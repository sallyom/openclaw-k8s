# Architecture

## Overview

OpenClaw is an AI agent runtime platform. This repo deploys it on Kubernetes (OpenShift or vanilla K8s) with per-user namespaces,
OpenTelemetry observability, and security hardening.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Developer/Operator (You)                                       │
└───┬─────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│  OpenClaw Pod (Namespace: <prefix>-openclaw)                    │
│                                                                 │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  Agent Runtime                                             │ │
│  │  ┌──────────────────── ┐     ┌────────────────────┐        │ │
│  │  │  Shadowman/Lynx     │     │  Resource Optimizer│        │ │
│  │  │  (customizable)     │     │  Schedule: CronJob │        │ │
│  │  │  Model: configurable│     │  Model: in-cluster │        │ │
│  │  └──────────────────── ┘     └────────────────────┘        │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                 │
│  ┌──────────────┐ ┌────────────┐ ┌────────────────────────────┐ │
│  │  Gateway     │ │ A2A Bridge │ │  OTEL Collector Sidecar    │ │
│  │  :18789      │ │ :8080      │ │  (auto-injected)           │ │
│  └──────────────┘ └────────────┘ └────────────────────────────┘ │
│                                                                 │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  AuthBridge (transparent zero-trust)                       │ │
│  │  ┌───────────┐ ┌─────────────────┐ ┌────────────────────┐  │ │
│  │  │  Envoy    │ │ Client          │ │ SPIFFE Helper      │  │ │
│  │  │  Proxy    │ │ Registration    │ │ (SPIRE CSI)        │  │ │
│  │  └───────────┘ └─────────────────┘ └────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                 │
│  Sessions stored on PVC                                         │
│  Config: openclaw.json (ConfigMap → PVC)                        │
└────────────────────┬────────────────────────────────────────────┘
                     │
         ┌───────────┼───────────────┐
         ▼           ▼               ▼
┌──────────────┐ ┌────────────┐ ┌─────────────────┐
│ Model        │ │ Other      │ │ Keycloak        │
│ Providers    │ │ OpenClaw   │ │ (SPIFFE realm)  │
│ - Anthropic  │ │ Instances  │ │                 │
│ - Vertex AI  │ │ (via A2A)  │ │ Token exchange  │
│ - vLLM       │ │            │ │ + validation    │
└──────────────┘ └────────────┘ └─────────────────┘
```

## Key Components

### OpenClaw Gateway
- Single-pod deployment running all agents in one process
- WebSocket + HTTP multiplexed on port 18789
- Control UI (settings, sessions, agent management)
- WebChat interface for interacting with agents
- Cron scheduler for scheduled agent tasks

### Agent Workspaces
Each agent gets an isolated workspace on the PVC:
- `AGENTS.md` — agent identity and instructions
- `agent.json` — agent metadata (name, description, capabilities)
- `.env` — agent-specific credentials (e.g., K8s SA tokens)

### Config Lifecycle
```
.envsubst template → envsubst → ConfigMap → init container → PVC
(git-committed)      (setup.sh)  (K8s)       (pod restart)   (runtime)
```

The init container overwrites `openclaw.json` on every pod restart.
UI changes live only on the PVC and are lost unless exported and merged back into the `.envsubst` template.

### OpenTelemetry Observability
- `diagnostics-otel` plugin emits OTLP traces from the gateway
- Sidecar OTEL collector (auto-injected by OpenTelemetry Operator)
- Traces exported to MLflow for LLM-specific visualization
- W3C Trace Context propagation to downstream services (e.g., vLLM)

See [OBSERVABILITY.md](OBSERVABILITY.md) for details.

### A2A Cross-Namespace Communication
- A2A bridge sidecar translates Google A2A JSON-RPC to OpenClaw's OpenAI-compatible API
- AuthBridge (Envoy + SPIFFE + Keycloak) provides transparent zero-trust authentication
- Agent cards served at `/.well-known/agent.json` for discovery
- A2A skill teaches agents to discover and message remote instances using `curl` + `jq`

See [A2A-ARCHITECTURE.md](A2A-ARCHITECTURE.md) for the full design, message flow, and security model.

### Security
- Custom `openclaw-authbridge` SCC grants only AuthBridge capabilities (NET_ADMIN, NET_RAW, spc_t, CSI)
- Gateway container fully hardened: read-only root FS, all caps dropped, no privilege escalation
- ResourceQuota, PodDisruptionBudget, NetworkPolicy
- Token-based gateway auth + OAuth proxy (OpenShift)
- Exec allowlist mode (only `curl`, `jq` permitted)
- Per-agent tool allow/deny policies
- SPIFFE workload identity per namespace (cryptographic, auditable)

## Deployment Flow

```
1. setup.sh
   ├── Prompt for prefix, API keys
   ├── Generate secrets → .env
   ├── envsubst on all .envsubst templates
   ├── Create namespace
   ├── Deploy via kustomize overlay (includes AuthBridge sidecars)
   ├── Create OAuthClient (OpenShift only)
   └── Install A2A skill into agent workspace

2. Grant SCC (OpenShift only)
   └── oc adm policy add-scc-to-user openclaw-authbridge -z openclaw-oauth-proxy -n <ns>

3. setup-agents.sh (optional)
   ├── Prompt for agent name customization
   ├── envsubst on agent templates
   ├── Deploy agent ConfigMaps
   ├── Set up RBAC (resource-optimizer SA)
   ├── Install agent identity files into workspaces
   └── Configure cron jobs
```

## Per-Agent Model Configuration

Each agent can use a different model provider:

```json
{
  "agents": {
    "defaults": {
      "model": { "primary": "nerc/openai/gpt-oss-20b" }
    },
    "list": [
      {
        "id": "prefix_lynx",
        "model": { "primary": "anthropic/claude-sonnet-4-5" }
      },
      {
        "id": "prefix_resource_optimizer"
      }
    ]
  }
}
```

Resolution order: agent-specific `model` → `agents.defaults.model.primary` → built-in default.

## Directory Structure Inside Pod

```
~/.openclaw/
├── openclaw.json                          # Gateway config (from ConfigMap)
├── agents/
│   ├── <prefix>_<name>/sessions/          # Session transcripts
│   └── <prefix>_resource_optimizer/sessions/
├── workspace-<prefix>_<name>/             # Agent workspace
│   ├── AGENTS.md
│   └── agent.json
├── workspace-<prefix>_resource_optimizer/
│   ├── AGENTS.md
│   ├── agent.json
│   └── .env                               # OC_TOKEN (K8s SA token)
├── skills/
│   └── a2a/SKILL.md                       # A2A cross-instance communication skill
├── cron/jobs.json                         # Cron job definitions
└── scripts/                               # Deployed scripts (resource-report.sh)
```
