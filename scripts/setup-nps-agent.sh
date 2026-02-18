#!/usr/bin/env bash
# ============================================================================
# NPS AGENT DEPLOYMENT SCRIPT
# ============================================================================
# Deploys the NPS Agent with A2A bridge and AuthBridge sidecars.
# Gives the NPS Agent its own SPIFFE identity for cross-namespace A2A calls.
#
# Usage:
#   ./setup-nps-agent.sh
#
# Prerequisites:
#   - OpenShift cluster with SPIRE and Keycloak deployed
#   - openclaw-authbridge SCC applied (shared with OpenClaw instances)
#   - SPIRE registration entry for the NPS Agent namespace (see output)
#
# This script:
#   - Creates the nps-agent namespace
#   - Builds the NPS Agent from https://github.com/Nehanth/nps_agent
#   - Deploys with A2A bridge + AuthBridge sidecars
#   - Grants the AuthBridge SCC
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KUBECTL="oc"

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
echo "║  NPS Agent Deployment (with A2A + SPIFFE identity)         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Load .env for cluster domain (optional)
if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

# Namespace
NPS_AGENT_NAMESPACE="${NPS_AGENT_NAMESPACE:-nps-agent}"
export NPS_AGENT_NAMESPACE

log_info "Namespace: $NPS_AGENT_NAMESPACE"
echo ""

# Prompt for secrets
log_info "NPS Agent configuration:"
echo ""

# Model endpoint — default to in-cluster vLLM from .env
NPS_MODEL_ENDPOINT="${MODEL_ENDPOINT:-http://vllm.openclaw-llms.svc.cluster.local/v1}"
log_info "  Model endpoint (OpenAI-compatible /v1 URL):"
log_info "  Current: $NPS_MODEL_ENDPOINT"
read -p "  Press Enter to keep, or enter a new URL: " CUSTOM_ENDPOINT
if [ -n "$CUSTOM_ENDPOINT" ]; then
  NPS_MODEL_ENDPOINT="$CUSTOM_ENDPOINT"
fi
log_success "Model endpoint: $NPS_MODEL_ENDPOINT"

# Model name
NPS_MODEL_NAME="${OPENAI_MODEL_NAME:-gpt-oss-20b}"
read -p "  Model name [${NPS_MODEL_NAME}]: " CUSTOM_MODEL
if [ -n "$CUSTOM_MODEL" ]; then
  NPS_MODEL_NAME="$CUSTOM_MODEL"
fi

# OpenAI API key — dummy value for vLLM/in-cluster endpoints
OPENAI_API_KEY_NPS="${OPENAI_API_KEY_NPS:-fakekey}"
echo ""

# NPS API key (for the government NPS API, not an LLM key)
if [ -z "${NPS_API_KEY:-}" ]; then
  log_info "  NPS API key (free, from https://www.nps.gov/subjects/developer/get-started.htm):"
  read -p "  API key: " NPS_API_KEY
  if [ -z "$NPS_API_KEY" ]; then
    log_error "NPS API key is required (it's a free government API key, not an LLM key)."
    exit 1
  fi
fi

MLFLOW_TRACKING_URI_NPS="${MLFLOW_TRACKING_URI_NPS:-}"
if [ -z "$MLFLOW_TRACKING_URI_NPS" ]; then
  read -p "  MLflow tracking URI (optional, for trace export): " MLFLOW_TRACKING_URI_NPS
fi

echo ""

# Confirm
log_warn "This will deploy the NPS Agent to namespace: $NPS_AGENT_NAMESPACE"
read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  log_info "Deployment cancelled"
  exit 0
fi
echo ""

# Create namespace
log_info "Creating namespace..."
$KUBECTL create namespace "$NPS_AGENT_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f - > /dev/null
$KUBECTL label namespace "$NPS_AGENT_NAMESPACE" kagenti-enabled=true --overwrite > /dev/null
$KUBECTL annotate namespace "$NPS_AGENT_NAMESPACE" \
  "openclaw.dev/agent-name=NPS Agent" \
  "openclaw.dev/agent-id=nps_agent" \
  --overwrite > /dev/null
log_success "Namespace created: $NPS_AGENT_NAMESPACE"
echo ""

# Create secrets
log_info "Creating secrets..."
$KUBECTL create secret generic nps-agent-secrets \
  --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY_NPS" \
  --from-literal=OPENAI_BASE_URL="$NPS_MODEL_ENDPOINT" \
  --from-literal=OPENAI_MODEL_NAME="$NPS_MODEL_NAME" \
  --from-literal=NPS_API_KEY="$NPS_API_KEY" \
  --from-literal=MLFLOW_TRACKING_URI="${MLFLOW_TRACKING_URI_NPS:-}" \
  -n "$NPS_AGENT_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -
log_success "Secrets created"
echo ""

# Apply SCC RBAC (reuses the shared openclaw-authbridge SCC)
log_info "Applying SCC RBAC..."
if $KUBECTL apply -f "$REPO_ROOT/manifests/openclaw/base/openclaw-scc.yaml" 2>/dev/null; then
  log_success "SCC openclaw-authbridge applied"
else
  log_warn "Could not apply SCC (may already exist or need cluster-admin)"
fi

# Create ClusterRoleBinding for this namespace
cat <<EOF | $KUBECTL apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openclaw-authbridge-scc-${NPS_AGENT_NAMESPACE}
subjects:
- kind: ServiceAccount
  name: nps-agent-oauth-proxy
  namespace: ${NPS_AGENT_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: use-openclaw-authbridge-scc
EOF
log_success "SCC granted to nps-agent-oauth-proxy"
echo ""

# Apply AuthBridge ConfigMaps + Secret
log_info "Deploying AuthBridge configuration..."
$KUBECTL apply -f "$REPO_ROOT/manifests/nps-agent/authbridge-configmaps.yaml" -n "$NPS_AGENT_NAMESPACE"
$KUBECTL apply -f "$REPO_ROOT/manifests/nps-agent/authbridge-secret.yaml" -n "$NPS_AGENT_NAMESPACE"
log_success "AuthBridge configuration deployed"
echo ""

# Apply ServiceAccount
log_info "Creating ServiceAccount..."
$KUBECTL apply -f "$REPO_ROOT/manifests/nps-agent/nps-agent-rbac.yaml" -n "$NPS_AGENT_NAMESPACE"
log_success "ServiceAccount created"
echo ""

# Apply BuildConfig + ImageStream
log_info "Creating build from GitHub repo..."
$KUBECTL apply -f "$REPO_ROOT/manifests/nps-agent/nps-agent-buildconfig.yaml" -n "$NPS_AGENT_NAMESPACE"
log_success "BuildConfig created (source: https://github.com/Nehanth/nps_agent)"
echo ""

# Wait for build
log_info "Starting build..."
BUILD_NAME=$($KUBECTL get builds -n "$NPS_AGENT_NAMESPACE" -l buildconfig=nps-agent --sort-by='{.metadata.creationTimestamp}' -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
if [ -z "$BUILD_NAME" ]; then
  $KUBECTL start-build nps-agent -n "$NPS_AGENT_NAMESPACE" 2>/dev/null || true
  sleep 5
  BUILD_NAME=$($KUBECTL get builds -n "$NPS_AGENT_NAMESPACE" -l buildconfig=nps-agent --sort-by='{.metadata.creationTimestamp}' -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
fi

if [ -n "$BUILD_NAME" ]; then
  log_info "Waiting for build $BUILD_NAME to complete (this may take a few minutes)..."
  $KUBECTL wait --for=jsonpath='{.status.phase}'=Complete "build/$BUILD_NAME" -n "$NPS_AGENT_NAMESPACE" --timeout=600s 2>/dev/null || {
    log_warn "Build may still be running. Check: oc logs -f build/$BUILD_NAME -n $NPS_AGENT_NAMESPACE"
  }
  log_success "Build complete"
else
  log_warn "Could not find build — check manually: oc get builds -n $NPS_AGENT_NAMESPACE"
fi
echo ""

# Run envsubst on deployment template
log_info "Generating deployment manifest..."
envsubst '${NPS_AGENT_NAMESPACE}' < "$REPO_ROOT/manifests/nps-agent/nps-agent-deployment.yaml.envsubst" \
  > "$REPO_ROOT/manifests/nps-agent/nps-agent-deployment.yaml"
log_success "Generated nps-agent-deployment.yaml"
echo ""

# Apply A2A bridge ConfigMap
log_info "Deploying A2A bridge..."
$KUBECTL apply -f "$REPO_ROOT/manifests/nps-agent/nps-agent-a2a-bridge.yaml" -n "$NPS_AGENT_NAMESPACE"
log_success "A2A bridge ConfigMap deployed"
echo ""

# Apply Deployment + Service + Route
log_info "Deploying NPS Agent..."
$KUBECTL apply -f "$REPO_ROOT/manifests/nps-agent/nps-agent-deployment.yaml" -n "$NPS_AGENT_NAMESPACE"
$KUBECTL apply -f "$REPO_ROOT/manifests/nps-agent/nps-agent-service.yaml" -n "$NPS_AGENT_NAMESPACE"
$KUBECTL apply -f "$REPO_ROOT/manifests/nps-agent/nps-agent-route.yaml" -n "$NPS_AGENT_NAMESPACE"
log_success "NPS Agent deployed"
echo ""

# Wait for rollout
log_info "Waiting for NPS Agent to be ready..."
$KUBECTL rollout status deployment/nps-agent -n "$NPS_AGENT_NAMESPACE" --timeout=300s 2>/dev/null || {
  log_warn "Deployment not ready yet — check: oc get pods -n $NPS_AGENT_NAMESPACE"
}
log_success "NPS Agent ready"
echo ""

# Get route
NPS_ROUTE=$($KUBECTL get route nps-agent -n "$NPS_AGENT_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  NPS Agent Deployment Complete!                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "A2A endpoint (in-cluster):"
echo "  http://nps-agent.${NPS_AGENT_NAMESPACE}.svc.cluster.local:8080/"
echo ""
if [ -n "$NPS_ROUTE" ]; then
echo "External URL:"
echo "  https://${NPS_ROUTE}"
echo ""
fi
echo "Agent card:"
echo "  curl -s http://nps-agent.${NPS_AGENT_NAMESPACE}.svc.cluster.local:8080/.well-known/agent.json | jq ."
echo ""
echo "SPIRE registration (cluster admin must run this):"
echo "  kubectl exec -n spire-system spire-server-0 -- \\"
echo "    /opt/spire/bin/spire-server entry create \\"
echo "    -spiffeID spiffe://demo.example.com/ns/${NPS_AGENT_NAMESPACE}/sa/nps-agent-oauth-proxy \\"
echo "    -parentID spiffe://demo.example.com/ns/spire-system/sa/spire-agent \\"
echo "    -selector k8s:ns:${NPS_AGENT_NAMESPACE} \\"
echo "    -selector k8s:sa:nps-agent-oauth-proxy"
echo ""
