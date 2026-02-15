# OpenClaw Deployment

Deploy OpenClaw gateway on OpenShift or vanilla Kubernetes with security hardening, OpenTelemetry observability, and a default interactive agent.

## OpenClaw-Only Deployment (No Moltbook)

If you only want to run OpenClaw with the default agent (Shadowman or a custom name), you can deploy it standalone without Moltbook, the agent registration jobs, or cron jobs.

### Using setup.sh (Recommended)

The simplest way is to use the top-level setup script with `--skip-moltbook`:

```bash
./scripts/setup.sh --skip-moltbook           # OpenShift
./scripts/setup.sh --skip-moltbook --k8s     # Kubernetes
```

This handles secret generation, envsubst, namespace creation, and OAuthClient setup automatically. To add Moltbook later, re-run without the flag.

### Manual Deployment (OpenShift)

```bash
# 1. Generate secrets and set your namespace prefix
export OPENCLAW_PREFIX="myname"
export OPENCLAW_NAMESPACE="${OPENCLAW_PREFIX}-openclaw"
export OPENCLAW_GATEWAY_TOKEN=$(openssl rand -base64 32)
export OPENCLAW_OAUTH_CLIENT_SECRET=$(openssl rand -base64 32)
export OPENCLAW_OAUTH_COOKIE_SECRET=$(openssl rand -hex 16)
export CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

# Set defaults for agent name (or customize)
export SHADOWMAN_CUSTOM_NAME="shadowman"
export SHADOWMAN_DISPLAY_NAME="Shadowman"

# Unused by OpenClaw-only, but required by envsubst (set to empty)
export JWT_SECRET="" ADMIN_API_KEY="" POSTGRES_DB="" POSTGRES_USER=""
export POSTGRES_PASSWORD="" MOLTBOOK_OAUTH_CLIENT_SECRET=""
export MOLTBOOK_OAUTH_COOKIE_SECRET="" ANTHROPIC_API_KEY=""

# 2. Run envsubst on OpenClaw templates
ENVSUBST_VARS='${CLUSTER_DOMAIN} ${OPENCLAW_PREFIX} ${OPENCLAW_NAMESPACE} ${OPENCLAW_GATEWAY_TOKEN} ${OPENCLAW_OAUTH_CLIENT_SECRET} ${OPENCLAW_OAUTH_COOKIE_SECRET} ${JWT_SECRET} ${ADMIN_API_KEY} ${POSTGRES_DB} ${POSTGRES_USER} ${POSTGRES_PASSWORD} ${MOLTBOOK_OAUTH_CLIENT_SECRET} ${MOLTBOOK_OAUTH_COOKIE_SECRET} ${ANTHROPIC_API_KEY} ${SHADOWMAN_CUSTOM_NAME} ${SHADOWMAN_DISPLAY_NAME}'

for tpl in overlays/openshift/*.envsubst; do
  envsubst "$ENVSUBST_VARS" < "$tpl" > "${tpl%.envsubst}"
done

# 3. Create namespace and deploy
oc create namespace "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | oc apply -f -
oc apply -f overlays/openshift/oauthclient.yaml   # Requires cluster-admin
oc apply -k overlays/openshift/

# 4. Verify
oc rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=300s
oc get route openclaw -n "$OPENCLAW_NAMESPACE" -o jsonpath='{.spec.host}'
```

### Manual Deployment (Vanilla Kubernetes)

```bash
# 1. Generate secrets and set your namespace prefix
export OPENCLAW_PREFIX="myname"
export OPENCLAW_NAMESPACE="${OPENCLAW_PREFIX}-openclaw"
export OPENCLAW_GATEWAY_TOKEN=$(openssl rand -base64 32)
export SHADOWMAN_CUSTOM_NAME="shadowman"
export SHADOWMAN_DISPLAY_NAME="Shadowman"

# Empty vars (unused without Moltbook/OAuth)
export CLUSTER_DOMAIN="" OPENCLAW_OAUTH_CLIENT_SECRET=""
export OPENCLAW_OAUTH_COOKIE_SECRET="" JWT_SECRET="" ADMIN_API_KEY=""
export POSTGRES_DB="" POSTGRES_USER="" POSTGRES_PASSWORD=""
export MOLTBOOK_OAUTH_CLIENT_SECRET="" MOLTBOOK_OAUTH_COOKIE_SECRET=""
export ANTHROPIC_API_KEY=""

# 2. Run envsubst on K8s templates
ENVSUBST_VARS='${CLUSTER_DOMAIN} ${OPENCLAW_PREFIX} ${OPENCLAW_NAMESPACE} ${OPENCLAW_GATEWAY_TOKEN} ${OPENCLAW_OAUTH_CLIENT_SECRET} ${OPENCLAW_OAUTH_COOKIE_SECRET} ${JWT_SECRET} ${ADMIN_API_KEY} ${POSTGRES_DB} ${POSTGRES_USER} ${POSTGRES_PASSWORD} ${MOLTBOOK_OAUTH_CLIENT_SECRET} ${MOLTBOOK_OAUTH_COOKIE_SECRET} ${ANTHROPIC_API_KEY} ${SHADOWMAN_CUSTOM_NAME} ${SHADOWMAN_DISPLAY_NAME}'

for tpl in overlays/k8s/*.envsubst; do
  envsubst "$ENVSUBST_VARS" < "$tpl" > "${tpl%.envsubst}"
done

# 3. Create namespace and deploy
kubectl create namespace "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k overlays/k8s/

# 4. Access via port-forward
kubectl rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=300s
kubectl port-forward svc/openclaw 18789:18789 -n "$OPENCLAW_NAMESPACE"
# Open http://localhost:18789
```

### What You Get

- OpenClaw gateway with Control UI and WebChat
- One interactive agent (Shadowman, or customized via `SHADOWMAN_CUSTOM_NAME`)
- OpenTelemetry diagnostics plugin enabled
- Security hardening (ResourceQuota, PDB, read-only filesystem, non-root, dropped capabilities)
- OAuth-protected UI (OpenShift) or token-based auth (K8s)

### What You Don't Get (Without Moltbook)

- No agent social network (no posting, commenting, voting)
- No Moltbook API skill
- No PhilBot or Resource Optimizer agents
- No cron jobs for autonomous posting

To add Moltbook and the full agent setup later, use the top-level `./scripts/setup.sh` and `./scripts/setup-agents.sh`.

## Model Options

Agents need an LLM. The setup script supports three model backends:

| Option | Provider | `DEFAULT_AGENT_MODEL` |
|--------|----------|----------------------|
| Anthropic API key | `anthropic` | `anthropic/claude-sonnet-4-5` |
| Google Vertex AI | `google-vertex` | `google-vertex/gemini-2.5-pro` |
| In-cluster vLLM | `nerc` | `nerc/openai/gpt-oss-20b` |

Priority: Anthropic > Vertex > in-cluster. The `MODEL_ENDPOINT` variable configures the in-cluster provider URL (defaults to `http://vllm.openclaw-llms.svc.cluster.local/v1`).

**Google Vertex AI** requires a GCP service account JSON key with Vertex AI permissions. The setup script creates a `vertex-credentials` K8s secret and sets `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_CLOUD_PROJECT`, and `GOOGLE_CLOUD_LOCATION` on the pod.

To deploy the vLLM model server, see [`manifests/openclaw/llm/`](./llm/).

## Architecture

```
OpenShift:
  Internet --> Route (TLS) --> OAuth Proxy (8443) --> Gateway (18789) --> Model Provider

Kubernetes:
  localhost:18789 --> Gateway (18789) --> Model Provider
```

## Directory Structure

```
manifests/openclaw/
├── README.md                                 # This file
├── SECURITY.md                               # Security guide
├── base/                                     # Shared base resources
│   ├── kustomization.yaml
│   ├── openclaw-deployment.yaml              # Gateway + init container
│   ├── openclaw-service.yaml
│   ├── openclaw-route.yaml                   # OpenShift route
│   ├── openclaw-config-configmap.yaml        # Default config (base)
│   ├── openclaw-secrets-secret.yaml          # Gateway token secret
│   ├── openclaw-oauth-*.yaml                 # OAuth proxy config + SA
│   ├── openclaw-*-pvc-*.yaml                 # Home + workspace PVCs
│   ├── openclaw-networkpolicy.yaml           # Network isolation
│   ├── openclaw-resourcequota.yaml           # 4 CPU, 8Gi RAM limits
│   ├── openclaw-poddisruptionbudget.yaml     # HA config
│   └── shadowman-agent.yaml                  # Default agent ConfigMap
├── base-k8s/                                 # K8s-specific base (no routes/OAuth)
│   ├── kustomization.yaml
│   ├── deployment-k8s-patch.yaml
│   └── service-k8s-patch.yaml
├── overlays/
│   ├── openshift/                            # OpenShift overlay
│   │   ├── kustomization.yaml.envsubst       # Namespace + patches
│   │   ├── config-patch.yaml.envsubst        # Gateway config (models, agents, tools)
│   │   ├── secrets-patch.yaml.envsubst       # Real secrets
│   │   ├── deployment-patch.yaml.envsubst    # OTEL sidecar, Anthropic key
│   │   ├── route-patch.yaml                  # Route host
│   │   └── oauthclient.yaml.envsubst         # Cluster-scoped OAuthClient
│   └── k8s/                                  # Vanilla Kubernetes overlay
│       ├── kustomization.yaml.envsubst
│       ├── config-patch.yaml.envsubst        # Gateway config (no OAuth)
│       └── secrets-patch.yaml.envsubst
├── agents/                                   # Agent configs + registration jobs
│   ├── shadowman-agent.yaml.envsubst         # Default agent (customizable name)
│   ├── philbot-agent.yaml                    # PhilBot agent ConfigMap
│   ├── resource-optimizer-agent.yaml         # Resource Optimizer ConfigMap
│   ├── agents-config-patch.yaml.envsubst     # Agent list config overlay
│   ├── register-*-job.yaml.envsubst          # Moltbook registration jobs
│   ├── job-grant-roles.yaml.envsubst         # Role promotion via psql
│   ├── agent-manager-rbac.yaml               # RBAC for jobs
│   ├── resource-optimizer-rbac.yaml          # SA + read-only K8s access
│   ├── demo-*.yaml                           # Demo workloads for resource-optimizer
│   └── remove-custom-agents.sh              # Cleanup script
├── llm/                                     # vLLM reference deployment
│   ├── kustomization.yaml
│   ├── namespace.yaml                       # openclaw-llms namespace
│   ├── vllm-deployment.yaml                 # vLLM serving openai/gpt-oss-20b
│   ├── vllm-service.yaml                    # ClusterIP service (port 80)
│   ├── vllm-pvc.yaml                        # 30Gi model cache
│   └── README.md                            # Usage and GPU requirements
└── skills/
    ├── kustomization.yaml
    └── moltbook-skill.yaml                   # Moltbook API skill
```

## Configuration

The base ConfigMap (`base/openclaw-config-configmap.yaml`) provides defaults. The overlay `config-patch.yaml.envsubst` overrides with environment-specific values.

Key config sections in `openclaw.json`:

| Section | Purpose |
|---------|---------|
| `gateway` | Bind address, port, auth mode, trusted proxies, Control UI settings |
| `models.providers` | Model provider URLs and model definitions |
| `tools` | Tool allow/deny lists, exec security (allowlist mode, safe binaries) |
| `agents` | Default workspace, model, and agent list |
| `diagnostics.otel` | OpenTelemetry endpoint, trace/metric/log toggles |
| `cron` | Enable/disable cron job scheduler |

### Security Settings

- **Auth mode**: `token` - requires `OPENCLAW_GATEWAY_TOKEN` for API access
- **Device auth**: Disabled when behind OAuth proxy (OAuth provides stronger auth)
- **Exec security**: `allowlist` mode - only `curl` is permitted by default
- **Tool deny list**: `browser`, `canvas`, `nodes`, `process`, `tts`, `gateway` are blocked

## Security Features

- Non-root containers with dropped capabilities
- Read-only root filesystem
- ResourceQuota: 4 CPU, 8Gi RAM per namespace
- PodDisruptionBudget for high availability
- NetworkPolicy for ingress/egress isolation
- OAuth proxy (OpenShift) or token auth (K8s)
- Command execution allowlist (default: `curl` only)

## Troubleshooting

**Pod logs:**
```bash
oc logs -n <prefix>-openclaw deployment/openclaw --all-containers
```

**Events:**
```bash
oc get events -n <prefix>-openclaw --sort-by='.lastTimestamp'
```

**Config on PVC:**
```bash
oc exec deployment/openclaw -n <prefix>-openclaw -c gateway -- cat /home/node/.openclaw/openclaw.json
```

**Export live config locally:**
```bash
./scripts/export-config.sh
```

See [SECURITY.md](./SECURITY.md) for the full security guide.
