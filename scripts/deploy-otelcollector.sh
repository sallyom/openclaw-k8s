#!/usr/bin/env bash
# ============================================================================
# OTEL COLLECTOR DEPLOYMENT
# ============================================================================
# Deploys the OpenTelemetry sidecar collector for trace export to MLflow.
# Can be run standalone or called from setup.sh.
#
# Usage:
#   ./scripts/deploy-otelcollector.sh                         # Interactive
#   ./scripts/deploy-otelcollector.sh --env-file path/to/.env # Use specific .env
#   ./scripts/deploy-otelcollector.sh --k8s                   # Use kubectl
#
# Prerequisites:
#   - OpenTelemetry Operator installed on the cluster
#   - OpenClaw namespace exists (run setup.sh first)
#   - MLflow instance accessible from the cluster
#
# The collector runs as a sidecar (auto-injected by the OTel Operator) and
# forwards OTLP traces from OpenClaw to MLflow.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse flags
K8S_MODE=false
ENV_FILE=""
NO_RESTART=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s) K8S_MODE=true; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --no-restart) NO_RESTART=true; shift ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --env-file PATH   Use a specific .env file (default: .env)"
      echo "  --k8s             Use kubectl instead of oc"
      echo "  --no-restart      Skip OpenClaw restart (when called from setup.sh)"
      echo "  -h, --help        Show this help"
      exit 0
      ;;
    *) shift ;;
  esac
done
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

if $K8S_MODE; then
  KUBECTL="kubectl"
else
  if command -v oc &>/dev/null; then
    KUBECTL="oc"
  else
    KUBECTL="kubectl"
  fi
fi

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}→${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }

OTEL_TEMPLATE="$REPO_ROOT/platform/observability/openclaw-otel-sidecar.yaml.envsubst"
OTEL_YAML="${OTEL_TEMPLATE%.envsubst}"

if [ ! -f "$OTEL_TEMPLATE" ]; then
  log_error "OTEL sidecar template not found: $OTEL_TEMPLATE"
  exit 1
fi

echo ""
echo "============================================"
echo "  OTEL Collector Deployment"
echo "============================================"
echo ""

# Load .env if it exists
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ENV_FILE"
  set +a
  log_success "Loaded $ENV_FILE"
fi

# Namespace (required)
if [ -z "${OPENCLAW_NAMESPACE:-}" ]; then
  read -p "  OpenClaw namespace: " OPENCLAW_NAMESPACE
  if [ -z "$OPENCLAW_NAMESPACE" ]; then
    log_error "Namespace is required"
    exit 1
  fi
fi
log_info "Namespace: $OPENCLAW_NAMESPACE"

# Verify namespace exists
if ! $KUBECTL get namespace "$OPENCLAW_NAMESPACE" &>/dev/null; then
  log_error "Namespace $OPENCLAW_NAMESPACE does not exist. Run setup.sh first."
  exit 1
fi

# MLflow tracking URI
if [ -z "${MLFLOW_TRACKING_URI:-}" ]; then
  echo ""
  log_info "MLflow tracking URI (where traces are exported):"
  log_info "  Example: https://mlflow-openclaw.apps.example.com"
  read -p "  MLflow URI: " MLFLOW_TRACKING_URI
  if [ -z "$MLFLOW_TRACKING_URI" ]; then
    log_error "MLflow URI is required for the OTEL collector"
    exit 1
  fi
fi
log_success "MLflow URI: $MLFLOW_TRACKING_URI"

# MLflow experiment ID
if [ -z "${MLFLOW_EXPERIMENT_ID:-}" ] || [ "${MLFLOW_EXPERIMENT_ID}" = "0" ]; then
  read -p "  MLflow experiment ID [0]: " MLFLOW_EXPERIMENT_ID
  MLFLOW_EXPERIMENT_ID="${MLFLOW_EXPERIMENT_ID:-0}"
fi
log_success "Experiment ID: $MLFLOW_EXPERIMENT_ID"

# Derive TLS setting from URI scheme
if [[ "$MLFLOW_TRACKING_URI" =~ ^https:// ]]; then
  MLFLOW_TLS_INSECURE="false"
else
  MLFLOW_TLS_INSECURE="true"
fi

export OPENCLAW_NAMESPACE MLFLOW_TRACKING_URI MLFLOW_EXPERIMENT_ID MLFLOW_TLS_INSECURE
echo ""

# Run envsubst
log_info "Generating OTEL collector manifest..."
ENVSUBST_VARS='${OPENCLAW_NAMESPACE} ${MLFLOW_TRACKING_URI} ${MLFLOW_EXPERIMENT_ID} ${MLFLOW_TLS_INSECURE}'
envsubst "$ENVSUBST_VARS" < "$OTEL_TEMPLATE" > "$OTEL_YAML"
log_success "Generated $(basename "$OTEL_YAML")"

# Apply
log_info "Deploying OTEL sidecar collector..."
if $KUBECTL apply -f "$OTEL_YAML"; then
  log_success "OTEL sidecar collector deployed"
else
  log_error "Failed to deploy OTEL sidecar collector"
  log_warn "The OpenTelemetry Operator may not be installed. Install it, then re-run this script."
  exit 1
fi

# Restart OpenClaw to pick up the sidecar injection
if $NO_RESTART; then
  log_info "Skipping restart (--no-restart). OpenClaw will pick up the sidecar on next restart."
else
  log_info "Restarting OpenClaw to inject OTEL sidecar..."
  if $KUBECTL rollout restart deployment/openclaw -n "$OPENCLAW_NAMESPACE" 2>/dev/null; then
    $KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=300s 2>/dev/null
    log_success "OpenClaw restarted with OTEL sidecar"
  else
    log_warn "Could not restart OpenClaw — restart manually to pick up the sidecar"
  fi
fi

echo ""
echo "============================================"
echo "  OTEL Collector Ready"
echo ""
echo "  Traces:      $MLFLOW_TRACKING_URI"
echo "  Experiment:  $MLFLOW_EXPERIMENT_ID"
echo "  TLS verify:  $([ "$MLFLOW_TLS_INSECURE" = "false" ] && echo "yes" || echo "no (HTTP)")"
echo "  Namespace:   $OPENCLAW_NAMESPACE"
echo "============================================"
echo ""
