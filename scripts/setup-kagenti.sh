#!/usr/bin/env bash
# ============================================================================
# KAGENTI PLATFORM SETUP
# ============================================================================
# Installs the Kagenti stack (SPIRE, cert-manager, Keycloak, operator, webhook,
# UI, MCP Gateway) on an OpenShift cluster. Run this BEFORE setup.sh --with-a2a.
#
# Usage:
#   ./scripts/setup-kagenti.sh                              # Interactive
#   ./scripts/setup-kagenti.sh --kagenti-repo /path/to/kagenti
#   ./scripts/setup-kagenti.sh --skip-ovn-patch             # Skip OVN gateway patch
#   ./scripts/setup-kagenti.sh --skip-mcp-gateway           # Skip MCP Gateway install
#
# Prerequisites:
#   - oc / kubectl with cluster-admin
#   - helm >= 3.18.0 (Helm 4 also works)
#   - Local clone of kagenti repo (use sallyom/kagenti branch charts-updated-webhook
#     until port exclusion annotations are merged upstream)
#
# Tested on: OCP 4.19+ (ROSA)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
KAGENTI_REPO="${KAGENTI_REPO:-}"
SKIP_OVN_PATCH=false
SKIP_MCP_GATEWAY=false
MCP_GATEWAY_VERSION="0.4.0"
DRY_RUN=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}→${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kagenti-repo)       KAGENTI_REPO="$2"; shift 2 ;;
    --skip-ovn-patch)     SKIP_OVN_PATCH=true; shift ;;
    --skip-mcp-gateway)   SKIP_MCP_GATEWAY=true; shift ;;
    --mcp-gateway-version) MCP_GATEWAY_VERSION="$2"; shift 2 ;;
    --dry-run)            DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --kagenti-repo PATH       Path to local kagenti repo clone"
      echo "  --skip-ovn-patch          Skip OVN gateway routing patch"
      echo "  --skip-mcp-gateway        Skip MCP Gateway installation"
      echo "  --mcp-gateway-version VER MCP Gateway chart version (default: $MCP_GATEWAY_VERSION)"
      echo "  --dry-run                 Show commands without executing"
      echo "  -h, --help                Show this help"
      exit 0
      ;;
    *) log_error "Unknown option: $1"; exit 1 ;;
  esac
done

run_cmd() {
  if $DRY_RUN; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

# ============================================================================
# Pre-flight checks
# ============================================================================
echo ""
echo "============================================"
echo "  Kagenti Platform Setup"
echo "============================================"
echo ""

# Check for kubectl/oc
if command -v oc &>/dev/null; then
  KUBECTL=oc
elif command -v kubectl &>/dev/null; then
  KUBECTL=kubectl
else
  log_error "Neither oc nor kubectl found in PATH"
  exit 1
fi

# Check cluster access
if ! $KUBECTL cluster-info &>/dev/null 2>&1; then
  log_error "Cannot connect to cluster. Run 'oc login' first."
  exit 1
fi
log_success "Connected to cluster"

# Check helm
if ! command -v helm &>/dev/null; then
  log_error "helm not found in PATH. Install helm >= 3.18.0"
  exit 1
fi
log_success "helm found: $(helm version --short)"

# Prompt for kagenti repo if not provided
if [ -z "$KAGENTI_REPO" ]; then
  DEFAULT_KAGENTI_REPO="$(cd "$REPO_ROOT/.." && pwd)/kagenti"
  if [ -d "$DEFAULT_KAGENTI_REPO/charts" ]; then
    log_info "Found kagenti repo at: $DEFAULT_KAGENTI_REPO"
    read -p "  Use this path? (Y/n): " -n 1 -r REPLY
    echo
    if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
      KAGENTI_REPO="$DEFAULT_KAGENTI_REPO"
    fi
  fi
  if [ -z "$KAGENTI_REPO" ]; then
    read -p "  Path to kagenti repo: " KAGENTI_REPO
  fi
fi

if [ ! -d "$KAGENTI_REPO/charts/kagenti-deps" ] || [ ! -d "$KAGENTI_REPO/charts/kagenti" ]; then
  log_error "Invalid kagenti repo: $KAGENTI_REPO (missing charts/kagenti-deps or charts/kagenti)"
  exit 1
fi
log_success "Kagenti repo: $KAGENTI_REPO"
echo ""

# ============================================================================
# Step 1: OVN Gateway Patch
# ============================================================================
log_info "Step 1: OVN Gateway Patch"

if $SKIP_OVN_PATCH; then
  log_info "Skipped (--skip-ovn-patch)"
else
  # Check if this is an OVNKubernetes cluster
  NETWORK_TYPE=$($KUBECTL get network.operator.openshift.io cluster -o jsonpath='{.spec.defaultNetwork.type}' 2>/dev/null || echo "unknown")
  if [ "$NETWORK_TYPE" = "OVNKubernetes" ]; then
    log_info "OVNKubernetes detected — applying routingViaHost patch"
    run_cmd $KUBECTL patch network.operator.openshift.io cluster --type=merge \
      -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'
    log_success "OVN gateway patch applied"
  else
    log_info "Network type: $NETWORK_TYPE — skipping OVN patch"
  fi
fi
echo ""

# ============================================================================
# Step 2: Detect Trust Domain
# ============================================================================
log_info "Step 2: Detect trust domain"

DOMAIN="apps.$($KUBECTL get dns cluster -o jsonpath='{ .spec.baseDomain }' 2>/dev/null || echo "")"
if [ "$DOMAIN" = "apps." ] || [ -z "$DOMAIN" ]; then
  log_warn "Could not auto-detect cluster domain"
  read -p "  Enter trust domain (e.g. apps.example.com): " DOMAIN
fi
export DOMAIN
log_success "Trust domain: $DOMAIN"
echo ""

# ============================================================================
# Step 3: Install kagenti-deps (SPIRE + cert-manager)
# ============================================================================
log_info "Step 3: Install kagenti-deps (SPIRE + cert-manager)"

if helm status kagenti-deps -n kagenti-system &>/dev/null 2>&1; then
  log_info "kagenti-deps already installed — upgrading"
  run_cmd helm upgrade kagenti-deps "$KAGENTI_REPO/charts/kagenti-deps/" \
    -n kagenti-system \
    --set spire.trustDomain="${DOMAIN}" --wait
else
  log_info "Installing kagenti-deps..."
  run_cmd helm dependency update "$KAGENTI_REPO/charts/kagenti-deps/"
  run_cmd helm install kagenti-deps "$KAGENTI_REPO/charts/kagenti-deps/" \
    -n kagenti-system --create-namespace \
    --set spire.trustDomain="${DOMAIN}" --wait
fi
log_success "kagenti-deps installed"
echo ""

# ============================================================================
# Step 4: Install MCP Gateway
# ============================================================================
log_info "Step 4: Install MCP Gateway"

if $SKIP_MCP_GATEWAY; then
  log_info "Skipped (--skip-mcp-gateway)"
elif helm status mcp-gateway -n mcp-system &>/dev/null 2>&1; then
  log_info "MCP Gateway already installed — skipping"
else
  log_info "Installing MCP Gateway v${MCP_GATEWAY_VERSION}..."
  run_cmd helm install mcp-gateway oci://ghcr.io/kagenti/charts/mcp-gateway \
    --create-namespace --namespace mcp-system --version "$MCP_GATEWAY_VERSION"
  log_success "MCP Gateway installed"
fi
echo ""

# ============================================================================
# Step 5: Install Kagenti (Keycloak + operator + webhook + UI)
# ============================================================================
log_info "Step 5: Install Kagenti (Keycloak + operator + webhook + UI)"

# Secrets file
SECRETS_FILE="$KAGENTI_REPO/charts/kagenti/.secrets.yaml"
SECRETS_TEMPLATE="$KAGENTI_REPO/charts/kagenti/.secrets_template.yaml"
if [ ! -f "$SECRETS_FILE" ]; then
  if [ -f "$SECRETS_TEMPLATE" ]; then
    log_info "Creating .secrets.yaml from template"
    cp "$SECRETS_TEMPLATE" "$SECRETS_FILE"
    log_warn "Edit $SECRETS_FILE if you need custom secrets (e.g. Keycloak admin password)"
  else
    log_error "No .secrets_template.yaml found at $SECRETS_TEMPLATE"
    exit 1
  fi
fi

# Get latest tag
log_info "Detecting latest kagenti release tag..."
LATEST_TAG=$(git ls-remote --tags --sort="v:refname" https://github.com/kagenti/kagenti.git | tail -n1 | sed 's|.*refs/tags/v||; s/\^{}//')
if [ -z "$LATEST_TAG" ]; then
  log_warn "Could not detect latest tag — using 'latest'"
  LATEST_TAG="latest"
fi
log_success "Using tag: v${LATEST_TAG}"

run_cmd helm dependency update "$KAGENTI_REPO/charts/kagenti/"

# Detect Keycloak public URL from route (for OIDC redirects in the browser).
# The internal URL (keycloak-service.keycloak:8080) is NOT reachable from outside the cluster.
KC_ROUTE=$($KUBECTL get route keycloak -n keycloak -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$KC_ROUTE" ]; then
  KEYCLOAK_PUBLIC_URL="https://${KC_ROUTE}"
  log_success "Keycloak public URL: $KEYCLOAK_PUBLIC_URL"
else
  # Fallback: construct from cluster domain
  KEYCLOAK_PUBLIC_URL="https://keycloak-keycloak.${DOMAIN}"
  log_warn "Keycloak route not found — using constructed URL: $KEYCLOAK_PUBLIC_URL"
fi

run_cmd helm upgrade --install kagenti "$KAGENTI_REPO/charts/kagenti/" \
  -n kagenti-system --create-namespace \
  -f "$SECRETS_FILE" \
  --set ui.frontend.tag="v${LATEST_TAG}" \
  --set ui.backend.tag="v${LATEST_TAG}" \
  --set "agentOAuthSecret.spiffePrefix=spiffe://${DOMAIN}/sa" \
  --set uiOAuthSecret.useServiceAccountCA=false \
  --set agentOAuthSecret.useServiceAccountCA=false \
  --set "keycloak.publicUrl=${KEYCLOAK_PUBLIC_URL}"

log_success "Kagenti installed"
echo ""

# ============================================================================
# Step 6: Verify
# ============================================================================
log_info "Step 6: Verify installation"
echo ""

log_info "SPIRE:"
$KUBECTL get daemonsets -n zero-trust-workload-identity-manager 2>/dev/null || log_warn "SPIRE daemonsets not found"
echo ""

log_info "Kagenti pods:"
$KUBECTL get pods -n kagenti-system 2>/dev/null || log_warn "No pods in kagenti-system"
echo ""

log_info "Keycloak pods:"
$KUBECTL get pods -n keycloak 2>/dev/null || log_warn "No pods in keycloak"
echo ""

# Kagenti UI URL
UI_HOST=$($KUBECTL get route kagenti-ui -n kagenti-system -o jsonpath='{.status.ingress[0].host}' 2>/dev/null || echo "")
if [ -n "$UI_HOST" ]; then
  log_success "Kagenti UI: https://$UI_HOST"
fi

# Keycloak admin credentials (master realm — for admin console only)
KC_SECRET=$($KUBECTL get secret keycloak-initial-admin -n keycloak -o go-template='Username: {{.data.username | base64decode}}  Password: {{.data.password | base64decode}}' 2>/dev/null || echo "")
if [ -n "$KC_SECRET" ]; then
  log_success "Keycloak admin (master realm): $KC_SECRET"
fi

echo ""
echo "============================================"
echo "  Kagenti platform is ready!"
echo ""
echo "  Namespace registration:"
echo "    Namespaces self-register for webhook injection via label:"
echo "      kubectl label namespace <ns> kagenti-enabled=true"
echo "    setup.sh --with-a2a does this automatically."
echo ""
echo "  Next: deploy OpenClaw with A2A:"
echo "    cd $REPO_ROOT"
echo "    ./scripts/setup.sh --with-a2a"
echo "============================================"
echo ""
