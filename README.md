# openclaw-k8s

Deploy [OpenClaw](https://github.com/openclaw) — an AI agent runtime platform — on OpenShift or vanilla Kubernetes. Each team member gets their own instance with a named agent, Control UI, and WebChat.

## What This Deploys

```
 ┌──────────────────────────────┐
 │  sally-openclaw              │
 │                              │
 │  Agent: Lynx (sally_lynx)    │
 │                              │
 │  Gateway + Control UI        │
 │  WebChat on port 18789       │
 └──────────────────────────────┘
```

Each instance runs:
- An AI agent with a customizable name (chosen during setup)
- Control UI + WebChat on port 18789
- Hardened gateway container (read-only FS, capabilities dropped, no privilege escalation)

Optionally, enable **A2A (Agent-to-Agent)** communication for cross-namespace agent messaging with zero-trust authentication. See [A2A Communication](#a2a-agent-to-agent-communication) below.

## Quick Start

> **Tip:** This repo is designed to be AI-navigable. Point an AI coding assistant (Claude Code, Codex, etc.) at this directory and ask it to help you deploy, troubleshoot, or customize your setup.

### Prerequisites

**OpenShift (default):**
- `oc` CLI installed and logged in (`oc login`)
- Cluster-admin access (for OAuthClient creation)

**Vanilla Kubernetes (KinD, minikube, etc.):**
- `kubectl` CLI installed with a valid kubeconfig
- Optional: `./scripts/create-cluster.sh` creates a KinD cluster for local testing

### Deploy

```bash
# OpenShift (default)
./scripts/setup.sh

# Or vanilla Kubernetes
./scripts/setup.sh --k8s
```

The script will prompt for:
- **Namespace prefix** (e.g., `sally`) — creates `sally-openclaw` namespace
- **Agent name** (e.g., `Lynx`) — your agent's display name
- **Anthropic API key** (optional — without it, agents use the in-cluster model)

Then it generates secrets, deploys via kustomize, and starts your instance.

### Access

**OpenShift** — URLs are displayed after `setup.sh` completes:
```
OpenClaw Gateway:  https://openclaw-<prefix>-openclaw.apps.YOUR-CLUSTER.com
```

The UI uses OpenShift OAuth login. The Control UI will prompt for the **Gateway Token**:
```bash
grep OPENCLAW_GATEWAY_TOKEN .env
```

**Kubernetes** — Use port-forwarding:
```bash
kubectl port-forward svc/openclaw 18789:18789 -n <prefix>-openclaw
# Open http://localhost:18789
```

### Verify

```bash
# Check pod is running (2 containers: gateway + init-config)
kubectl get pods -n <prefix>-openclaw
```

## A2A (Agent-to-Agent) Communication

> **Advanced:** A2A requires SPIRE and Keycloak infrastructure on your cluster. Most users don't need this.

To enable cross-namespace agent communication with zero-trust authentication, deploy with the `--with-a2a` flag:

```bash
./scripts/setup.sh --with-a2a              # OpenShift
./scripts/setup.sh --k8s --with-a2a        # Kubernetes
```

This adds A2A bridge + AuthBridge sidecars (SPIFFE + Envoy + Keycloak) to each instance, enabling agents to discover and message each other across namespaces.

```
 Sally's Namespace                          Bob's Namespace
 ┌──────────────────────────────┐          ┌──────────────────────────────┐
 │  sally-openclaw              │          │  bob-openclaw                │
 │                              │   A2A    │                              │
 │  Agent: Lynx                 │◄────────►│  Agent: Shadowman            │
 │  (sally_lynx)                │  JSON-RPC│  (bob_shadowman)             │
 │                              │          │                              │
 │  Gateway + A2A Bridge        │          │  Gateway + A2A Bridge        │
 │  AuthBridge (SPIFFE + Envoy) │          │  AuthBridge (SPIFFE + Envoy) │
 └──────────────────────────────┘          └──────────────────────────────┘
          │                                          │
          └──────────── Keycloak ────────────────────┘
                    (token exchange)
```

**A2A prerequisites:**
- SPIRE + Keycloak infrastructure deployed (see [Cluster Prerequisites](docs/A2A-ARCHITECTURE.md#cluster-prerequisites))
- Cluster-admin access (for AuthBridge SCC on OpenShift)
- The script will prompt for Keycloak URL, realm, and admin credentials

**How it works:**
1. Each pod runs an **A2A bridge** sidecar on port 8080 that translates [A2A JSON-RPC](https://github.com/google/A2A) to OpenClaw's internal API
2. The **AuthBridge** (Envoy + SPIFFE + Keycloak) transparently authenticates every cross-namespace call — agents never handle tokens
3. An **A2A skill** loaded into each agent teaches it how to discover and message remote instances

See [docs/A2A-ARCHITECTURE.md](docs/A2A-ARCHITECTURE.md) for the full architecture and [docs/A2A-SECURITY.md](docs/A2A-SECURITY.md) for the security model.

## Additional Agents

Beyond the default interactive agent, you can deploy additional agents with specialized capabilities:

```bash
./scripts/setup-agents.sh           # OpenShift
./scripts/setup-agents.sh --k8s     # Kubernetes
```

This adds:
- **Resource Optimizer** — K8s resource analysis with RBAC, CronJobs, and scheduled cost reports
- **MLOps Monitor** — Monitors the NPS Agent's MLflow traces and evaluation results, reports anomalies
- **NPS Skill** — Teaches the default agent to query the NPS Agent for national park information

See [docs/ADDITIONAL-AGENTS.md](docs/ADDITIONAL-AGENTS.md) for details.

## NPS Agent

A standalone AI agent that answers questions about U.S. national parks, deployed to its own namespace with a separate SPIFFE identity:

```bash
./scripts/setup-nps-agent.sh
```

The NPS Agent runs an [upstream Python agent](https://github.com/Nehanth/nps_agent) with 5 MCP tools connected to the NPS API, served via an A2A bridge with full AuthBridge authentication.

**Evaluation:** A CronJob runs weekly (Monday 8 AM UTC) with 6 test cases scored by MLflow's GenAI scorers (Correctness, RelevanceToQuery). Results appear in the "NPSAgent" MLflow experiment.

```bash
# Trigger an eval run manually
oc create job nps-eval-$(date +%s) --from=cronjob/nps-eval -n nps-agent

# Check results
JOB_NAME=$(oc get jobs -n nps-agent -l component=eval \
  --sort-by='{.metadata.creationTimestamp}' -o jsonpath='{.items[-1].metadata.name}')
oc logs -l job-name=$JOB_NAME -n nps-agent
```

See [docs/ADDITIONAL-AGENTS.md](docs/ADDITIONAL-AGENTS.md) for architecture details.

## Teardown

```bash
./scripts/teardown.sh                   # OpenShift
./scripts/teardown.sh --k8s             # Kubernetes
./scripts/teardown.sh --delete-env      # Also delete .env file
```

## Configuration Management

OpenClaw's config (`openclaw.json`) can be edited through the Control UI or directly in the manifests.

```
.envsubst template          ConfigMap              PVC (live config)
(source of truth)    -->    (K8s object)    -->    /home/node/.openclaw/openclaw.json
                          setup.sh runs           init container copies
                          envsubst + deploy       on every pod restart
```

The init container overwrites config on every pod restart. UI changes live only on the PVC. Export before restarting:

```bash
./scripts/export-config.sh              # Export live config
./scripts/export-config.sh -o out.json  # Custom output path
```

See the `.envsubst` templates in `manifests/openclaw/overlays/` for the full config structure.

### Update Without Re-running setup.sh

If you already have OpenClaw running and just want to apply manifest changes:

```bash
source .env && set -a
ENVSUBST_VARS='${CLUSTER_DOMAIN} ${OPENCLAW_GATEWAY_TOKEN} ${OPENCLAW_OAUTH_CLIENT_SECRET} ${OPENCLAW_OAUTH_COOKIE_SECRET}'
for tpl in manifests/openclaw/overlays/openshift/*.envsubst; do
  envsubst "$ENVSUBST_VARS" < "$tpl" > "${tpl%.envsubst}"
done

oc apply -k manifests/openclaw/overlays/openshift/
```

## Repository Structure

```
openclaw-k8s/
├── scripts/
│   ├── setup.sh                # Deploy OpenClaw (add --with-a2a for A2A)
│   ├── setup-agents.sh         # Deploy additional agents + skills
│   ├── setup-nps-agent.sh      # Deploy NPS Agent (separate namespace)
│   ├── create-cluster.sh       # Create a KinD cluster for local testing
│   ├── update-jobs.sh          # Update cron jobs (quick iteration)
│   ├── export-config.sh        # Export live config from running pod
│   ├── teardown.sh             # Remove everything
│   └── build-and-push.sh       # Build images with podman (optional)
│
├── manifests/
│   ├── openclaw/
│   │   ├── base/               # Core: deployment, service, PVCs, A2A resources
│   │   ├── base-k8s/           # K8s-specific patches (strips OpenShift resources)
│   │   ├── patches/            # Optional patches (strip-a2a.yaml)
│   │   ├── overlays/
│   │   │   ├── openshift/      # OpenShift overlay (secrets, config, OAuth, routes)
│   │   │   └── k8s/            # Vanilla Kubernetes overlay
│   │   ├── agents/             # Agent configs, RBAC, cron jobs
│   │   ├── skills/             # Agent skills (NPS, A2A)
│   │   └── llm/                # vLLM reference deployment (GPU model server)
│   │
│   └── nps-agent/              # NPS Agent deployment (own namespace + identity)
│
├── observability/              # OTEL sidecar and collector templates
│
└── docs/
    ├── ARCHITECTURE.md         # Overall architecture
    ├── A2A-ARCHITECTURE.md     # A2A + AuthBridge deep dive
    ├── A2A-SECURITY.md         # Identity vs. content security, audit, DLP roadmap
    ├── ADDITIONAL-AGENTS.md    # Resource-optimizer, cron jobs, RBAC
    ├── OBSERVABILITY.md        # OpenTelemetry + MLflow
    └── TEAMMATE-QUICKSTART.md  # Quick onboarding guide
```

## Security

The gateway container runs with security hardening:

- Read-only root filesystem, all capabilities dropped, no privilege escalation
- ResourceQuota, PodDisruptionBudget
- Token-based gateway auth + OAuth proxy (OpenShift)
- Exec allowlist mode (only `curl` and `jq` permitted)

With `--with-a2a`, additional security features are enabled:
- Custom `openclaw-authbridge` SCC for AuthBridge sidecar capabilities (OpenShift)
- SPIFFE workload identity per namespace (cryptographic, auditable)

See [docs/OPENSHIFT-SECURITY-FIXES.md](docs/OPENSHIFT-SECURITY-FIXES.md) for the full security posture. With A2A enabled, see [docs/A2A-ARCHITECTURE.md](docs/A2A-ARCHITECTURE.md) and [docs/A2A-SECURITY.md](docs/A2A-SECURITY.md).

## Troubleshooting

**Agent not appearing in Control UI:**
- Check config: `kubectl get configmap openclaw-config -n <prefix>-openclaw -o yaml`
- Restart gateway: `kubectl rollout restart deployment/openclaw -n <prefix>-openclaw`

**Setup script fails with "not logged in to OpenShift":**
- Run `oc login https://api.YOUR-CLUSTER:6443` first

**A2A-specific issues (only with `--with-a2a`):**

- **Pod not starting (SCC issues):** Grant the custom SCC: `oc adm policy add-scc-to-user openclaw-authbridge -z openclaw-oauth-proxy -n <prefix>-openclaw`
- **A2A bridge returning 401:** Check SPIFFE helper credentials: `oc exec deployment/openclaw -c spiffe-helper -- ls -la /opt/`
- **Cross-namespace call failing:** Verify SPIRE registration entry exists for the target namespace; check Envoy logs: `oc logs deployment/openclaw -c envoy-proxy`

## License

MIT
