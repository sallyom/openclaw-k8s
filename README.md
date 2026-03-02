# openclaw-infra

Deploy [OpenClaw](https://github.com/openclaw) on Kubernetes, OpenShift, and standalone Linux machines.

> All deployments use the `quay.io/sallyom/openclaw:latest` container image, which tracks upstream `openclaw/openclaw` main and adds full OpenTelemetry instrumentation via the `diagnostics-otel` extension. This ensures every agent action — tool calls, LLM inference, message lifecycle — is traced end-to-end in MLflow.

## Deployment Targets

| Target | Setup | Docs |
|--------|-------|------|
| **OpenShift** | `./scripts/setup.sh` | This README |
| **Vanilla Kubernetes** | `./scripts/setup.sh --k8s` | This README |
| **Standalone Linux** (Fedora/RHEL) | `agents/openclaw/edge/scripts/setup-edge.sh` | [edge/README.md](agents/openclaw/edge/README.md) |

## Kubernetes / OpenShift

### Quick Start

```bash
# OpenShift (default)
./scripts/setup.sh

# Vanilla Kubernetes (KinD, minikube, etc.)
./scripts/setup.sh --k8s
```

The script prompts for:
- **Namespace prefix** (e.g., `sally`) — creates `sally-openclaw` namespace
- **Agent name** (e.g., `Lynx`) — your agent's display name
- **API keys** (optional — without them, agents use the in-cluster model)

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

### Scripts

| Script | Purpose |
|--------|---------|
| `./scripts/setup.sh` | Deploy OpenClaw (add `--with-a2a` for A2A) |
| `./scripts/setup-agents.sh` | Deploy additional agents + skills |
| `./scripts/setup-nps-agent.sh` | Deploy NPS Agent (separate namespace) |
| `./scripts/create-cluster.sh` | Create a KinD cluster for local testing |
| `./scripts/export-config.sh` | Export live config from running pod |
| `./scripts/update-jobs.sh` | Update cron jobs without full re-deploy |
| `./scripts/teardown.sh` | Remove everything |

All scripts accept `--k8s` for vanilla Kubernetes.

### Additional Agents

Deploy specialized agents (Resource Optimizer, MLOps Monitor, NPS) with RBAC, CronJobs, and scheduled tasks:

```bash
./scripts/setup-agents.sh           # OpenShift
./scripts/setup-agents.sh --k8s     # Kubernetes
```

See [docs/ADDITIONAL-AGENTS.md](docs/ADDITIONAL-AGENTS.md) for details on each agent, creating your own, and the NPS evaluation framework.

### A2A (Agent-to-Agent) Communication

> **Advanced:** Requires SPIRE and Keycloak infrastructure on your cluster.

```bash
./scripts/setup.sh --with-a2a
```

Adds A2A bridge + AuthBridge sidecars (SPIFFE + Envoy + Keycloak) for cross-namespace agent messaging with zero-trust authentication.

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

See [docs/A2A-ARCHITECTURE.md](docs/A2A-ARCHITECTURE.md) and [docs/A2A-SECURITY.md](docs/A2A-SECURITY.md).

## Standalone Linux (Edge)

Deploy OpenClaw as a podman Quadlet on Fedora/RHEL machines, managed by systemd with SELinux enforcing. Designed for the [fleet management](docs/FLEET.md) model where a central OpenShift gateway supervises edge agents.

```bash
cd agents/openclaw/edge/
./scripts/setup-edge.sh
```

Installs:
- **OpenClaw agent** — same container image as K8s, running as a systemd Quadlet
- **OTEL collector** (optional) — forwards traces to central MLflow on OpenShift

See [agents/openclaw/edge/README.md](agents/openclaw/edge/README.md) for setup and [docs/FLEET.md](docs/FLEET.md) for the full architecture.

## Configuration Management

```
.envsubst template          ConfigMap              PVC (live config)
(source of truth)    -->    (K8s object)    -->    /home/node/.openclaw/openclaw.json
                          setup.sh runs           init container copies
                          envsubst + deploy       on every pod restart
```

The init container overwrites config on every pod restart. Export before restarting:

```bash
./scripts/export-config.sh
```

## Repository Structure

```
openclaw-infra/
├── platform/                   # Generic trusted A2A network platform
│   ├── base/                   # Namespace scaffolding, RBAC, quotas, PVCs, PDB
│   ├── auth-identity-bridge/   # AgentCard CR + SCC (Kagenti webhook handles sidecars)
│   ├── observability/          # OTEL sidecar configs, tracing (Jaeger, collector)
│   ├── overlays/
│   │   ├── openshift/          # OAuth proxy, Route, SCC RBAC, OAuthClient
│   │   └── k8s/                # fsGroup patches, service patches
│   └── edge/                   # Generic Quadlet scaffolding: OTEL collector
│
├── agents/
│   ├── openclaw/               # OpenClaw reference implementation
│   │   ├── base/               # Deployment, Service, ConfigMap, Secrets, Route
│   │   ├── a2a-bridge/         # A2A JSON-RPC to OpenAI bridge (ConfigMap-mounted script)
│   │   ├── overlays/
│   │   │   ├── openshift/      # Config, secrets, deployment patches (oauth-proxy)
│   │   │   └── k8s/            # Config, secrets, deployment patches (fsGroup)
│   │   ├── agents/             # Agent configs, RBAC, cron jobs
│   │   ├── skills/             # Agent skills (A2A, NPS)
│   │   ├── edge/               # OpenClaw Quadlet files, config templates, setup-edge.sh
│   │   └── llm/                # vLLM reference deployment (GPU model server)
│   ├── nps-agent/              # NPS Agent (own namespace + identity)
│   └── _template/              # Skeleton for new agent implementations
│
├── scripts/                    # K8s/OpenShift deployment scripts
└── docs/
    ├── FLEET.md                # Fleet management architecture
    ├── ADDITIONAL-AGENTS.md    # Agent details, RBAC, cron jobs
    ├── A2A-ARCHITECTURE.md     # A2A + AuthBridge deep dive
    ├── A2A-SECURITY.md         # Identity, audit, DLP roadmap
    ├── OBSERVABILITY.md        # OpenTelemetry + MLflow
    └── TEAMMATE-QUICKSTART.md  # Quick onboarding guide
```

## Security

The gateway container runs with:
- Read-only root filesystem, all capabilities dropped, no privilege escalation
- ResourceQuota, PodDisruptionBudget
- Token-based gateway auth + OAuth proxy (OpenShift)
- Exec allowlist mode (only permitted commands can be run)

See [docs/OPENSHIFT-SECURITY-FIXES.md](docs/OPENSHIFT-SECURITY-FIXES.md) for the full security posture.

## Teardown

```bash
./scripts/teardown.sh                   # OpenShift
./scripts/teardown.sh --k8s             # Kubernetes
./scripts/teardown.sh --delete-env      # Also delete .env file
```

## License

MIT
