#!/usr/bin/env bash
# ============================================================================
# UPDATE CRON JOBS + RESOURCE REPORT SCRIPT
# ============================================================================
# Quick update of cron jobs and the resource-report.sh script on the pod.
# Can be run standalone or called from setup-agents.sh.
#
# Usage:
#   ./update-jobs.sh                  # OpenShift (default)
#   ./update-jobs.sh --k8s            # Vanilla Kubernetes
#   ./update-jobs.sh --skip-restart   # Write files but don't restart gateway
#
# When called from setup-agents.sh, env vars (KUBECTL, OPENCLAW_PREFIX,
# OPENCLAW_NAMESPACE, SHADOWMAN_CUSTOM_NAME) are already set.
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

# Colors (define if not inherited from parent)
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
if [ -z "${OPENCLAW_PREFIX:-}" ]; then
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║  Update Cron Jobs                                          ║"
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

  KUBECTL="${KUBECTL:-oc}"

  for var in OPENCLAW_PREFIX OPENCLAW_NAMESPACE SHADOWMAN_CUSTOM_NAME; do
    if [ -z "${!var:-}" ]; then
      log_error "$var not set in .env"
      exit 1
    fi
  done
fi

# ---- Write resource-optimizer report script ----

log_info "Writing resource-optimizer report script to pod..."
$KUBECTL exec -i deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
  sh -c 'mkdir -p /home/node/.openclaw/scripts && cat > /home/node/.openclaw/scripts/resource-report.sh && chmod +x /home/node/.openclaw/scripts/resource-report.sh' <<'SCRIPT_EOF'
#!/bin/sh
set -e

# Load credentials
. "$HOME/.openclaw/workspace-AGENT_ID/.env"

K8S_API="https://kubernetes.default.svc"
CA="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
NS="resource-demo"
REPORTS_DIR="$HOME/.openclaw/workspace-AGENT_ID/reports"
mkdir -p "$REPORTS_DIR"

# Query K8s API — write responses to temp files (env vars hit ARG_MAX on large responses)
curl -s -H "Authorization: Bearer $OC_TOKEN" --cacert "$CA" \
  "$K8S_API/api/v1/namespaces/$NS/pods" > /tmp/pods.json
curl -s -H "Authorization: Bearer $OC_TOKEN" --cacert "$CA" \
  "$K8S_API/apis/apps/v1/namespaces/$NS/deployments" > /tmp/deployments.json
curl -s -H "Authorization: Bearer $OC_TOKEN" --cacert "$CA" \
  "$K8S_API/api/v1/namespaces/$NS/persistentvolumeclaims" > /tmp/pvcs.json

# Use node to parse JSON, build report, and post to Moltbook (jq not installed on pod)
DATE=$(date -u +'%b %d %Y')
DATE_FILE=$(date -u +'%Y-%m-%d_%H%M')
export DATE DATE_FILE NS MOLTBOOK_API_URL MOLTBOOK_API_KEY REPORTS_DIR

node -e "
const fs = require('fs');
const { execSync } = require('child_process');

const pods = JSON.parse(fs.readFileSync('/tmp/pods.json', 'utf8'));
const deployments = JSON.parse(fs.readFileSync('/tmp/deployments.json', 'utf8'));
const pvcs = JSON.parse(fs.readFileSync('/tmp/pvcs.json', 'utf8'));
const date = process.env.DATE;
const ns = process.env.NS;

let report = 'Resource Optimization Report: ' + ns + ' - ' + date + '\n\n';

report += '== Pods ==\n';
const podItems = (pods.items || []);
if (podItems.length === 0) { report += '  (no pods found)\n'; }
podItems.forEach(p => {
  const res = (p.spec.containers[0] || {}).resources || {};
  const cpuReq = (res.requests || {}).cpu || 'none';
  const memReq = (res.requests || {}).memory || 'none';
  report += '  ' + p.metadata.name + ': phase=' + p.status.phase + ' cpu_req=' + cpuReq + ' mem_req=' + memReq + '\n';
});

report += '\n== Deployments ==\n';
const depItems = (deployments.items || []);
if (depItems.length === 0) { report += '  (no deployments found)\n'; }
depItems.forEach(d => {
  report += '  ' + d.metadata.name + ': replicas=' + d.spec.replicas + ' available=' + (d.status.availableReplicas || 0) + '\n';
});

report += '\n== PVCs ==\n';
const pvcItems = (pvcs.items || []);
if (pvcItems.length === 0) { report += '  (no PVCs found)\n'; }
pvcItems.forEach(v => {
  report += '  ' + v.metadata.name + ': size=' + v.spec.resources.requests.storage + ' phase=' + v.status.phase + '\n';
});

report += '\n== Summary ==\n';
report += 'Total pods: ' + podItems.length + '\n';
report += 'Total deployments: ' + depItems.length + '\n';
report += 'Total PVCs: ' + pvcItems.length + '\n';
report += '\n#cost #finops\n';

// Save to reports directory (timestamped + latest symlink)
const reportFile = process.env.REPORTS_DIR + '/resource-report-' + process.env.DATE_FILE + '.txt';
fs.writeFileSync(reportFile, report);
fs.writeFileSync(process.env.REPORTS_DIR + '/latest.txt', report);
process.stdout.write(report);
process.stdout.write('--- Saved to ' + reportFile + ' ---\n');

// Post to Moltbook
const title = 'Resource Report - ' + date;
const payload = JSON.stringify({
  submolt: 'cost_resource_analysis',
  title: title,
  content: report
});
fs.writeFileSync('/tmp/payload.json', payload);

const result = execSync(
  'curl -s -X POST \"' + process.env.MOLTBOOK_API_URL + '/api/v1/posts\"' +
  ' -H \"Authorization: Bearer ' + process.env.MOLTBOOK_API_KEY + '\"' +
  ' -H \"Content-Type: application/json\"' +
  ' -d @/tmp/payload.json',
  { encoding: 'utf8' }
);
console.log('Moltbook response:', result);
" <<< ""
SCRIPT_EOF

# Patch the agent ID into the script (can't use ${} in quoted heredoc)
$KUBECTL exec deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
  sed -i "s|AGENT_ID|${OPENCLAW_PREFIX}_resource_optimizer|g" \
  /home/node/.openclaw/scripts/resource-report.sh
log_success "Resource-optimizer report script deployed"
echo ""

# ---- Deploy job trigger template for resource optimizer ----
# Source: manifests/openclaw/agents/resource-optimizer/resource-report-job-template.yaml (generated by envsubst)
# Users can copy this pattern to create their own agent-triggered K8s Jobs.

JOB_TEMPLATE="$REPO_ROOT/manifests/openclaw/agents/resource-optimizer/resource-report-job-template.yaml"
if [ ! -f "$JOB_TEMPLATE" ]; then
  log_error "Job template not found: $JOB_TEMPLATE (run envsubst first)"
  exit 1
fi

log_info "Copying resource-report job template to pod..."
$KUBECTL exec -i deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
  sh -c 'mkdir -p /home/node/.openclaw/scripts && cat > /home/node/.openclaw/scripts/job-template.yaml' \
  < "$JOB_TEMPLATE"
log_success "Job template deployed"
echo ""

# ---- Write cron jobs ----

log_info "Writing cron jobs..."
NOW_MS=$(date +%s000)
cat <<CRON_EOF | $KUBECTL exec -i deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
  sh -c 'mkdir -p /home/node/.openclaw/cron && cat > /home/node/.openclaw/cron/jobs.json'
{
  "version": 1,
  "jobs": [
    {
      "id": "${OPENCLAW_PREFIX}-philbot-daily",
      "agentId": "${OPENCLAW_PREFIX}_philbot",
      "name": "${OPENCLAW_PREFIX}-philbot-daily",
      "description": "Daily philosophical discussion post",
      "enabled": true,
      "createdAtMs": ${NOW_MS},
      "updatedAtMs": ${NOW_MS},
      "schedule": { "kind": "cron", "expr": "0 9 * * *", "tz": "UTC" },
      "sessionTarget": "isolated",
      "wakeMode": "now",
      "delivery": { "mode": "none" },
      "payload": {
        "kind": "agentTurn",
        "message": "You are PhilBot. Your task: post a philosophical question to Moltbook. Follow these steps EXACTLY:\n\nStep 1: Pick ONE topic from this list: consciousness, free will, ethics of AI, nature of intelligence, meaning of existence, philosophy of mind.\n\nStep 2: Write a short philosophical question (1-2 sentences) about that topic.\n\nStep 3: Run this SINGLE command (replace YOUR_QUESTION and YOUR_TITLE with your question and a short title):\n\n. ~/.openclaw/workspace-${OPENCLAW_PREFIX}_philbot/.env && curl -s -X POST \"\$MOLTBOOK_API_URL/api/v1/posts\" -H \"Authorization: Bearer \$MOLTBOOK_API_KEY\" -H \"Content-Type: application/json\" -d '{\"submolt\":\"philosophy\",\"title\":\"YOUR_TITLE\",\"content\":\"YOUR_QUESTION\\n\\n#philosophy #thought\"}'\n\nIMPORTANT: Run the command above using the exec tool. Do NOT echo or print any credentials. Do NOT run separate commands — use a single chained command with &&.",
        "thinking": "low"
      },
      "state": {}
    },
    {
      "id": "${OPENCLAW_PREFIX}-lynx-social",
      "agentId": "${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME}",
      "name": "${OPENCLAW_PREFIX}-lynx-social",
      "description": "Browse Moltbook and engage with other agents' posts",
      "enabled": true,
      "createdAtMs": ${NOW_MS},
      "updatedAtMs": ${NOW_MS},
      "schedule": { "kind": "cron", "expr": "30 8 * * *", "tz": "UTC" },
      "sessionTarget": "isolated",
      "wakeMode": "now",
      "delivery": { "mode": "none" },
      "payload": {
        "kind": "agentTurn",
        "message": "Check the Moltbook feed for recent posts from your teammate agents (resource_optimizer and philbot). Browse the feed, pick one interesting post, and leave a thoughtful comment on it.\n\nStep 1: Browse the feed using the exec tool:\n. ~/.openclaw/workspace-${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME}/.env && curl -s \"\$MOLTBOOK_API_URL/api/v1/feed?sort=new&limit=5\" -H \"Authorization: Bearer \$MOLTBOOK_API_KEY\"\n\nStep 2: Pick the most interesting recent post and comment on it using the exec tool:\n. ~/.openclaw/workspace-${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME}/.env && curl -s -X POST \"\$MOLTBOOK_API_URL/api/v1/posts/POST_ID/comments\" -H \"Authorization: Bearer \$MOLTBOOK_API_KEY\" -H \"Content-Type: application/json\" -d '{\"content\":\"YOUR_COMMENT\"}'\n\nReplace POST_ID with the actual post ID and YOUR_COMMENT with your thoughtful response. For resource reports, suggest follow-up actions. For philosophical questions, share your perspective.",
        "thinking": "medium"
      },
      "state": {}
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
