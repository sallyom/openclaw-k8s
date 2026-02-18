#!/usr/bin/env bash
# ============================================================================
# UPDATE OPENCLAW INTERNAL CRON JOBS
# ============================================================================
# Writes OpenClaw's internal cron/jobs.json to the pod.
#
# Current jobs:
# - resource-optimizer-analysis: Reads the K8s CronJob report from ConfigMap,
#   analyzes it, and messages the default agent with notable findings.
#
# Usage:
#   ./update-jobs.sh                  # OpenShift (default)
#   ./update-jobs.sh --k8s            # Vanilla Kubernetes
#   ./update-jobs.sh --skip-restart   # Write files but don't restart gateway
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse flags
SKIP_RESTART=false
for arg in "$@"; do
  case "$arg" in
    --k8s) KUBECTL="${KUBECTL:-kubectl}" ;;
    --skip-restart) SKIP_RESTART=true ;;
  esac
done

KUBECTL="${KUBECTL:-oc}"

# Colors
GREEN="${GREEN:-\033[0;32m}"
BLUE="${BLUE:-\033[0;34m}"
RED="${RED:-\033[0;31m}"
NC="${NC:-\033[0m}"

# Log functions (define if not inherited from parent)
if ! declare -f log_info >/dev/null 2>&1; then
  log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
  log_success() { echo -e "${GREEN}✅ $1${NC}"; }
  log_error()   { echo -e "${RED}❌ $1${NC}"; }
fi

# Load env if not already set (standalone mode)
if [ -z "${OPENCLAW_NAMESPACE:-}" ]; then
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║  Update OpenClaw Cron Jobs                                 ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""

  if [ ! -f "$REPO_ROOT/.env" ]; then
    log_error "No .env file found. Run setup.sh first."
    exit 1
  fi

  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a

  for var in OPENCLAW_PREFIX OPENCLAW_NAMESPACE SHADOWMAN_CUSTOM_NAME; do
    if [ -z "${!var:-}" ]; then
      log_error "$var not set in .env"
      exit 1
    fi
  done
fi

# ---- Write cron jobs ----

log_info "Writing OpenClaw cron jobs..."

# Use unquoted heredoc so bash substitutes ${OPENCLAW_PREFIX} and ${SHADOWMAN_CUSTOM_NAME}
cat <<CRON_EOF | $KUBECTL exec -i deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
  sh -c 'mkdir -p /home/node/.openclaw/cron && cat > /home/node/.openclaw/cron/jobs.json'
{
  "version": 1,
  "jobs": [
    {
      "id": "resource-optimizer-analysis",
      "agentId": "${OPENCLAW_PREFIX}_resource_optimizer",
      "schedule": {"kind": "cron", "expr": "0 9,17 * * *", "tz": "UTC"},
      "sessionTarget": "isolated",
      "delivery": { "mode": "none" },
      "wakeMode": "now",
      "payload": {
        "kind": "agentTurn",
        "message": "Read the latest resource report by running: cat /data/reports/resource-optimizer/report.txt — then analyze it for notable findings: over-provisioned pods (high requests but likely low usage), idle deployments (0 replicas), unattached PVCs, or any degraded deployments. If you find issues worth flagging, send a brief 2-3 sentence summary to ${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME} using sessions_send. Focus on actionable insights. If everything looks healthy, no message needed."
      }
    },
    {
      "id": "mlops-monitor-analysis",
      "agentId": "${OPENCLAW_PREFIX}_mlops_monitor",
      "schedule": {"kind": "cron", "expr": "0 10,16 * * *", "tz": "UTC"},
      "sessionTarget": "isolated",
      "delivery": { "mode": "none" },
      "wakeMode": "now",
      "payload": {
        "kind": "agentTurn",
        "message": "Read the latest MLOps report at /data/reports/mlops-monitor/report.txt. Analyze for: high error rates (above 5%), latency spikes (above 30s average), low evaluation scores, or unusual patterns. If you find anything notable, send a brief summary to ${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME} using sessions_send. Include specific numbers. If metrics look healthy, no message needed."
      }
    }
  ]
}
CRON_EOF

log_success "Cron jobs written"
echo ""

# ---- Restart gateway to reload (unless caller handles it) ----

if ! $SKIP_RESTART; then
  log_info "Restarting OpenClaw to load updated jobs..."
  $KUBECTL rollout restart deployment/openclaw -n "$OPENCLAW_NAMESPACE"
  $KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=120s
  log_success "Done — jobs updated and loaded"
  echo ""
fi
