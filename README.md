# openclaw-k8s

Deploy OpenClaw — an AI agent runtime platform — on OpenShift or vanilla Kubernetes. Each team member gets their own instance with a named agent. Agents communicate across namespaces using the [A2A protocol](https://github.com/google/A2A) with zero-trust authentication via SPIFFE and Keycloak.

## What This Deploys

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

Each instance runs:
- An AI agent with a customizable name (chosen during setup)
- An A2A bridge sidecar for cross-instance communication
- AuthBridge sidecars for transparent zero-trust identity (SPIFFE/Keycloak)
- Control UI + WebChat on port 18789

## Quick Start

> **Tip:** This repo is designed to be AI-navigable. Point an AI coding assistant (Claude Code, Codex, etc.) at this directory and ask it to help you deploy, troubleshoot, or customize your setup.

### Prerequisites

**OpenShift (default):**
- `oc` CLI installed and logged in (`oc login`)
- Cluster-admin access (for OAuthClient and SCC creation)
- SPIRE + Keycloak infrastructure deployed (see [Cluster Prerequisites](docs/A2A-ARCHITECTURE.md#cluster-prerequisites))

**Vanilla Kubernetes (minikube, kind, etc.):**
- `kubectl` CLI installed with a valid kubeconfig
- A2A works but without AuthBridge authentication

### Deploy

```bash
# OpenShift (default)
./scripts/setup.sh

# Or vanilla Kubernetes
./scripts/setup.sh --k8s
```

The script will prompt for:
- **Namespace prefix** (e.g., `sally`) — creates `sally-openclaw` namespace
- **Agent name** (e.g., `Lynx`) — this is who your teammates see when communicating via A2A
- **Anthropic API key** (optional — without it, agents use the in-cluster model)

Then it generates secrets, deploys via kustomize, and installs the A2A skill.

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
# Check pod is running (7 containers: gateway, a2a-bridge, oauth-proxy,
# spiffe-helper, client-registration, envoy-proxy, otel-collector)
oc get pods -n <prefix>-openclaw

# Check agent card (A2A discovery)
oc exec deployment/openclaw -c gateway -- \
  curl -s http://localhost:8080/.well-known/agent.json | jq .
```

## Cross-Namespace Agent Communication

This is the main demo feature. Once two or more team members have deployed their instances, agents can discover and message each other across namespaces.

### How It Works

1. Each pod runs an **A2A bridge** sidecar on port 8080 that translates [A2A JSON-RPC](https://github.com/google/A2A) to OpenClaw's internal API
2. The **AuthBridge** (Envoy + SPIFFE + Keycloak) transparently authenticates every cross-namespace call — agents never handle tokens
3. An **A2A skill** loaded into each agent teaches it how to discover and message remote instances

### Example: Sally's Lynx Talks to Bob's Shadowman

Lynx discovers the local agents and the remote Shadowman on Bob's instance, sends a message via A2A, and relays the response — all with zero-trust authentication handled transparently by the AuthBridge:

![Lynx communicating with Shadowman across namespaces via A2A](images/a2a.png)

Every cross-namespace call is traced end-to-end via OpenTelemetry, with full GenAI semantic conventions (token counts, model, latency):

![OTEL trace of a cross-namespace A2A call in MLflow](images/a2a-trace.png)

### Security Model

- Each instance gets a unique SPIFFE identity: `spiffe://demo.example.com/ns/<namespace>/sa/openclaw-oauth-proxy`
- Outbound calls: Envoy intercepts, exchanges SPIFFE JWT for Keycloak OAuth token, injects into request
- Inbound calls: Envoy validates caller's OAuth token before forwarding to A2A bridge
- Gateway container is fully hardened: read-only FS, all capabilities dropped, no privilege escalation

See [docs/A2A-ARCHITECTURE.md](docs/A2A-ARCHITECTURE.md) for the full architecture, message flow diagrams, pod component breakdown, and cluster prerequisites. See [docs/A2A-SECURITY.md](docs/A2A-SECURITY.md) for the identity vs. content security model, audit trail, and DLP roadmap.

## Additional Agents

Beyond the default interactive agent, you can deploy additional agents with specialized capabilities:

```bash
./scripts/setup-agents.sh           # OpenShift
./scripts/setup-agents.sh --k8s     # Kubernetes
```

This adds a **Resource Optimizer** agent with K8s RBAC, CronJobs, and scheduled analysis. See [docs/ADDITIONAL-AGENTS.md](docs/ADDITIONAL-AGENTS.md) for details.

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

## Repository Structure

```
openclaw-k8s/
├── scripts/
│   ├── setup.sh                # Deploy OpenClaw + A2A skill
│   ├── setup-agents.sh         # Deploy additional agents (resource-optimizer)
│   ├── update-jobs.sh          # Update cron jobs (quick iteration)
│   ├── export-config.sh        # Export live config from running pod
│   ├── teardown.sh             # Remove everything
│   └── build-and-push.sh      # Build images with podman (optional)
│
├── manifests/
│   └── openclaw/
│       ├── base/               # Core: deployment (7 containers), service, PVCs,
│       │                       #   A2A bridge, AuthBridge, custom SCC
│       ├── overlays/
│       │   ├── openshift/      # OpenShift overlay (secrets, config, OAuth, routes)
│       │   └── k8s/            # Vanilla Kubernetes overlay
│       ├── agents/             # Additional agent configs, RBAC, cron jobs
│       ├── skills/             # Reusable agent skills (A2A communication)
│       └── llm/                # vLLM reference deployment (GPU model server)
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

The gateway container runs with enterprise security hardening:

- Read-only root filesystem, all capabilities dropped, no privilege escalation
- Custom `openclaw-authbridge` SCC grants only AuthBridge sidecar capabilities (NET_ADMIN, NET_RAW, spc_t)
- ResourceQuota, PodDisruptionBudget, NetworkPolicy
- Token-based gateway auth + OAuth proxy (OpenShift)
- Exec allowlist mode (only `curl` and `jq` permitted)
- SPIFFE workload identity per namespace (cryptographic, auditable)

See [docs/A2A-ARCHITECTURE.md](docs/A2A-ARCHITECTURE.md) for the custom SCC rationale and [docs/OPENSHIFT-SECURITY-FIXES.md](docs/OPENSHIFT-SECURITY-FIXES.md) for the full security posture.

## Troubleshooting

**Pod not starting (SCC issues):**
- Grant the custom SCC: `oc adm policy add-scc-to-user openclaw-authbridge -z openclaw-oauth-proxy -n <prefix>-openclaw`

**A2A bridge returning 401:**
- Check SPIFFE helper has credentials: `oc exec deployment/openclaw -c spiffe-helper -- ls -la /opt/`
- Check client registration completed: `oc logs deployment/openclaw -c client-registration`

**Cross-namespace call failing:**
- Verify SPIRE registration entry exists for the target namespace
- Check Envoy logs: `oc logs deployment/openclaw -c envoy-proxy`

**Agent not appearing in Control UI:**
- Check config: `oc get configmap openclaw-config -n <prefix>-openclaw -o yaml`
- Restart gateway: `oc rollout restart deployment/openclaw -n <prefix>-openclaw`

**Setup script fails with "not logged in to OpenShift":**
- Run `oc login https://api.YOUR-CLUSTER:6443` first

## License

MIT
