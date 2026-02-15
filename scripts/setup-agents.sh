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
#   - setup.sh has been run at least once (so .env and namespaces exist)
#   - OpenClaw and Moltbook are deployed and running
#
# This script:
#   - Sources .env for secrets and config (OPENCLAW_PREFIX, OPENCLAW_NAMESPACE, etc.)
#   - Runs envsubst on agent templates only
#   - Deploys agent ConfigMaps (philbot, resource-optimizer)
#   - Registers agents with Moltbook (prefixed names)
#   - Grants contributor roles
#   - Restarts OpenClaw to load config
#   - Sets up cron jobs for autonomous posting
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
YELLOW='\033[1;33m'
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
for var in OPENCLAW_PREFIX OPENCLAW_NAMESPACE POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD; do
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
log_info "Agents:    ${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME}, ${OPENCLAW_PREFIX}_philbot, ${OPENCLAW_PREFIX}_resource_optimizer"
echo ""

# Verify cluster connection
if ! $KUBECTL get namespace "$OPENCLAW_NAMESPACE" &>/dev/null; then
  log_error "Namespace $OPENCLAW_NAMESPACE not found. Run setup.sh first."
  exit 1
fi
log_success "Connected to cluster, namespace exists"
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

ENVSUBST_VARS='${CLUSTER_DOMAIN} ${OPENCLAW_PREFIX} ${OPENCLAW_NAMESPACE} ${OPENCLAW_GATEWAY_TOKEN} ${OPENCLAW_OAUTH_CLIENT_SECRET} ${OPENCLAW_OAUTH_COOKIE_SECRET} ${JWT_SECRET} ${POSTGRES_DB} ${POSTGRES_USER} ${POSTGRES_PASSWORD} ${MOLTBOOK_OAUTH_CLIENT_SECRET} ${MOLTBOOK_OAUTH_COOKIE_SECRET} ${ANTHROPIC_API_KEY} ${SHADOWMAN_CUSTOM_NAME} ${SHADOWMAN_DISPLAY_NAME} ${MODEL_ENDPOINT} ${DEFAULT_AGENT_MODEL} ${GOOGLE_CLOUD_PROJECT} ${GOOGLE_CLOUD_LOCATION}'

for tpl in $(find "$REPO_ROOT/manifests/openclaw/agents" -name '*.envsubst'); do
  yaml="${tpl%.envsubst}"
  envsubst "$ENVSUBST_VARS" < "$tpl" > "$yaml"
  log_success "Generated $(basename "$yaml")"
done
echo ""

# Apply RBAC for agent jobs (must exist before jobs are created)
log_info "Applying agent manager RBAC..."
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/agent-manager-rbac.yaml"
log_success "RBAC applied"
echo ""

# Create DB credentials secret (used by grant-roles job to connect to PostgreSQL directly)
$KUBECTL create secret generic moltbook-db-credentials \
  -n "$OPENCLAW_NAMESPACE" \
  --from-literal=database-name="$POSTGRES_DB" \
  --from-literal=database-user="$POSTGRES_USER" \
  --from-literal=database-password="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | $KUBECTL apply -f -

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
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/shadowman-agent.yaml"
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/philbot-agent.yaml"
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/resource-optimizer-agent.yaml"
log_success "Agent ConfigMaps deployed"
echo ""

# Deploy skills
log_info "Deploying skills (using kustomize)..."
$KUBECTL kustomize "$REPO_ROOT/manifests/openclaw/skills/" \
  | sed "s/namespace: openclaw/namespace: $OPENCLAW_NAMESPACE/g" \
  | $KUBECTL apply -f -
log_success "Skills deployed"
echo ""

# Pre-registration cleanup: remove agents from Moltbook DB for idempotent re-runs
log_info "Cleaning up any existing agent registrations in Moltbook DB..."
PG_POD=$($KUBECTL get pods -n moltbook -l app=moltbook-postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
# Fallback label selectors if the first one doesn't match
if [ -z "$PG_POD" ]; then
  PG_POD=$($KUBECTL get pods -n moltbook -l component=database -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
fi
if [ -z "$PG_POD" ]; then
  PG_POD=$($KUBECTL get pods -n moltbook -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i postgres | head -1) || true
fi
if [ -n "$PG_POD" ]; then
  # Disable audit_log immutability triggers to allow cascading SET NULL on agent delete
  $KUBECTL exec -n moltbook "$PG_POD" -- psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    ALTER TABLE audit_log DISABLE TRIGGER audit_log_immutable_delete;
    ALTER TABLE audit_log DISABLE TRIGGER audit_log_immutable_update;
    DELETE FROM agents WHERE name IN ('${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME}', '${OPENCLAW_PREFIX}_philbot', '${OPENCLAW_PREFIX}_resource_optimizer');
    ALTER TABLE audit_log ENABLE TRIGGER audit_log_immutable_delete;
    ALTER TABLE audit_log ENABLE TRIGGER audit_log_immutable_update;
  " 2>/dev/null || log_warn "Could not clean up existing agents (table may not exist yet)"
  log_success "Pre-registration cleanup done"
else
  log_warn "PostgreSQL pod not found — skipping pre-cleanup (first deploy?)"
fi
echo ""

# Register agents with Moltbook
log_info "Registering agents with Moltbook..."
# Delete old jobs if re-running (jobs are immutable)
$KUBECTL delete job register-shadowman register-philbot register-resource-optimizer -n "$OPENCLAW_NAMESPACE" 2>/dev/null || true
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/register-shadowman-job.yaml"
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/register-philbot-job.yaml"
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/register-resource-optimizer-job.yaml"
sleep 5
$KUBECTL wait --for=condition=complete --timeout=60s job/register-shadowman -n "$OPENCLAW_NAMESPACE" 2>/dev/null || log_warn "Agent registration still running"
$KUBECTL wait --for=condition=complete --timeout=60s job/register-philbot -n "$OPENCLAW_NAMESPACE" 2>/dev/null || log_warn "Agent registration still running"
$KUBECTL wait --for=condition=complete --timeout=60s job/register-resource-optimizer -n "$OPENCLAW_NAMESPACE" 2>/dev/null || log_warn "Agent registration still running"
log_success "Agents registered"
echo ""

# Grant roles
log_info "Granting contributor roles..."
$KUBECTL delete job grant-agent-roles -n "$OPENCLAW_NAMESPACE" 2>/dev/null || true
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/job-grant-roles.yaml"
sleep 5
$KUBECTL wait --for=condition=complete --timeout=60s job/grant-agent-roles -n "$OPENCLAW_NAMESPACE" 2>/dev/null || log_warn "Role grants still running"
log_success "Roles granted"
echo ""

# Setup resource-optimizer RBAC (ServiceAccount + read-only access to resource-demo)
log_info "Setting up resource-optimizer RBAC..."
$KUBECTL create namespace resource-demo --dry-run=client -o yaml | $KUBECTL apply -f - > /dev/null
$KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/agents/resource-optimizer-rbac.yaml"
# Deploy demo workloads for resource-optimizer to analyze
for demo in "$REPO_ROOT/manifests/openclaw/agents"/demo-*.yaml; do
  [ -f "$demo" ] && $KUBECTL apply -f "$demo"
done
log_success "Resource-optimizer RBAC and demo workloads applied"
echo ""

# Restart OpenClaw to pick up new config
log_info "Restarting OpenClaw to load agents..."
$KUBECTL rollout restart deployment/openclaw -n "$OPENCLAW_NAMESPACE"
log_info "Waiting for OpenClaw to be ready..."
$KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=120s
log_success "OpenClaw ready"
echo ""

# Install moltbook skill into pod
log_info "Installing moltbook skill into OpenClaw pod..."
$KUBECTL get configmap moltbook-skill -n "$OPENCLAW_NAMESPACE" -o jsonpath='{.data.SKILL\.md}' | \
  $KUBECTL exec -i deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
    sh -c 'mkdir -p /home/node/.openclaw/skills/moltbook && cat > /home/node/.openclaw/skills/moltbook/SKILL.md && chmod -R 775 /home/node/.openclaw/skills'
log_success "Moltbook skill installed"
echo ""

# Install agent AGENTS.md and agent.json into each workspace
log_info "Installing agent identity files into workspaces..."
for agent_cfg in shadowman:workspace-${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME} philbot:workspace-${OPENCLAW_PREFIX}_philbot resource-optimizer:workspace-${OPENCLAW_PREFIX}_resource_optimizer; do
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

# Inject Moltbook credentials into all agent workspace .env files
# Secret names match the registration jobs:
#   shadowman: ${OPENCLAW_PREFIX}-${SHADOWMAN_CUSTOM_NAME}-moltbook-key (prefixed)
#   philbot:   philbot-moltbook-key (no prefix)
#   resource-optimizer: resource-optimizer-moltbook-key (no prefix)
MOLTBOOK_INT_URL="http://moltbook-api.moltbook.svc.cluster.local:3000"

inject_moltbook_creds() {
  local SECRET_NAME="$1"
  local WORKSPACE_ID="$2"
  local LABEL="$3"

  log_info "Injecting ${LABEL} Moltbook credentials..."
  local API_KEY
  API_KEY=$($KUBECTL get secret "$SECRET_NAME" -n "$OPENCLAW_NAMESPACE" -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d) || true
  if [ -n "$API_KEY" ]; then
    $KUBECTL exec deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- sh -c "
      ENV_FILE=\$HOME/.openclaw/workspace-${WORKSPACE_ID}/.env
      mkdir -p \$(dirname \$ENV_FILE)
      grep -v '^MOLTBOOK_API_KEY=\|^MOLTBOOK_API_URL=' \$ENV_FILE > \$ENV_FILE.tmp 2>/dev/null || true
      mv \$ENV_FILE.tmp \$ENV_FILE 2>/dev/null || true
      echo 'MOLTBOOK_API_KEY=$API_KEY' >> \$ENV_FILE
      echo 'MOLTBOOK_API_URL=$MOLTBOOK_INT_URL' >> \$ENV_FILE
    "
    log_success "${LABEL} Moltbook credentials injected"
  else
    log_warn "${LABEL} Moltbook key not found — registration may have failed"
  fi
}

inject_moltbook_creds "${OPENCLAW_PREFIX}-${SHADOWMAN_CUSTOM_NAME}-moltbook-key" "${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME}" "${SHADOWMAN_DISPLAY_NAME}"
inject_moltbook_creds "philbot-moltbook-key" "${OPENCLAW_PREFIX}_philbot" "PhilBot"
inject_moltbook_creds "resource-optimizer-moltbook-key" "${OPENCLAW_PREFIX}_resource_optimizer" "Resource Optimizer"
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

# Restart gateway first, THEN write cron jobs to the new pod.
# Writing before restart is unreliable — the restart creates a new pod and the
# old pod's pending writes may not flush to the PVC in time.
log_info "Restarting OpenClaw to load agents and skills..."
$KUBECTL rollout restart deployment/openclaw -n "$OPENCLAW_NAMESPACE"
$KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=120s
log_success "OpenClaw ready"
echo ""

# Setup cron jobs — write jobs.json directly to the PVC on the NEW pod
# (The CLI's --token flag doesn't bypass device pairing, so we write the file instead)
log_info "Setting up cron jobs for autonomous posting..."
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
      "id": "${OPENCLAW_PREFIX}-resource-optimizer-scan",
      "agentId": "${OPENCLAW_PREFIX}_resource_optimizer",
      "name": "${OPENCLAW_PREFIX}-resource-optimizer-scan",
      "description": "Daily cost optimization analysis",
      "enabled": true,
      "createdAtMs": ${NOW_MS},
      "updatedAtMs": ${NOW_MS},
      "schedule": { "kind": "cron", "expr": "0 8 * * *", "tz": "UTC" },
      "sessionTarget": "isolated",
      "wakeMode": "now",
      "delivery": { "mode": "none" },
      "payload": {
        "kind": "agentTurn",
        "message": "You are the Resource Optimizer. Check resource usage in resource-demo namespace and post a report to Moltbook.\n\nStep 1: Run this command to query resources:\n\n. ~/.openclaw/workspace-${OPENCLAW_PREFIX}_resource_optimizer/.env && K8S_API=https://kubernetes.default.svc && CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt && curl -s -H \"Authorization: Bearer \$OC_TOKEN\" --cacert \$CA \"\$K8S_API/api/v1/namespaces/resource-demo/pods\" | jq '[.items[] | {name: .metadata.name, phase: .status.phase, cpu_req: .spec.containers[0].resources.requests.cpu, mem_req: .spec.containers[0].resources.requests.memory}]' && curl -s -H \"Authorization: Bearer \$OC_TOKEN\" --cacert \$CA \"\$K8S_API/apis/apps/v1/namespaces/resource-demo/deployments\" | jq '[.items[] | {name: .metadata.name, replicas: .spec.replicas, available: .status.availableReplicas}]'\n\nStep 2: Write your analysis to a file. Include findings about over-provisioned pods, idle deployments, and recommendations. Use the write tool to create /tmp/report.txt with your analysis.\n\nStep 3: Post to Moltbook using this command (it reads your report from the file and builds valid JSON automatically):\n\n. ~/.openclaw/workspace-${OPENCLAW_PREFIX}_resource_optimizer/.env && TITLE=\"Resource Report - \$(date -u +'%b %d %Y')\" && jq -n --arg submolt cost_resource_analysis --arg title \"\$TITLE\" --arg content \"\$(cat /tmp/report.txt)\" '{submolt: \$submolt, title: \$title, content: \$content}' | curl -s -X POST \"\$MOLTBOOK_API_URL/api/v1/posts\" -H \"Authorization: Bearer \$MOLTBOOK_API_KEY\" -H \"Content-Type: application/json\" -d @-\n\nIMPORTANT: Use the write tool to write the report file, then use exec to run the posting command. Do NOT construct JSON by hand. Do NOT echo credentials.",
        "thinking": "low"
      },
      "state": {}
    }
  ]
}
CRON_EOF
log_success "Cron jobs written to new pod"
echo ""

# Final restart to load the cron jobs (gateway reads jobs.json at startup)
log_info "Final restart to load cron jobs..."
$KUBECTL rollout restart deployment/openclaw -n "$OPENCLAW_NAMESPACE"
$KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=120s
log_success "OpenClaw ready with cron jobs and moltbook skill"
echo ""

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Agent Setup Complete!                                     ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Agents deployed:"
echo "  ${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME}:            contributor (interactive, Anthropic)"
echo "  ${OPENCLAW_PREFIX}_philbot:             contributor (daily at 9AM UTC)"
echo "  ${OPENCLAW_PREFIX}_resource_optimizer:  contributor (daily at 8AM UTC)"
echo ""
echo "Cleanup: cd manifests/openclaw/agents && ./remove-custom-agents.sh"
echo ""
