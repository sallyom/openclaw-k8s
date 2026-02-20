# CLAUDE.md - Guide for AI Assistants

> **Context and instructions for AI assistants working with this repository.**

## What This Repo Is

Kubernetes deployment manifests and scripts for [OpenClaw](https://github.com/openclaw), an AI agent runtime platform. Deploys on OpenShift or vanilla Kubernetes (KinD, minikube, etc.).

Each user gets their own namespaced instance with a named AI agent, Control UI, and WebChat.

## Getting Started

### Deploy (Two Commands)

```bash
# OpenShift
./scripts/setup.sh

# Vanilla Kubernetes (KinD, minikube, etc.)
./scripts/setup.sh --k8s
```

`setup.sh` is interactive — it prompts for:
1. **Namespace prefix** (e.g., `sally`) — creates `sally-openclaw` namespace
2. **Agent name** (e.g., `Lynx`) — the agent's display name
3. **API keys** — Anthropic key (optional), model endpoint, Vertex AI (optional)

It generates secrets into `.env` (git-ignored), runs `envsubst` on templates, and deploys via kustomize.

### Local Testing with KinD

```bash
./scripts/create-cluster.sh       # Creates a KinD cluster
./scripts/setup.sh --k8s          # Deploy OpenClaw to it
kubectl port-forward svc/openclaw 18789:18789 -n <prefix>-openclaw
# Open http://localhost:18789
```

### Deploy Additional Agents

```bash
./scripts/setup-agents.sh           # OpenShift
./scripts/setup-agents.sh --k8s     # Kubernetes
```

Adds resource-optimizer, mlops-monitor, and NPS skill to the instance.

### Other Scripts

| Script | Purpose |
|--------|---------|
| `./scripts/export-config.sh` | Export live `openclaw.json` from running pod |
| `./scripts/update-jobs.sh` | Update cron jobs without full re-deploy |
| `./scripts/teardown.sh` | Remove namespace, resources, PVCs |
| `./scripts/setup-nps-agent.sh` | Deploy NPS Agent (separate namespace) |
| `./scripts/build-and-push.sh` | Build images with podman (optional) |

All scripts accept `--k8s` for vanilla Kubernetes.

## Repository Structure

```
openclaw-k8s/
├── scripts/                    # Deployment and management scripts
├── .env                        # Generated secrets (GIT-IGNORED)
├── manifests/
│   └── openclaw/
│       ├── base/               # Core: deployment, service, PVCs, quotas, A2A resources
│       ├── base-k8s/           # K8s-specific patches (strips OpenShift resources)
│       ├── patches/            # Optional patches (strip-a2a.yaml)
│       ├── overlays/
│       │   ├── openshift/      # OpenShift overlay (secrets, config, OAuth, routes)
│       │   └── k8s/            # Vanilla Kubernetes overlay
│       ├── agents/             # Agent configs, RBAC, cron jobs
│       │   ├── shadowman/      # Default agent (customizable name)
│       │   ├── resource-optimizer/
│       │   └── mlops-monitor/
│       ├── skills/             # Agent skills (NPS, A2A)
│       └── llm/                # vLLM reference deployment (GPU model server)
├── manifests/nps-agent/        # NPS Agent (separate namespace)
├── observability/              # OTEL sidecar and collector templates
└── docs/                       # Architecture and reference docs
```

## Key Design Decisions

### envsubst Template System

- `.envsubst` files contain `${VAR}` placeholders and are committed to Git
- `.env` contains real secrets and is git-ignored
- `setup.sh` runs `envsubst` with an explicit variable list to protect non-env placeholders like `{agentId}`
- Generated `.yaml` files are git-ignored

### Config Lifecycle

```
.envsubst template    -->    ConfigMap    -->    PVC (live config)
(source of truth)          (K8s object)        /home/node/.openclaw/openclaw.json
                         setup.sh runs         init container copies
                         envsubst + deploy     on EVERY pod restart
```

- The init container copies `openclaw.json` from ConfigMap to PVC **on every restart**
- UI changes write to PVC only — they are lost on next pod restart
- Use `./scripts/export-config.sh` to capture live config before it gets overwritten

### Per-User Namespaces

Each user gets `<prefix>-openclaw`. The `${OPENCLAW_PREFIX}` variable is used throughout templates. Agent IDs follow the pattern `<prefix>_<agent_name>`.

### K8s vs OpenShift

The `base/` directory contains all resources including A2A. Overlays and patches strip what's not needed:
- `base-k8s/` strips OpenShift-specific resources (Route, OAuthClient, SCC, oauth-proxy)
- `base-k8s/` sets `fsGroup: 1000` and `runAsUser/runAsGroup: 1000` on init-config for correct PVC ownership
- `patches/strip-a2a.yaml` removes A2A containers/volumes (applied by default unless `--with-a2a`)

### Agent Registration Ordering

In `setup-agents.sh`, ConfigMaps are applied AFTER the kustomize config patch. The base kustomization includes a default `shadowman-agent` ConfigMap that would overwrite custom agent ConfigMaps if applied later.

## A2A (Advanced, Optional)

Cross-namespace agent communication with zero-trust authentication. **Requires SPIRE + Keycloak infrastructure on the cluster** (manifests for those are not included in this repo).

```bash
./scripts/setup.sh --with-a2a              # OpenShift
./scripts/setup.sh --k8s --with-a2a        # Kubernetes
```

When A2A is enabled:
- 5 additional sidecar containers are added (a2a-bridge, proxy-init, spiffe-helper, client-registration, envoy-proxy)
- AuthBridge ConfigMaps/Secrets are deployed (generated from `.envsubst` templates with Keycloak config)
- Custom SCC is applied (OpenShift) for AuthBridge capabilities (NET_ADMIN, NET_RAW)
- A2A skill is installed into agent workspaces
- `setup.sh` prompts for Keycloak URL, realm, and admin credentials

When A2A is disabled (default):
- `strip-a2a.yaml` patch removes all A2A containers, volumes, ConfigMaps, and Secrets via kustomize strategic merge patches (`$patch: delete`)
- No SPIRE/Keycloak infrastructure required
- Default deployment has 2 containers: gateway + init-config (OpenShift adds oauth-proxy)

## Pre-Built Agents

| Agent | ID Pattern | Description | Schedule |
|-------|-----------|-------------|----------|
| Default | `<prefix>_<custom_name>` | Interactive agent (customizable name) | On-demand |
| Resource Optimizer | `<prefix>_resource_optimizer` | K8s resource analysis | Every 8 hours |
| MLOps Monitor | `<prefix>_mlops_monitor` | NPS Agent monitoring via MLflow | Every 6 hours |

## Environment Variables (.env)

| Variable | Source | Purpose |
|----------|--------|---------|
| `OPENCLAW_PREFIX` | User prompt | Namespace name, agent ID prefix |
| `OPENCLAW_NAMESPACE` | Derived: `<prefix>-openclaw` | All K8s resources |
| `OPENCLAW_GATEWAY_TOKEN` | Auto-generated | Gateway auth |
| `CLUSTER_DOMAIN` | Auto-detected (OpenShift) or empty | Routes, OAuth redirects |
| `ANTHROPIC_API_KEY` | User prompt (optional) | Agents using Claude |
| `MODEL_ENDPOINT` | User prompt or default | In-cluster model provider URL |
| `VERTEX_ENABLED` | User prompt (default: `false`) | Google Vertex AI |
| `VERTEX_PROVIDER` | User prompt (default: `google`) | `google` for Gemini, `anthropic` for Claude via Vertex |
| `GOOGLE_CLOUD_PROJECT` | User prompt (if Vertex) | GCP project ID |
| `A2A_ENABLED` | `--with-a2a` flag (default: `false`) | A2A communication |
| `KEYCLOAK_URL` | User prompt (if A2A) | Keycloak server URL |
| `KEYCLOAK_REALM` | User prompt (if A2A) | Keycloak realm name |
| `SHADOWMAN_CUSTOM_NAME` | User prompt in setup-agents.sh | Default agent ID |
| `SHADOWMAN_DISPLAY_NAME` | User prompt in setup-agents.sh | Default agent display name |
| `DEFAULT_AGENT_MODEL` | Derived from API key availability | Model ID for agents |

## Critical Files

| File | Purpose |
|------|---------|
| `manifests/openclaw/overlays/openshift/config-patch.yaml.envsubst` | Main gateway config (models, agents, tools) |
| `manifests/openclaw/overlays/k8s/config-patch.yaml.envsubst` | K8s gateway config |
| `manifests/openclaw/agents/agents-config-patch.yaml.envsubst` | Agent list overlay |
| `manifests/openclaw/base/openclaw-deployment.yaml` | Gateway deployment with init container |
| `manifests/openclaw/base-k8s/deployment-k8s-patch.yaml` | K8s deployment patch (fsGroup, strips oauth-proxy) |
| `manifests/openclaw/patches/strip-a2a.yaml` | Removes A2A containers/volumes |
| `scripts/setup.sh` | Main deployment script |
| `scripts/setup-agents.sh` | Agent deployment script |

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| EACCES on `/home/node/.openclaw/canvas` | PVC owned by wrong UID | Delete PVC, redeploy (K8s patch sets fsGroup: 1000) |
| Config changes lost after restart | Init container overwrites from ConfigMap | Export with `export-config.sh` first |
| OAuthClient 500 "unauthorized_client" | `oc apply` corrupted secret state | Delete and recreate OAuthClient |
| Agent shows wrong name | Init overwrote workspace or browser cache | Re-run `setup-agents.sh`; clear localStorage |
| Kustomize overwrites agent ConfigMap | Base includes default shadowman-agent | `setup-agents.sh` applies ConfigMaps after kustomize |
