#!/usr/bin/env bash
# ============================================================================
# TEARDOWN SCRIPT
# ============================================================================
# Removes OpenClaw deployment and namespace.
#
# Usage:
#   ./teardown.sh                    # Teardown OpenShift (default)
#   ./teardown.sh --k8s              # Teardown vanilla Kubernetes
#   ./teardown.sh --delete-env       # Also delete .env file
#
# This script:
#   - Reads .env for namespace and prefix configuration
#   - Removes the auto-registered Keycloak client (SPIFFE ID)
#   - Deletes all resources in namespace before deleting namespace
#     (avoids finalizer hang during namespace deletion)
#   - Removes cluster-scoped OAuthClients (OpenShift only)
#   - Strips finalizers from stuck namespaces
#   - Optionally deletes .env
#
# If .env doesn't exist, you can set OPENCLAW_NAMESPACE manually:
#   OPENCLAW_NAMESPACE=my-openclaw ./teardown.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse flags
K8S_MODE=false
DELETE_ENV=false
for arg in "$@"; do
  case "$arg" in
    --k8s) K8S_MODE=true ;;
    --delete-env) DELETE_ENV=true ;;
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
echo "║  OpenClaw Teardown                                         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Load .env if available
if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

# Determine namespace — env var takes precedence, then .env, then prompt
if [ -z "${OPENCLAW_NAMESPACE:-}" ]; then
  log_warn "No .env file and OPENCLAW_NAMESPACE not set."
  read -p "  Enter OpenClaw namespace to teardown (e.g., sallyom-openclaw): " OPENCLAW_NAMESPACE
  if [ -z "$OPENCLAW_NAMESPACE" ]; then
    log_error "Namespace is required."
    exit 1
  fi
fi

echo "Namespace to teardown:"
echo "  - $OPENCLAW_NAMESPACE"
echo ""

read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  log_info "Teardown cancelled"
  exit 0
fi
echo ""

# Delete all resources in a namespace before deleting the namespace itself.
# This avoids the common issue where namespace deletion hangs on finalizers.
teardown_namespace() {
  local ns="$1"

  if ! $KUBECTL get namespace "$ns" &>/dev/null; then
    log_warn "Namespace $ns does not exist — skipping"
    return 0
  fi

  log_info "Deleting resources in $ns..."

  # Workloads and services (oc delete all covers deployments, replicasets,
  # pods, services, daemonsets, statefulsets, replicationcontrollers, buildconfigs, builds, imagestreams)
  $KUBECTL delete all --all -n "$ns" --timeout=60s 2>/dev/null || true

  # Jobs (not included in 'all')
  $KUBECTL delete jobs --all -n "$ns" --timeout=30s 2>/dev/null || true
  $KUBECTL delete cronjobs --all -n "$ns" --timeout=30s 2>/dev/null || true

  # Config and secrets
  $KUBECTL delete configmaps --all -n "$ns" --timeout=30s 2>/dev/null || true
  $KUBECTL delete secrets --all -n "$ns" --timeout=30s 2>/dev/null || true

  # RBAC
  $KUBECTL delete serviceaccounts --all -n "$ns" --timeout=30s 2>/dev/null || true
  $KUBECTL delete roles --all -n "$ns" --timeout=30s 2>/dev/null || true
  $KUBECTL delete rolebindings --all -n "$ns" --timeout=30s 2>/dev/null || true

  # Storage
  $KUBECTL delete pvc --all -n "$ns" --timeout=60s 2>/dev/null || true

  # Security / availability
  $KUBECTL delete networkpolicies --all -n "$ns" --timeout=30s 2>/dev/null || true
  $KUBECTL delete poddisruptionbudgets --all -n "$ns" --timeout=30s 2>/dev/null || true
  $KUBECTL delete resourcequotas --all -n "$ns" --timeout=30s 2>/dev/null || true

  # OpenShift-specific
  if ! $K8S_MODE; then
    $KUBECTL delete routes --all -n "$ns" --timeout=30s 2>/dev/null || true
  fi

  log_success "Resources deleted from $ns"

  # Delete the namespace
  log_info "Deleting namespace $ns..."
  if $KUBECTL delete namespace "$ns" --timeout=60s 2>/dev/null; then
    log_success "Namespace $ns deleted"
  else
    log_warn "Namespace deletion timed out — removing finalizers..."
    $KUBECTL get namespace "$ns" -o json | \
      jq '.spec.finalizers = []' | \
      $KUBECTL replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
    # Wait briefly for it to disappear
    sleep 3
    if $KUBECTL get namespace "$ns" &>/dev/null; then
      log_error "Namespace $ns still exists. May need manual cleanup."
    else
      log_success "Namespace $ns deleted (finalizers stripped)"
    fi
  fi
  echo ""
}

# Teardown A2A / Keycloak resources (only if A2A was enabled)
A2A_ENABLED="${A2A_ENABLED:-false}"
if [ "$A2A_ENABLED" = "true" ]; then
  # Remove Keycloak client (auto-registered by AuthBridge using SPIFFE ID)
  KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak-spiffe-demo.apps.ocp-beta-test.nerc.mghpcc.org}"
  KEYCLOAK_REALM="${KEYCLOAK_REALM:-spiffe-demo}"
  KEYCLOAK_ADMIN_USERNAME="${KEYCLOAK_ADMIN_USERNAME:-admin}"
  KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin123}"
  SPIFFE_CLIENT_ID="spiffe://demo.example.com/ns/${OPENCLAW_NAMESPACE}/sa/openclaw-oauth-proxy"

  log_info "Removing Keycloak client for $OPENCLAW_NAMESPACE..."

  # Get admin token
  KC_TOKEN=$(curl -s --connect-timeout 5 -X POST \
    "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=client_credentials&client_id=admin-cli" \
    -d "grant_type=password&username=${KEYCLOAK_ADMIN_USERNAME}&password=${KEYCLOAK_ADMIN_PASSWORD}" \
    -H "Content-Type: application/x-www-form-urlencoded" 2>/dev/null | jq -r '.access_token // empty')

  if [ -n "$KC_TOKEN" ]; then
    # URL-encode the SPIFFE ID (contains :// and /)
    ENCODED_CLIENT_ID=$(printf '%s' "$SPIFFE_CLIENT_ID" | jq -sRr @uri)

    # Look up the client by clientId
    KC_CLIENT_UUID=$(curl -s \
      "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${ENCODED_CLIENT_ID}" \
      -H "Authorization: Bearer ${KC_TOKEN}" 2>/dev/null | jq -r '.[0].id // empty')

    if [ -n "$KC_CLIENT_UUID" ]; then
      if curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${KC_CLIENT_UUID}" \
        -H "Authorization: Bearer ${KC_TOKEN}" 2>/dev/null | grep -q "204"; then
        log_success "Keycloak client deleted: $SPIFFE_CLIENT_ID"
      else
        log_warn "Failed to delete Keycloak client (may need manual cleanup)"
      fi
    else
      log_warn "Keycloak client not found: $SPIFFE_CLIENT_ID (already removed or never registered)"
    fi
  else
    log_warn "Could not authenticate to Keycloak — skipping client cleanup"
    log_warn "  Manually remove client: $SPIFFE_CLIENT_ID"
    log_warn "  From realm: ${KEYCLOAK_REALM} at ${KEYCLOAK_URL}"
  fi
  echo ""

  # Remove cluster-scoped A2A resources (OpenShift only)
  if ! $K8S_MODE; then
    log_info "Removing SCC ClusterRoleBinding..."
    $KUBECTL delete clusterrolebinding "openclaw-authbridge-scc-${OPENCLAW_NAMESPACE}" 2>/dev/null && \
      log_success "ClusterRoleBinding openclaw-authbridge-scc-${OPENCLAW_NAMESPACE} deleted" || \
      log_warn "ClusterRoleBinding not found (already removed)"
    echo ""
  fi
else
  log_info "A2A was not enabled — skipping Keycloak/SCC cleanup"
  echo ""
fi

# Remove cluster-scoped resources (OpenShift only, non-A2A)
if ! $K8S_MODE; then
  log_info "Removing OpenClaw OAuthClient..."
  $KUBECTL delete oauthclient "$OPENCLAW_NAMESPACE" 2>/dev/null && \
    log_success "OAuthClient $OPENCLAW_NAMESPACE deleted" || \
    log_warn "OAuthClient $OPENCLAW_NAMESPACE not found (already removed)"
  echo ""
fi

teardown_namespace "$OPENCLAW_NAMESPACE"

# Optionally delete .env
if $DELETE_ENV && [ -f "$REPO_ROOT/.env" ]; then
  rm "$REPO_ROOT/.env"
  log_success "Deleted .env"
  echo ""
elif [ -f "$REPO_ROOT/.env" ]; then
  log_info ".env kept (use --delete-env to remove)"
  echo ""
fi

# Clean up generated YAML files (from envsubst)
log_info "Cleaning up generated YAML files..."
generated=0
for tpl in $(find "$REPO_ROOT/manifests" "$REPO_ROOT/observability" -name '*.envsubst' 2>/dev/null); do
  yaml="${tpl%.envsubst}"
  if [ -f "$yaml" ]; then
    rm "$yaml"
    generated=$((generated + 1))
  fi
done
if [ $generated -gt 0 ]; then
  log_success "Removed $generated generated YAML files"
else
  log_info "No generated YAML files to clean up"
fi
echo ""

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Teardown Complete                                         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "To redeploy, run: ./scripts/setup.sh$(if $K8S_MODE; then echo ' --k8s'; fi)"
echo ""
