#!/usr/bin/env bash
# ============================================================================
# EDGE AGENT SETUP SCRIPT
# ============================================================================
# Run this ON the Linux machine that will be managed by the central gateway.
# Installs OpenClaw as a podman Quadlet (systemd-managed container).
#
# Usage:
#   ./setup-edge.sh                # Interactive setup
#   ./setup-edge.sh --uninstall    # Remove everything
#
# Prerequisites:
#   - Fedora 39+ / RHEL 9+ / CentOS Stream 9+
#   - podman (installed by default on Fedora/RHEL)
#   - SELinux enforcing (recommended, script verifies)
#
# What this script does:
#   1. Verifies prerequisites (podman, systemd, SELinux)
#   2. Prompts for configuration (model endpoint, agent name, OTEL)
#   3. Generates openclaw.json from template
#   4. Generates Pod YAML, ConfigMap YAML, and Secret YAML for .kube Quadlets
#   5. Installs .kube + generated YAML files into ~/.config/containers/systemd/
#   6. Pulls the container image
#   7. Enables lingering + reloads systemd (does NOT start the agent)
#
# After setup:
#   systemctl --user start openclaw-agent    # Start manually (or let supervisor do it)
#   journalctl --user -u openclaw-agent -f   # Watch logs
#   curl -H "Authorization: Bearer <token>" http://127.0.0.1:18789/v1/chat/completions
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Flags ──────────────────────────────────────────────────────────────────
UNINSTALL=false
for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=true ;;
  esac
done

# ── Colors ─────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; }

# Helper: indent content for YAML block scalar embedding
indent_yaml() {
  sed 's/^/    /'
}

# ── Uninstall ──────────────────────────────────────────────────────────────
if $UNINSTALL; then
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║  OpenClaw Edge Agent — Uninstall                           ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""

  log_info "Stopping services..."
  systemctl --user stop openclaw-agent 2>/dev/null || true
  systemctl --user stop otel-collector 2>/dev/null || true

  log_info "Removing Quadlet files..."
  rm -f ~/.config/containers/systemd/openclaw-agent.kube
  rm -f ~/.config/containers/systemd/openclaw-agent-pod.yaml
  rm -f ~/.config/containers/systemd/openclaw-agent-config.yaml
  rm -f ~/.config/containers/systemd/openclaw-agent-secret.yaml
  rm -f ~/.config/containers/systemd/openclaw-agent-agents.yaml
  rm -f ~/.config/containers/systemd/otel-collector.kube
  rm -f ~/.config/containers/systemd/otel-collector-pod.yaml
  rm -f ~/.config/containers/systemd/otel-collector-config.yaml
  # Also clean up old .container/.volume files from previous setup
  rm -f ~/.config/containers/systemd/openclaw-agent.container
  rm -f ~/.config/containers/systemd/openclaw-config.volume
  rm -f ~/.config/containers/systemd/otel-collector.container
  rm -f ~/.config/containers/systemd/otel-collector-config.volume

  log_info "Reloading systemd..."
  systemctl --user daemon-reload

  log_warn "Volume data preserved. To remove all data:"
  log_warn "  podman volume rm openclaw-data"

  log_success "Uninstalled."
  exit 0
fi

# ── Banner ─────────────────────────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  OpenClaw Edge Agent Setup                                 ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# ── Prerequisites ──────────────────────────────────────────────────────────
log_info "Checking prerequisites..."

# podman
if ! command -v podman &> /dev/null; then
  log_error "podman not found. Install with: sudo dnf install -y podman"
  exit 1
fi
PODMAN_VERSION=$(podman --version | awk '{print $NF}')
log_success "podman $PODMAN_VERSION"

# systemd
if ! command -v systemctl &> /dev/null; then
  log_error "systemd not found. Quadlet requires systemd."
  exit 1
fi
log_success "systemd $(systemctl --version | head -1 | awk '{print $2}')"

# Quadlet support (podman 4.4+, rootless)
QUADLET_DIR="${HOME}/.config/containers/systemd"
if [ ! -d "$QUADLET_DIR" ]; then
  log_info "Creating $QUADLET_DIR..."
  mkdir -p "$QUADLET_DIR"
fi
log_success "Quadlet directory: $QUADLET_DIR"

# SELinux
SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Unknown")
if [ "$SELINUX_STATUS" = "Enforcing" ]; then
  log_success "SELinux: Enforcing"
elif [ "$SELINUX_STATUS" = "Permissive" ]; then
  log_warn "SELinux: Permissive (recommend Enforcing for production)"
else
  log_warn "SELinux: $SELINUX_STATUS"
fi

# Hostname
HOSTNAME=$(hostnamectl --static 2>/dev/null || hostname)
log_success "Hostname: $HOSTNAME"

echo ""

# ── Load existing .env if re-running ───────────────────────────────────────
ENV_FILE="$EDGE_ROOT/.env.edge"
_ENV_REUSE=false
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  _ENV_REUSE=true
  log_success "Re-run detected — loading config from .env.edge"
  echo ""
fi

# ── Agent identity ─────────────────────────────────────────────────────────
if $_ENV_REUSE && [ -n "${AGENT_ID:-}" ]; then
  log_success "Agent ID: $AGENT_ID"
  log_success "Agent name: $AGENT_NAME"
else
  log_info "Agent identity for this machine:"
  echo ""

  DEFAULT_ID="edge_$(echo "$HOSTNAME" | tr '.-' '_' | tr '[:upper:]' '[:lower:]')"
  read -p "  Agent ID [$DEFAULT_ID]: " AGENT_ID
  AGENT_ID="${AGENT_ID:-$DEFAULT_ID}"

  DEFAULT_NAME="$HOSTNAME Agent"
  read -p "  Agent display name [$DEFAULT_NAME]: " AGENT_NAME
  AGENT_NAME="${AGENT_NAME:-$DEFAULT_NAME}"
fi
echo ""

# ── Gateway token ──────────────────────────────────────────────────────────
if $_ENV_REUSE && [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
  log_success "Gateway token: (set)"
else
  OPENCLAW_GATEWAY_TOKEN=$(openssl rand -base64 32)
  log_success "Generated gateway token"
fi

# ── Model provider ─────────────────────────────────────────────────────────
if $_ENV_REUSE && [ -n "${MODEL_ENDPOINT:-}" ]; then
  log_success "Model endpoint: $MODEL_ENDPOINT"
  log_success "Model: $MODEL_NAME ($MODEL_ID)"
else
  log_info "Model provider configuration:"
  echo ""
  echo "  The edge agent needs access to an LLM. Options:"
  echo "    1. Local LLM (e.g., RHEL Lightspeed on this machine — localhost:8888)"
  echo "    2. Central model server (e.g., vLLM on OpenShift)"
  echo "    3. Cloud API (e.g., Anthropic, OpenAI)"
  echo ""

  read -p "  Model endpoint URL [http://127.0.0.1:8888/v1]: " MODEL_ENDPOINT
  MODEL_ENDPOINT="${MODEL_ENDPOINT:-http://127.0.0.1:8888/v1}"

  read -p "  Model API type [openai-completions]: " MODEL_API
  MODEL_API="${MODEL_API:-openai-completions}"

  read -sp "  API key [fakekey]: " MODEL_API_KEY
  echo ""
  MODEL_API_KEY="${MODEL_API_KEY:-fakekey}"

  read -p "  Model ID [models/Phi-4-mini-instruct-Q4_K_M.gguf]: " MODEL_ID
  MODEL_ID="${MODEL_ID:-models/Phi-4-mini-instruct-Q4_K_M.gguf}"

  read -p "  Model display name [Phi-4 Mini]: " MODEL_NAME
  MODEL_NAME="${MODEL_NAME:-Phi-4 Mini}"
fi
echo ""

# ── Anthropic API key (optional) ──────────────────────────────────────────
if $_ENV_REUSE && [ -n "${ANTHROPIC_API_KEY+x}" ]; then
  if [ -n "$ANTHROPIC_API_KEY" ]; then
    log_success "Anthropic API key: (set)"
  else
    log_success "Anthropic API key: (none)"
  fi
else
  log_info "Optional: provide an Anthropic API key for Claude."
  log_info "The local model remains available as fallback."
  echo ""
  read -sp "  Anthropic API key (leave empty to skip): " ANTHROPIC_API_KEY
  echo ""
  if [ -n "$ANTHROPIC_API_KEY" ]; then
    log_success "Anthropic provider configured (Claude Sonnet 4.6)"
  fi
fi
echo ""

# ── OTEL (optional) ───────────────────────────────────────────────────────
if $_ENV_REUSE && [ -n "${OTEL_ENABLED:-}" ]; then
  log_success "OTEL: $OTEL_ENABLED"
  if [ "$OTEL_ENABLED" = "true" ]; then
    log_success "  MLflow endpoint: $MLFLOW_OTLP_ENDPOINT"
    log_success "  Collector image: $OTEL_COLLECTOR_IMAGE"
  fi
else
  log_info "OTEL observability (local collector forwards traces to central MLflow):"
  echo ""
  read -p "  Enable OTEL? [y/N]: " OTEL_ANSWER
  if [[ "${OTEL_ANSWER,,}" =~ ^y ]]; then
    OTEL_ENABLED="true"
    # OpenClaw agent always sends to localhost collector
    OTEL_ENDPOINT="http://127.0.0.1:4318"

    echo ""
    log_info "The local OTEL collector will forward traces to your MLflow instance."
    read -p "  MLflow OTLP endpoint (e.g., https://mlflow-route.apps.cluster.com): " MLFLOW_OTLP_ENDPOINT
    if [ -z "$MLFLOW_OTLP_ENDPOINT" ]; then
      log_error "MLflow endpoint is required when OTEL is enabled."
      exit 1
    fi

    read -p "  MLflow experiment ID [4]: " MLFLOW_EXPERIMENT_ID
    MLFLOW_EXPERIMENT_ID="${MLFLOW_EXPERIMENT_ID:-4}"

    # TLS: if endpoint is HTTPS, use secure; if HTTP, insecure
    if [[ "$MLFLOW_OTLP_ENDPOINT" =~ ^https:// ]]; then
      MLFLOW_TLS_INSECURE="false"
    else
      MLFLOW_TLS_INSECURE="true"
    fi

    read -p "  OTEL collector image [ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:latest]: " OTEL_COLLECTOR_IMAGE
    OTEL_COLLECTOR_IMAGE="${OTEL_COLLECTOR_IMAGE:-ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:latest}"
  else
    OTEL_ENABLED="false"
    OTEL_ENDPOINT="http://127.0.0.1:4318"
    MLFLOW_OTLP_ENDPOINT=""
    MLFLOW_EXPERIMENT_ID=""
    MLFLOW_TLS_INSECURE="true"
    OTEL_COLLECTOR_IMAGE=""
  fi
fi
echo ""

# ── Container images ──────────────────────────────────────────────────────
if $_ENV_REUSE && [ -n "${OPENCLAW_IMAGE:-}" ]; then
  log_success "Image: $OPENCLAW_IMAGE"
else
  read -p "  OpenClaw container image [quay.io/aicatalyst/openclaw:latest]: " OPENCLAW_IMAGE
  OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-quay.io/aicatalyst/openclaw:latest}"
fi
echo ""

# ── Save .env.edge ─────────────────────────────────────────────────────────
log_info "Saving configuration to .env.edge..."
cat > "$ENV_FILE" <<EOF
# OpenClaw Edge Agent Configuration
# Generated by setup-edge.sh — DO NOT COMMIT
AGENT_ID="$AGENT_ID"
AGENT_NAME="$AGENT_NAME"
OPENCLAW_GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN"
MODEL_ENDPOINT="$MODEL_ENDPOINT"
MODEL_API="$MODEL_API"
MODEL_API_KEY="$MODEL_API_KEY"
MODEL_ID="$MODEL_ID"
MODEL_NAME="$MODEL_NAME"
ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
OTEL_ENABLED="$OTEL_ENABLED"
OTEL_ENDPOINT="$OTEL_ENDPOINT"
MLFLOW_OTLP_ENDPOINT="$MLFLOW_OTLP_ENDPOINT"
MLFLOW_EXPERIMENT_ID="$MLFLOW_EXPERIMENT_ID"
MLFLOW_TLS_INSECURE="$MLFLOW_TLS_INSECURE"
OTEL_COLLECTOR_IMAGE="$OTEL_COLLECTOR_IMAGE"
OPENCLAW_IMAGE="$OPENCLAW_IMAGE"
EOF
log_success "Saved .env.edge"

# ── Generate openclaw.json ─────────────────────────────────────────────────
log_info "Generating openclaw.json..."

ENVSUBST_VARS='${AGENT_ID} ${AGENT_NAME} ${OPENCLAW_GATEWAY_TOKEN}'
ENVSUBST_VARS+=' ${MODEL_ENDPOINT} ${MODEL_API} ${MODEL_API_KEY} ${MODEL_ID} ${MODEL_NAME}'
ENVSUBST_VARS+=' ${OTEL_ENABLED} ${OTEL_ENDPOINT}'

export AGENT_ID AGENT_NAME OPENCLAW_GATEWAY_TOKEN
export MODEL_ENDPOINT MODEL_API MODEL_API_KEY MODEL_ID MODEL_NAME
export OTEL_ENABLED OTEL_ENDPOINT

GENERATED_CONFIG="$EDGE_ROOT/config/openclaw.json"
envsubst "$ENVSUBST_VARS" < "$EDGE_ROOT/config/openclaw.json.envsubst" > "$GENERATED_CONFIG"

# Inject extra provider if API key was provided
# The API key is passed via environment variable (not stored in config JSON)
# so the agent's exec sandbox can't access it — OpenClaw strips ANTHROPIC_API_KEY
# from child process environments (see sanitize-env-vars.ts)
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  python3 -c "
import json
with open('$GENERATED_CONFIG') as f:
    config = json.load(f)
# Add anthropic provider with explicit model + cost data
config['models']['providers']['anthropic'] = {
    'baseUrl': 'https://api.anthropic.com',
    'api': 'anthropic-messages',
    'models': [{
        'id': 'claude-sonnet-4-6',
        'name': 'Claude Sonnet 4.6',
        'reasoning': False,
        'input': ['text', 'image'],
        'cost': {'input': 3, 'output': 15, 'cacheRead': 0.3, 'cacheWrite': 3.75},
        'contextWindow': 200000,
        'maxTokens': 16384
    }]
}
# Set default agent model to Anthropic, local model as fallback
config['agents']['defaults']['model'] = {
    'primary': 'anthropic/claude-sonnet-4-6',
    'fallbacks': ['default/$MODEL_ID']
}
for agent in config['agents']['list']:
    agent['model'] = {
        'primary': 'anthropic/claude-sonnet-4-6',
        'fallbacks': ['default/$MODEL_ID']
    }
with open('$GENERATED_CONFIG', 'w') as f:
    json.dump(config, f, indent=2)
"
  log_success "Anthropic provider added (key via env var, local model as fallback)"
fi
log_success "Generated config/openclaw.json"

# ── Generate AGENTS.md and agent.json ─────────────────────────────────────
log_info "Generating agent files..."

AGENT_ENVSUBST_VARS='${AGENT_ID} ${AGENT_NAME} ${HOSTNAME}'
export HOSTNAME

GENERATED_AGENTS_MD="$EDGE_ROOT/config/AGENTS.md"
envsubst "$AGENT_ENVSUBST_VARS" < "$EDGE_ROOT/config/AGENTS.md.envsubst" > "$GENERATED_AGENTS_MD"

GENERATED_AGENT_JSON="$EDGE_ROOT/config/agent.json"
cat > "$GENERATED_AGENT_JSON" <<EOF
{
  "name": "$AGENT_ID",
  "display_name": "$AGENT_NAME",
  "description": "Edge Linux system observer and administrator",
  "emoji": "🖥️",
  "color": "#2ECC71",
  "capabilities": ["system-diagnostics", "monitoring", "linux-admin"],
  "tags": ["edge", "linux", "system"],
  "version": "1.0.0"
}
EOF

log_success "Generated config/AGENTS.md and config/agent.json"

# Generate OTEL collector config if enabled
if [ "$OTEL_ENABLED" = "true" ]; then
  OTEL_ENVSUBST_VARS='${HOSTNAME} ${MLFLOW_OTLP_ENDPOINT} ${MLFLOW_EXPERIMENT_ID} ${MLFLOW_TLS_INSECURE}'
  export MLFLOW_OTLP_ENDPOINT MLFLOW_EXPERIMENT_ID MLFLOW_TLS_INSECURE

  GENERATED_OTEL_CONFIG="$EDGE_ROOT/config/otel-collector-config.yaml"
  envsubst "$OTEL_ENVSUBST_VARS" < "$EDGE_ROOT/config/otel-collector-config.yaml.envsubst" > "$GENERATED_OTEL_CONFIG"
  log_success "Generated config/otel-collector-config.yaml"
fi

# ── Generate Kube YAML files ──────────────────────────────────────────────
log_info "Generating Kube YAML files..."

GENERATED_DIR="$EDGE_ROOT/generated"
mkdir -p "$GENERATED_DIR"

# --- Pod YAML (envsubst for image name) ---
export OPENCLAW_IMAGE
envsubst '${OPENCLAW_IMAGE}' < "$EDGE_ROOT/quadlet/openclaw-agent-pod.yaml.envsubst" > "$GENERATED_DIR/openclaw-agent-pod.yaml"

# --- ConfigMap: openclaw.json (embed generated JSON into YAML) ---
cat > "$GENERATED_DIR/openclaw-agent-config.yaml" <<CONFIGMAP_EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: openclaw-agent-config
data:
  openclaw.json: |
$(cat "$GENERATED_CONFIG" | indent_yaml)
CONFIGMAP_EOF

# --- ConfigMap: gateway token + API keys (podman doesn't support Secret in --configmap) ---
export OPENCLAW_GATEWAY_TOKEN ANTHROPIC_API_KEY
envsubst '${OPENCLAW_GATEWAY_TOKEN} ${ANTHROPIC_API_KEY}' < "$EDGE_ROOT/quadlet/openclaw-agent-secret.yaml.envsubst" > "$GENERATED_DIR/openclaw-agent-secret.yaml"

# --- ConfigMap: AGENTS.md + agent.json (embed into YAML) ---
cat > "$GENERATED_DIR/openclaw-agent-agents.yaml" <<AGENTS_EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: openclaw-agent-agents
data:
  AGENTS.md: |
$(cat "$GENERATED_AGENTS_MD" | indent_yaml)
  agent.json: |
$(cat "$GENERATED_AGENT_JSON" | indent_yaml)
AGENTS_EOF

log_success "Generated openclaw-agent Pod YAML, ConfigMap, Secret, and Agents"

# --- OTEL collector (if enabled) ---
if [ "$OTEL_ENABLED" = "true" ]; then
  export OTEL_COLLECTOR_IMAGE
  envsubst '${OTEL_COLLECTOR_IMAGE}' < "$EDGE_ROOT/quadlet/otel-collector-pod.yaml.envsubst" > "$GENERATED_DIR/otel-collector-pod.yaml"

  cat > "$GENERATED_DIR/otel-collector-config.yaml" <<OTEL_CM_EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
data:
  config.yaml: |
$(cat "$GENERATED_OTEL_CONFIG" | indent_yaml)
OTEL_CM_EOF

  log_success "Generated otel-collector Pod YAML and ConfigMap"
fi

# ── Install Quadlet files ─────────────────────────────────────────────────
log_info "Installing Quadlet files..."

# Remove old .container/.volume files if they exist (migration from previous setup)
rm -f "$QUADLET_DIR/openclaw-agent.container"
rm -f "$QUADLET_DIR/openclaw-config.volume"
rm -f "$QUADLET_DIR/otel-collector.container"
rm -f "$QUADLET_DIR/otel-collector-config.volume"

# Install .kube file (static, no substitution needed)
cp "$EDGE_ROOT/quadlet/openclaw-agent.kube" "$QUADLET_DIR/openclaw-agent.kube"

# Install generated YAML files alongside the .kube file
cp "$GENERATED_DIR/openclaw-agent-pod.yaml" "$QUADLET_DIR/openclaw-agent-pod.yaml"
cp "$GENERATED_DIR/openclaw-agent-config.yaml" "$QUADLET_DIR/openclaw-agent-config.yaml"
cp "$GENERATED_DIR/openclaw-agent-secret.yaml" "$QUADLET_DIR/openclaw-agent-secret.yaml"
cp "$GENERATED_DIR/openclaw-agent-agents.yaml" "$QUADLET_DIR/openclaw-agent-agents.yaml"

# Install OTEL collector Quadlet if enabled
if [ "$OTEL_ENABLED" = "true" ]; then
  cp "$EDGE_ROOT/quadlet/otel-collector.kube" "$QUADLET_DIR/otel-collector.kube"
  cp "$GENERATED_DIR/otel-collector-pod.yaml" "$QUADLET_DIR/otel-collector-pod.yaml"
  cp "$GENERATED_DIR/otel-collector-config.yaml" "$QUADLET_DIR/otel-collector-config.yaml"
fi

log_success "Installed Quadlet files to $QUADLET_DIR/"

# ── Pull images ────────────────────────────────────────────────────────────
log_info "Pulling container images (this may take a moment)..."
podman pull "$OPENCLAW_IMAGE"
log_success "Image pulled: $OPENCLAW_IMAGE"

if [ "$OTEL_ENABLED" = "true" ]; then
  podman pull "$OTEL_COLLECTOR_IMAGE"
  log_success "Image pulled: $OTEL_COLLECTOR_IMAGE"
fi

# ── Enable lingering ──────────────────────────────────────────────────────
# Required so user services survive logout (critical for SSH-activated agents)
if ! loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q "yes"; then
  log_info "Enabling lingering for $USER (services persist after logout)..."
  sudo loginctl enable-linger "$USER"
  log_success "Lingering enabled"
else
  log_success "Lingering already enabled for $USER"
fi

# ── Reload systemd ────────────────────────────────────────────────────────
log_info "Reloading systemd..."
systemctl --user daemon-reload
log_success "systemd reloaded — Quadlet unit registered"

# ── Verify ─────────────────────────────────────────────────────────────────
echo ""
log_info "Verifying installation..."
if systemctl --user list-unit-files | grep -q openclaw-agent; then
  log_success "openclaw-agent.service is registered"
else
  log_warn "openclaw-agent.service not found — check Quadlet files in $QUADLET_DIR"
fi

AGENT_STATUS=$(systemctl --user is-active openclaw-agent 2>/dev/null || echo "inactive")
log_success "Agent status: $AGENT_STATUS (expected: inactive)"

if [ "$OTEL_ENABLED" = "true" ]; then
  if systemctl --user list-unit-files | grep -q otel-collector; then
    log_success "otel-collector.service is registered"
  else
    log_warn "otel-collector.service not found — check Quadlet files in $QUADLET_DIR"
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Setup Complete                                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  Agent ID:     $AGENT_ID"
echo "  Agent name:   $AGENT_NAME"
echo "  Image:        $OPENCLAW_IMAGE"
echo "  SELinux:      $SELINUX_STATUS"
echo "  OTEL:         $OTEL_ENABLED"
if [ "$OTEL_ENABLED" = "true" ]; then
echo "  MLflow:       $MLFLOW_OTLP_ENDPOINT"
echo "  Collector:    $OTEL_COLLECTOR_IMAGE"
fi
echo "  Gateway port: 18789 (loopback only)"
echo ""
echo "  Quadlet files:  $QUADLET_DIR/openclaw-agent.kube"
echo "                  $QUADLET_DIR/openclaw-agent-{pod,config,secret,agents}.yaml"
if [ "$OTEL_ENABLED" = "true" ]; then
echo "                  $QUADLET_DIR/otel-collector.kube"
echo "                  $QUADLET_DIR/otel-collector-{pod,config}.yaml"
fi
echo "  Saved settings: $ENV_FILE"
echo ""
echo "  Commands:"
if [ "$OTEL_ENABLED" = "true" ]; then
echo "    systemctl --user start otel-collector      # Start collector (before agent)"
fi
echo "    systemctl --user start openclaw-agent      # Start the agent"
echo "    systemctl --user stop openclaw-agent       # Stop the agent"
if [ "$OTEL_ENABLED" = "true" ]; then
echo "    systemctl --user stop otel-collector       # Stop collector"
fi
echo "    journalctl --user -u openclaw-agent -f     # Watch agent logs"
if [ "$OTEL_ENABLED" = "true" ]; then
echo "    journalctl --user -u otel-collector -f     # Watch collector logs"
fi
echo "    systemctl --user status openclaw-agent     # Check status"
echo ""
echo "  From the central supervisor (via SSH):"
echo "    ssh $(whoami)@$HOSTNAME 'systemctl --user start openclaw-agent'"
echo ""
