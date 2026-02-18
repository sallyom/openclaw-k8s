#!/usr/bin/env bash
# ============================================================================
# AGENT-ONLY SETUP SCRIPT
# ============================================================================
# Deploy (or re-deploy) AI agents to an existing OpenClaw instance.
# Uses the existing .env — does NOT regenerate secrets.
#
# Usage:
#   ./setup-agents.sh           # OpenShift (default)
#   ./setup-agents.sh --k8s     # Vanilla Kubernetes
#
# Prerequisites:
#   - setup.sh has been run at least once (so .env and namespace exist)
#   - OpenClaw is deployed and running
#
# This script:
#   - Sources .env for secrets and config (OPENCLAW_PREFIX, OPENCLAW_NAMESPACE, etc.)
#   - Runs envsubst on agent templates only
#   - Deploys agent ConfigMaps (shadowman, resource-optimizer)
#   - Sets up resource-optimizer RBAC and demo workloads
#   - Restarts OpenClaw to load config
#   - Sets up cron jobs for autonomous tasks
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse flags
K8S_MODE=false
for arg in "$@"; do
  case "$arg" in
    --k8s) K8S_MODE=true ;;
  esac
done

if $K8S_MODE; then
  KUBECTL="kubectl"
else
  KUBECTL="oc"
fi

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; }

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  OpenClaw Agent Setup                                      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Load .env
if [ ! -f "$REPO_ROOT/.env" ]; then
  log_error "No .env file found. Run setup.sh first."
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$REPO_ROOT/.env"
set +a

# Validate required vars
for var in OPENCLAW_PREFIX OPENCLAW_NAMESPACE; do
  if [ -z "${!var:-}" ]; then
    log_error "$var not set in .env. Run setup.sh first (or add it manually)."
    exit 1
  fi
done

# Prompt for custom default agent name
if [ -n "${SHADOWMAN_CUSTOM_NAME:-}" ]; then
  log_info "Using saved agent name: ${SHADOWMAN_DISPLAY_NAME:-$SHADOWMAN_CUSTOM_NAME}"
else
  echo "Your default agent is 'Shadowman'. Would you like to customize its name?"
  read -p "  Enter a name (or press Enter to keep 'Shadowman'): " CUSTOM_NAME
  if [ -n "$CUSTOM_NAME" ]; then
    SHADOWMAN_DISPLAY_NAME="$CUSTOM_NAME"
    SHADOWMAN_CUSTOM_NAME=$(echo "$CUSTOM_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd 'a-z0-9_')
    log_success "Agent will be named '${SHADOWMAN_DISPLAY_NAME}' (id: ${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME})"
    # Save to .env for future runs
    if ! grep -q '^SHADOWMAN_CUSTOM_NAME=' "$REPO_ROOT/.env" 2>/dev/null; then
      echo "" >> "$REPO_ROOT/.env"
      echo "# Custom default agent name (set by setup-agents.sh)" >> "$REPO_ROOT/.env"
      echo "SHADOWMAN_CUSTOM_NAME=${SHADOWMAN_CUSTOM_NAME}" >> "$REPO_ROOT/.env"
      echo "SHADOWMAN_DISPLAY_NAME=${SHADOWMAN_DISPLAY_NAME}" >> "$REPO_ROOT/.env"
    else
      sed -i.bak "s/^SHADOWMAN_CUSTOM_NAME=.*/SHADOWMAN_CUSTOM_NAME=${SHADOWMAN_CUSTOM_NAME}/" "$REPO_ROOT/.env"
      sed -i.bak "s/^SHADOWMAN_DISPLAY_NAME=.*/SHADOWMAN_DISPLAY_NAME=${SHADOWMAN_DISPLAY_NAME}/" "$REPO_ROOT/.env"
      rm -f "$REPO_ROOT/.env.bak"
    fi
  else
    SHADOWMAN_CUSTOM_NAME="shadowman"
    SHADOWMAN_DISPLAY_NAME="Shadowman"
    log_info "Keeping default name: Shadowman"
  fi
  export SHADOWMAN_CUSTOM_NAME SHADOWMAN_DISPLAY_NAME
fi

log_info "Namespace: $OPENCLAW_NAMESPACE"
log_info "Prefix:    $OPENCLAW_PREFIX"
log_info "Agents:    ${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME}, ${OPENCLAW_PREFIX}_resource_optimizer, ${OPENCLAW_PREFIX}_mlops_monitor"
echo ""

# Verify cluster connection
if ! $KUBECTL get namespace "$OPENCLAW_NAMESPACE" &>/dev/null; then
  log_error "Namespace $OPENCLAW_NAMESPACE not found. Run setup.sh first."
  exit 1
fi
log_success "Connected to cluster, namespace exists"

# Update namespace annotations with agent roster
AGENT_LIST="${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME},${OPENCLAW_PREFIX}_resource_optimizer,${OPENCLAW_PREFIX}_mlops_monitor"
$KUBECTL annotate namespace "$OPENCLAW_NAMESPACE" \
  "openclaw.dev/agent-name=$SHADOWMAN_DISPLAY_NAME" \
  "openclaw.dev/agent-id=${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME}" \
  "openclaw.dev/agents=$AGENT_LIST" \
  --overwrite > /dev/null
log_success "Namespace annotations updated (agents: $AGENT_LIST)"
echo ""

# Run envsubst on agent templates only
log_info "Running envsubst on agent templates..."
export MODEL_ENDPOINT="${MODEL_ENDPOINT:-http://vllm.openclaw-llms.svc.cluster.local/v1}"
export VERTEX_ENABLED="${VERTEX_ENABLED:-false}"
export GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:-}"
export GOOGLE_CLOUD_LOCATION="${GOOGLE_CLOUD_LOCATION:-}"

# Agent model priority: Anthropic > Google Vertex > in-cluster
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  export DEFAULT_AGENT_MODEL="anthropic/claude-sonnet-4-5"
elif [ "${VERTEX_ENABLED:-}" = "true" ]; then
  export DEFAULT_AGENT_MODEL="google-vertex/gemini-2.5-pro"
  log_info "Using Google Vertex (Gemini) as default agent model"
else
  export DEFAULT_AGENT_MODEL="nerc/openai/gpt-oss-20b"
  log_info "No Anthropic API key or Vertex — agents will use in-cluster model (${MODEL_ENDPOINT})"
fi

ENVSUBST_VARS='${CLUSTER_DOMAIN} ${OPENCLAW_PREFIX} ${OPENCLAW_NAMESPACE} ${OPENCLAW_GATEWAY_TOKEN} ${OPENCLAW_OAUTH_CLIENT_SECRET} ${OPENCLAW_OAUTH_COOKIE_SECRET} ${ANTHROPIC_API_KEY} ${SHADOWMAN_CUSTOM_NAME} ${SHADOWMAN_DISPLAY_NAME} ${MODEL_ENDPOINT} ${DEFAULT_AGENT_MODEL} ${GOOGLE_CLOUD_PROJECT} ${GOOGLE_CLOUD_LOCATION}'

for tpl in $(find "$REPO_ROOT/manifests/openclaw/agents" -name '*.envsubst'); do
  yaml="${tpl%.envsubst}"
  envsubst "$ENVSUBST_VARS" < "$tpl" > "$yaml"
  log_success "Generated $(basename "$yaml")"
done
echo ""

# Deploy agent configuration (overlay config patch)
if ! $K8S_MODE; then
  log_info "Deploying agent configuration..."
  $KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/agents-config-patch.yaml"
  log_success "Agent configuration deployed"
  echo ""
fi

# Deploy agent ConfigMaps AFTER config patch (must come after any kustomize apply,
# since the base kustomization includes a default shadowman-agent that would overwrite)
log_info "Deploying agent ConfigMaps..."
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/shadowman/shadowman-agent.yaml"
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/resource-optimizer/resource-optimizer-agent.yaml"
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/mlops-monitor/mlops-monitor-agent.yaml"
log_success "Agent ConfigMaps deployed"
echo ""

# Deploy NPS skill ConfigMap
log_info "Deploying NPS skill..."
$KUBECTL kustomize "$REPO_ROOT/manifests/openclaw/skills" \
  | sed "s/namespace: openclaw/namespace: $OPENCLAW_NAMESPACE/g" \
  | $KUBECTL apply -f -
log_success "NPS skill ConfigMap deployed"
echo ""

# Setup resource-optimizer RBAC (ServiceAccount + read-only access to resource-demo)
log_info "Setting up resource-optimizer RBAC..."
$KUBECTL create namespace resource-demo --dry-run=client -o yaml | $KUBECTL apply -f - > /dev/null
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/resource-optimizer/resource-optimizer-rbac.yaml"
# Deploy demo workloads for resource-optimizer to analyze
for demo in "$REPO_ROOT/manifests/openclaw/agents/demo-workloads"/demo-*.yaml; do
  [ -f "$demo" ] && $KUBECTL apply -f "$demo"
done
# Pre-create the resource-report-latest ConfigMap (CronJob will update it)
$KUBECTL create configmap resource-report-latest \
  --from-literal=report.txt="No report generated yet. The resource-report CronJob has not run." \
  -n "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -
# Deploy K8s CronJob for resource reports (runs independently of the LLM)
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/resource-optimizer/resource-report-cronjob.yaml"
log_success "Resource-optimizer RBAC, demo workloads, report ConfigMap, and CronJob applied"
echo ""

# Setup mlops-monitor RBAC and CronJob
log_info "Setting up mlops-monitor..."
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/mlops-monitor/mlops-monitor-rbac.yaml"
# Pre-create the mlops-report-latest ConfigMap (CronJob will update it)
$KUBECTL create configmap mlops-report-latest \
  --from-literal=report.txt="No report generated yet. The mlops-report CronJob has not run." \
  -n "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -
# Create mlops-monitor secrets (MLFLOW_TRACKING_URI)
MLFLOW_URI="${MLFLOW_TRACKING_URI:-}"
if [ -z "$MLFLOW_URI" ]; then
  log_info "MLflow tracking URI (for mlops-monitor to query NPS Agent traces):"
  read -p "  Enter URI (or press Enter to skip): " MLFLOW_URI
fi
if [ -n "$MLFLOW_URI" ]; then
  $KUBECTL create secret generic mlops-monitor-secrets \
    --from-literal=MLFLOW_TRACKING_URI="$MLFLOW_URI" \
    -n "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -
  log_success "MLflow tracking URI configured"
else
  # Create empty secret so CronJob doesn't crash
  $KUBECTL create secret generic mlops-monitor-secrets \
    --from-literal=MLFLOW_TRACKING_URI="" \
    -n "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -
  log_warn "No MLflow URI set — mlops-monitor reports will show an error until configured"
fi
# Deploy CronJob
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/mlops-monitor/mlops-monitor-cronjob.yaml"
log_success "MLOps-monitor RBAC, report ConfigMap, and CronJob applied"
echo ""

# Restart OpenClaw to pick up new config
log_info "Restarting OpenClaw to load agents..."
$KUBECTL rollout restart deployment/openclaw -n "$OPENCLAW_NAMESPACE"
log_info "Waiting for OpenClaw to be ready..."
$KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=300s
log_success "OpenClaw ready"
echo ""

# Install agent AGENTS.md and agent.json into each workspace
log_info "Installing agent identity files into workspaces..."
for agent_cfg in shadowman:workspace-${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME} resource-optimizer:workspace-${OPENCLAW_PREFIX}_resource_optimizer mlops-monitor:workspace-${OPENCLAW_PREFIX}_mlops_monitor; do
  AGENT_NAME="${agent_cfg%%:*}"
  WORKSPACE="${agent_cfg#*:}"
  WORKSPACE_DIR="/home/node/.openclaw/${WORKSPACE}"
  CM_NAME="${AGENT_NAME}-agent"
  # Ensure workspace directory exists
  $KUBECTL exec deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- mkdir -p "$WORKSPACE_DIR"
  for key in AGENTS.md agent.json; do
    $KUBECTL get configmap "$CM_NAME" -n "$OPENCLAW_NAMESPACE" -o jsonpath="{.data.${key//./\\.}}" | \
      $KUBECTL exec -i deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
        sh -c "cat > ${WORKSPACE_DIR}/${key}"
  done
  log_success "  ${AGENT_NAME} → ${WORKSPACE}"
done
echo ""

# Install NPS skill into workspace
log_info "Installing NPS skill into workspace..."
$KUBECTL get configmap nps-skill -n "$OPENCLAW_NAMESPACE" -o jsonpath='{.data.SKILL\.md}' | \
  $KUBECTL exec -i deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
    sh -c 'mkdir -p /home/node/.openclaw/skills/nps && cat > /home/node/.openclaw/skills/nps/SKILL.md'
log_success "NPS skill installed"
echo ""

# Inject resource-optimizer SA token into workspace .env
log_info "Injecting resource-optimizer ServiceAccount token..."
RO_TOKEN=""
for i in $(seq 1 15); do
  RO_TOKEN=$($KUBECTL get secret resource-optimizer-sa-token -n "$OPENCLAW_NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d) || true
  if [ -n "$RO_TOKEN" ]; then break; fi
  log_info "  Waiting for SA token... ($i/15)"
  sleep 2
done

if [ -n "$RO_TOKEN" ]; then
  $KUBECTL exec deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- sh -c "
    ENV_FILE=\$HOME/.openclaw/workspace-${OPENCLAW_PREFIX}_resource_optimizer/.env
    mkdir -p \$(dirname \$ENV_FILE)
    grep -v '^OC_TOKEN=' \$ENV_FILE > \$ENV_FILE.tmp 2>/dev/null || true
    mv \$ENV_FILE.tmp \$ENV_FILE 2>/dev/null || true
    echo 'OC_TOKEN=$RO_TOKEN' >> \$ENV_FILE
  "
  log_success "Resource-optimizer SA token injected"
else
  log_warn "Could not get SA token — resource-optimizer won't have K8s API access"
  log_warn "Run setup-resource-optimizer-rbac.sh manually after deployment"
fi
echo ""

# Restart gateway to load agent configs and report ConfigMap mount
log_info "Restarting OpenClaw to load agents..."
$KUBECTL rollout restart deployment/openclaw -n "$OPENCLAW_NAMESPACE"
$KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=300s
log_success "OpenClaw ready"
echo ""

# Write OpenClaw internal cron jobs (agent analysis schedule)
"$SCRIPT_DIR/update-jobs.sh" --skip-restart
log_success "Cron jobs written"

# Final restart to load cron jobs
log_info "Final restart to load cron jobs..."
$KUBECTL rollout restart deployment/openclaw -n "$OPENCLAW_NAMESPACE"
$KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=300s
log_success "OpenClaw ready with agents"
echo ""

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Agent Setup Complete!                                     ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Agents deployed:"
echo "  ${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME}:            interactive assistant"
echo "  ${OPENCLAW_PREFIX}_resource_optimizer:  cost analysis (report CronJob every 8h)"
echo "  ${OPENCLAW_PREFIX}_mlops_monitor:       MLOps monitoring (report CronJob every 6h)"
echo ""
echo "Skills deployed:"
echo "  nps:  query the NPS Agent for national park information"
echo ""
echo "Agent cron jobs:"
echo "  resource-optimizer-analysis:  reads report, messages ${SHADOWMAN_DISPLAY_NAME} (9 AM + 5 PM UTC)"
echo "  mlops-monitor-analysis:      reads MLflow report, messages ${SHADOWMAN_DISPLAY_NAME} (10 AM + 4 PM UTC)"
echo ""
echo "Cleanup: cd manifests/openclaw/agents && ./remove-custom-agents.sh"
echo ""
