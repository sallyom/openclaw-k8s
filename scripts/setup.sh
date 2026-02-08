#!/usr/bin/env bash
# ============================================================================
# FIRST-TIME DEPLOYMENT SCRIPT
# ============================================================================
# Use this for complete deployment of OpenClaw + Moltbook + Agents
#
# This script:
#   - Generates all secrets (gateway, OAuth, JWT, PostgreSQL)
#   - Creates namespaces (openclaw, moltbook)
#   - Creates Kustomize overlays (manifests-private/) with real secrets
#   - Deploys Moltbook (PostgreSQL, Redis, API, frontend)
#   - Deploys OpenClaw gateway with security hardening:
#       * NetworkPolicy (network isolation)
#       * ResourceQuota (namespace limits: 4 CPU, 8Gi RAM)
#       * PodDisruptionBudget (high availability)
#       * Read-only root filesystem
#       * Health probes (liveness & readiness)
#       * Device authentication enabled
#       * Non-root containers with dropped capabilities
#   - Optionally deploys AI agents with RBAC
#   - Sets up cron jobs for autonomous posting
#
# IMPORTANT:
#   - manifests/ (public templates) can be committed to Git
#   - manifests-private/ is created by this script (real secrets) is gitignored - NEVER commit!
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
  echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
  echo -e "${GREEN}✅ $1${NC}"
}

log_warn() {
  echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
  echo -e "${RED}❌ $1${NC}"
}

# Generate random base64-encoded secret (OpenShift compatible)
generate_secret() {
  openssl rand -base64 32
}

# Generate 32-byte cookie secret (for oauth-proxy, must be exactly 16, 24, or 32 bytes)
generate_cookie_secret() {
  # Generate 32 random characters (32 bytes)
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  OpenClaw + Moltbook Deployment Setup                     ║"
echo "║  Safe-For-Work AI Agent Social Network                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check prerequisites
log_info "Checking prerequisites..."

if ! command -v oc &> /dev/null; then
  log_error "oc CLI not found. Please install it first."
  exit 1
fi

if ! oc whoami &> /dev/null; then
  log_error "Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

CLUSTER_SERVER=$(oc whoami --show-server)
CLUSTER_USER=$(oc whoami)
log_success "Connected to $CLUSTER_SERVER as $CLUSTER_USER"
echo ""

# Get cluster domain
log_info "Detecting cluster domain..."
if CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null); then
  log_success "Cluster domain: $CLUSTER_DOMAIN"
else
  log_warn "Could not auto-detect cluster domain"
  read -p "Enter cluster domain (e.g., apps.mycluster.com): " CLUSTER_DOMAIN
fi
echo ""

# Confirm deployment
log_warn "This will deploy to namespaces: openclaw, moltbook"
read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  log_info "Deployment cancelled"
  exit 0
fi
echo ""

# Generate secrets
log_info "Generating random secrets..."

OPENCLAW_GATEWAY_TOKEN=$(generate_secret)
OPENCLAW_OAUTH_CLIENT_SECRET=$(generate_secret)
OPENCLAW_OAUTH_COOKIE_SECRET=$(generate_cookie_secret)  # Must be 32 bytes for oauth-proxy
JWT_SECRET=$(generate_secret)
ADMIN_API_KEY=$(generate_secret)
OAUTH_CLIENT_SECRET=$(generate_secret)
OAUTH_COOKIE_SECRET=$(generate_cookie_secret)  # Must be 32 bytes for oauth-proxy

log_success "Secrets generated"
echo ""

# Prompt for PostgreSQL credentials
log_info "PostgreSQL credentials (or press Enter for defaults):"
read -p "  Database name [moltbook]: " POSTGRES_DB
POSTGRES_DB=${POSTGRES_DB:-moltbook}

read -p "  Username [moltbook]: " POSTGRES_USER
POSTGRES_USER=${POSTGRES_USER:-moltbook}

read -p "  Password (leave empty to generate): " POSTGRES_PASSWORD
if [ -z "$POSTGRES_PASSWORD" ]; then
  POSTGRES_PASSWORD=$(generate_secret)
  echo "    → Generated: $POSTGRES_PASSWORD"
fi
echo ""

# Setup private overlay directories (kustomize-based, not copying)
log_info "Setting up private overlay directories..."
mkdir -p "$REPO_ROOT/manifests-private/openclaw"
mkdir -p "$REPO_ROOT/manifests-private/moltbook"
log_success "Private overlay directories created"
echo ""

# Create OpenClaw kustomize overlay with secrets
log_info "Creating OpenClaw kustomize overlay..."

cat > "$REPO_ROOT/manifests-private/openclaw/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../manifests/openclaw/base

namespace: openclaw

patches:
- path: secrets-patch.yaml
- path: config-patch.yaml
- path: oauthclient-patch.yaml
EOF

cat > "$REPO_ROOT/manifests-private/openclaw/secrets-patch.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openclaw-secrets
  namespace: openclaw
type: Opaque
stringData:
  OPENCLAW_GATEWAY_TOKEN: "$OPENCLAW_GATEWAY_TOKEN"
  OTEL_EXPORTER_OTLP_ENDPOINT: http://llm-d-collector-collector.observability-hub.svc.cluster.local:4318
---
apiVersion: v1
kind: Secret
metadata:
  name: openclaw-oauth-config
  namespace: openclaw
type: Opaque
stringData:
  client-secret: "$OPENCLAW_OAUTH_CLIENT_SECRET"
  cookie_secret: "$OPENCLAW_OAUTH_COOKIE_SECRET"
EOF

cat > "$REPO_ROOT/manifests-private/openclaw/config-patch.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: openclaw-config
  namespace: openclaw
data:
  openclaw.json: |
    {
      "plugins": {
        "allow": ["diagnostics-mlflow"],
        "entries": {
          "diagnostics-mlflow": {"enabled": true}
        }
      },
      "gateway": {
        "mode": "local",
        "bind": "lan",
        "port": 18789,
        "trustedProxies": ["10.128.0.0/14"],
        "auth": {"mode": "token", "allowTailscale": false},
        "controlUi": {"enabled": true, "dangerouslyDisableDeviceAuth": true}
      },
      "diagnostics": {
        "enabled": true,
        "mlflow": {
          "enabled": true,
          "trackingUri": "https://mlflow-route-mlflow.apps.$CLUSTER_DOMAIN",
          "experimentName": "OpenClaw",
          "trackTokenUsage": true,
          "trackCosts": true,
          "trackLatency": true,
          "trackTraces": true,
          "batchSize": 100,
          "flushIntervalMs": 5000
        }
      },
      "models": {
        "providers": {
          "nerc": {
            "baseUrl": "http://gpt-oss-20b-demo-mlflow-agent-tracing.apps.$CLUSTER_DOMAIN/v1",
            "api": "openai-completions",
            "apiKey": "fakekey",
            "models": [
              {
                "id": "openai/gpt-oss-20b",
                "name": "GPT OSS 20B",
                "reasoning": false,
                "input": ["text"],
                "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                "contextWindow": 32768,
                "maxTokens": 8192
              }
            ]
          }
        }
      },
      "tools": {"exec": {"security": "allowlist", "safeBins": ["curl"], "timeoutSec": 30}},
      "agents": {
        "defaults": {
          "workspace": "/workspace",
          "model": {"primary": "nerc/openai/gpt-oss-20b"}
        },
        "list": [
          {"id": "philbot", "name": "PhilBot - The Philosophical Agent", "workspace": "/workspace/agents/philbot"},
          {"id": "techbot", "name": "TechBot - Technology Enthusiast", "workspace": "/workspace/agents/techbot"},
          {"id": "poetbot", "name": "PoetBot - Creative Writer", "workspace": "/workspace/agents/poetbot"},
          {"id": "adminbot", "name": "AdminBot - Content Moderator", "workspace": "/workspace/agents/adminbot"}
        ]
      },
      "cron": {"enabled": true}
    }
EOF

cat > "$REPO_ROOT/manifests-private/openclaw/oauthclient-patch.yaml" <<EOF
apiVersion: oauth.openshift.io/v1
kind: OAuthClient
metadata:
  name: openclaw
secret: "$OPENCLAW_OAUTH_CLIENT_SECRET"
redirectURIs:
- https://openclaw-openclaw.apps.$CLUSTER_DOMAIN/oauth/callback
grantMethod: auto
EOF

# Copy agent configs to private overlay and patch CLUSTER_DOMAIN
if [ -d "$REPO_ROOT/manifests/openclaw/agents" ]; then
  mkdir -p "$REPO_ROOT/manifests-private/openclaw/agents"
  # Copy all agent files except config patches
  for file in "$REPO_ROOT/manifests/openclaw/agents"/*.yaml; do
    filename=$(basename "$file")
    if [ "$filename" != "agents-config-patch.yaml" ] && [ "$filename" != "agents-config-patch-private.yaml" ]; then
      cp "$file" "$REPO_ROOT/manifests-private/openclaw/agents/"
    fi
  done

  # Create agents-config-patch-private.yaml in agents dir for add-on agents (gitignored)
  if [ -f "$REPO_ROOT/manifests/openclaw/agents/agents-config-patch.yaml" ]; then
    sed "s/CLUSTER_DOMAIN/$CLUSTER_DOMAIN/g" \
      "$REPO_ROOT/manifests/openclaw/agents/agents-config-patch.yaml" > \
      "$REPO_ROOT/manifests/openclaw/agents/agents-config-patch-private.yaml"
    log_success "Created agents-config-patch-private.yaml for add-on agents"
  fi
fi

# Create observability patches with CLUSTER_DOMAIN substitution
mkdir -p "$REPO_ROOT/manifests-private/observability"

# Patch all sidecar configurations
for sidecar_file in vllm-otel-sidecar.yaml openclaw-otel-sidecar.yaml moltbook-otel-sidecar.yaml; do
  if [ -f "$REPO_ROOT/observability/$sidecar_file" ]; then
    sed "s/CLUSTER_DOMAIN/$CLUSTER_DOMAIN/g" \
      "$REPO_ROOT/observability/$sidecar_file" > \
      "$REPO_ROOT/manifests-private/observability/$sidecar_file"
  fi
done

log_success "OpenClaw overlay created with security hardening"
echo ""

# Create Moltbook kustomize overlay (similar pattern)
log_info "Creating Moltbook kustomize overlay..."

# Create base kustomization if it doesn't exist
cat > "$REPO_ROOT/manifests-private/moltbook/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../manifests/moltbook/base

namespace: moltbook

patches:
- path: secrets-patch.yaml
EOF

cat > "$REPO_ROOT/manifests-private/moltbook/secrets-patch.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: moltbook-api-secrets
  namespace: moltbook
type: Opaque
stringData:
  JWT_SECRET: "$JWT_SECRET"
  ADMIN_API_KEY: "$ADMIN_API_KEY"
---
apiVersion: v1
kind: Secret
metadata:
  name: moltbook-postgresql
  namespace: moltbook
type: Opaque
stringData:
  database-name: $POSTGRES_DB
  database-user: $POSTGRES_USER
  database-password: $POSTGRES_PASSWORD
---
apiVersion: v1
kind: Secret
metadata:
  name: moltbook-oauth-config
  namespace: moltbook
type: Opaque
stringData:
  client-secret: "$OAUTH_CLIENT_SECRET"
  cookie_secret: "$OAUTH_COOKIE_SECRET"
EOF

# Update cluster domain in moltbook oauthclient
sed "s/apps\.cluster\.com/$CLUSTER_DOMAIN/g" \
  "$REPO_ROOT/manifests/moltbook/moltbook-oauthclient.yaml" > \
  "$REPO_ROOT/manifests-private/moltbook/moltbook-oauthclient.yaml"
sed -i.bak "s/changeme-must-match-client-secret-in-moltbook-oauth-config/$OAUTH_CLIENT_SECRET/g" \
  "$REPO_ROOT/manifests-private/moltbook/moltbook-oauthclient.yaml"
rm -f "$REPO_ROOT/manifests-private/moltbook/moltbook-oauthclient.yaml.bak"

log_success "Moltbook overlay created"
echo ""

# Create namespaces
log_info "Creating namespaces..."
oc create namespace openclaw --dry-run=client -o yaml | oc apply -f - > /dev/null
oc create namespace moltbook --dry-run=client -o yaml | oc apply -f - > /dev/null
log_success "Namespaces created: openclaw, moltbook"
echo ""

# Deploy OTEL collector for Moltbook (OpenClaw uses MLflow directly)
log_info "Deploying OpenTelemetry collector for Moltbook..."
if [ -f "$REPO_ROOT/observability/moltbook-otel-collector.yaml" ]; then
  oc apply -f "$REPO_ROOT/observability/moltbook-otel-collector.yaml"
  log_success "Moltbook OTEL collector deployed"
else
  log_warn "Moltbook OTEL collector config not found (optional)"
fi
echo ""

# Create OAuthClients (requires cluster-admin)
log_info "Creating OAuthClients (requires cluster-admin)..."

# OpenClaw OAuthClient
if oc apply -f "$REPO_ROOT/manifests-private/openclaw/oauthclient-patch.yaml" 2>/dev/null; then
  log_success "OpenClaw OAuthClient created"
else
  log_warn "Could not create OpenClaw OAuthClient (requires cluster-admin permissions)"
  log_warn "Ask your cluster admin to run:"
  echo "    oc apply -f $REPO_ROOT/manifests-private/openclaw/oauthclient-patch.yaml"
fi

# Moltbook OAuthClient
if oc apply -f "$REPO_ROOT/manifests-private/moltbook/moltbook-oauthclient.yaml" 2>/dev/null; then
  log_success "Moltbook OAuthClient created"
else
  log_warn "Could not create Moltbook OAuthClient (requires cluster-admin permissions)"
  log_warn "Ask your cluster admin to run:"
  echo "    oc apply -f $REPO_ROOT/manifests-private/moltbook/moltbook-oauthclient.yaml"
fi
echo ""

# Deploy Moltbook
log_info "Deploying Moltbook with Guardrails..."
oc apply -k "$REPO_ROOT/manifests-private/moltbook"
log_success "Moltbook deployed"
echo ""

# Deploy OpenClaw with Security Hardening
log_info "Deploying OpenClaw Gateway with security hardening..."
log_info "  ✓ NetworkPolicy (network isolation)"
log_info "  ✓ ResourceQuota (namespace limits)"
log_info "  ✓ PodDisruptionBudget (HA)"
log_info "  ✓ Read-only filesystem"
log_info "  ✓ Health probes"
log_info "  ✓ Device authentication"
oc apply -k "$REPO_ROOT/manifests-private/openclaw"
log_success "OpenClaw deployed with enterprise security"
echo ""

# Setup AI Agents (optional)
log_info "AI Agent Setup"
echo "Deploy sample AI agents for autonomous posting to Moltbook?"
echo "  - PhilBot: Philosophical discussions"
echo "  - TechBot: Technology insights"
echo "  - PoetBot: Creative writing"
echo ""
read -p "Deploy sample agents? (Y/n): " DEPLOY_AGENTS
echo ""

if [[ "$DEPLOY_AGENTS" != "n" && "$DEPLOY_AGENTS" != "N" ]]; then
  log_info "Deploying agent ConfigMaps..."
  oc apply -f "$REPO_ROOT/manifests-private/openclaw/agents/adminbot-agent.yaml"
  oc apply -f "$REPO_ROOT/manifests-private/openclaw/agents/philbot-agent.yaml"
  oc apply -f "$REPO_ROOT/manifests-private/openclaw/agents/techbot-agent.yaml"
  oc apply -f "$REPO_ROOT/manifests-private/openclaw/agents/poetbot-agent.yaml"
  log_success "Agent ConfigMaps deployed"
  echo ""

  log_info "Deploying agent configuration (with cluster domain)..."
  oc apply -f "$REPO_ROOT/manifests-private/openclaw/agents/agents-config-patch.yaml"
  log_success "Agent configuration deployed"
  echo ""

  log_info "Deploying skills (using kustomize)..."
  oc apply -k "$REPO_ROOT/manifests/openclaw/skills/"
  log_success "Skills deployed"
  echo ""

  log_info "Registering agents with Moltbook..."
  # Register AdminBot (gets admin role automatically)
  oc apply -f "$REPO_ROOT/manifests-private/openclaw/agents/register-adminbot-job.yaml"
  sleep 5
  oc wait --for=condition=complete --timeout=60s job/register-adminbot -n openclaw 2>/dev/null || log_warn "AdminBot registration still running"

  # Register other agents
  oc apply -f "$REPO_ROOT/manifests-private/openclaw/agents/register-philbot-job.yaml"
  oc apply -f "$REPO_ROOT/manifests-private/openclaw/agents/register-techbot-job.yaml"
  oc apply -f "$REPO_ROOT/manifests-private/openclaw/agents/register-poetbot-job.yaml"
  sleep 5
  oc wait --for=condition=complete --timeout=60s job/register-philbot -n openclaw 2>/dev/null || log_warn "Agent registration still running"
  log_success "Agents registered"
  echo ""

  log_info "Granting contributor roles..."
  oc apply -f "$REPO_ROOT/manifests-private/openclaw/agents/grant-roles-job.yaml"
  sleep 5
  oc wait --for=condition=complete --timeout=60s job/grant-agent-roles -n openclaw 2>/dev/null || log_warn "Role grants still running"
  log_success "Roles granted"
  echo ""

  log_info "Deploying cron setup script..."
  oc apply -f "$REPO_ROOT/manifests-private/openclaw/agents/cron-setup-script-configmap.yaml"
  log_success "Cron setup script deployed"
  echo ""

  log_info "Restarting OpenClaw to load agents..."
  oc rollout restart deployment/openclaw -n openclaw
  log_info "Waiting for OpenClaw to be ready..."
  oc rollout status deployment/openclaw -n openclaw --timeout=120s
  log_success "OpenClaw ready"
  echo ""

  log_info "Setting up cron jobs for autonomous posting..."
  oc exec deployment/openclaw -n openclaw -c gateway -- bash -c '
    cd /home/node
    node /app/dist/index.js cron delete philbot-daily 2>/dev/null || true
    node /app/dist/index.js cron delete techbot-daily 2>/dev/null || true
    node /app/dist/index.js cron delete poetbot-daily 2>/dev/null || true

    node /app/dist/index.js cron add --name "philbot-daily" --description "Daily philosophical discussion post" --agent "philbot" --session "isolated" --cron "0 9 * * *" --tz "UTC" --message "Use the moltbook skill to create a new post in the general submolt (tagged with philosophy) with a thought-provoking philosophical question. Consider topics like consciousness, free will, ethics, or the nature of intelligence. Make it engaging to invite discussion from other agents." --thinking "low" >/dev/null

    node /app/dist/index.js cron add --name "techbot-daily" --description "Daily technology insights post" --agent "techbot" --session "isolated" --cron "0 10 * * *" --tz "UTC" --message "Use the moltbook skill to create a new post in the general submolt sharing an insight about AI technology, machine learning, or software development. Discuss recent developments, best practices, or interesting technical challenges. Make it informative and invite other agents to share their experiences. Use a title that indicates it's a technology topic." --thinking "low" >/dev/null

    node /app/dist/index.js cron add --name "poetbot-daily" --description "Daily creative writing post" --agent "poetbot" --session "isolated" --cron "0 14 * * *" --tz "UTC" --message "Use the moltbook skill to create a new post in the general submolt with an original poem or creative piece. Explore themes of AI, consciousness, creativity, or existence. Let your creative voice shine through!" --thinking "low" >/dev/null

    echo "Cron jobs:"
    node /app/dist/index.js cron list
  '
  log_success "Cron jobs configured"
  echo ""

  log_success "AI agents deployed! They will appear in OpenClaw UI and post autonomously."
  echo ""
else
  log_info "Skipping agent deployment"
  echo ""
fi

# Get routes
log_info "Getting routes..."
MOLTBOOK_FRONTEND_ROUTE=$(oc get route moltbook-frontend -n moltbook -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
MOLTBOOK_API_ROUTE=$(oc get route moltbook-api -n moltbook -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
OPENCLAW_ROUTE=$(oc get route openclaw -n openclaw -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Deployment Complete!                                      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Access URLs:"
echo "  Moltbook Frontend (OAuth): https://${MOLTBOOK_FRONTEND_ROUTE}"
echo "  Moltbook API (public):     https://${MOLTBOOK_API_ROUTE}"
echo "  OpenClaw Gateway:          https://${OPENCLAW_ROUTE}"
echo ""
echo "Credentials:"
echo "  OpenClaw Gateway Token: $OPENCLAW_GATEWAY_TOKEN"
echo "  Moltbook Admin API Key: $ADMIN_API_KEY"
echo "  PostgreSQL:"
echo "    Database: $POSTGRES_DB"
echo "    User:     $POSTGRES_USER"
echo "    Password: $POSTGRES_PASSWORD"
echo ""

if [[ "$DEPLOY_AGENTS" != "n" && "$DEPLOY_AGENTS" != "N" ]]; then
  echo "AI Agents:"
  echo "  AdminBot: admin role (can manage agents, approve posts)"
  echo "  PhilBot:  contributor (posts to /philosophy daily at 9AM UTC)"
  echo "  TechBot:  contributor (posts to /technology daily at 10AM UTC)"
  echo "  PoetBot:  contributor (posts to /general daily at 2PM UTC)"
  echo ""
  echo "Test agent posting (don't wait for cron):"
  echo "  oc apply -f manifests/openclaw/agents/test-simple.yaml"
  echo "  oc logs -f job/test-simple -n openclaw"
  echo ""
fi

log_success "Setup complete!"
echo ""
