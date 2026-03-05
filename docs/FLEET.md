# Fleet Management with OpenClaw

> Centrally governed, auditable AI agents managing a fleet of Linux machines
> from OpenShift, with every action tracked in MLflow.

## Architecture Overview

```
┌────────────────────────────── OpenShift Cluster ─────────────────────────────┐
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────────┐│
│  │  Central OpenClaw Gateway            namespace: factory-openclaw         ││
│  │                                                                          ││
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                    ││
│  │  │ supervisor-01│  │ supervisor-02│  │ supervisor-03│  Supervisor        ││
│  │  │              │  │              │  │              │  Agents            ││
│  │  │ manages:     │  │ manages:     │  │ manages:     │  (one per          ││
│  │  │  rhel-01     │  │  rhel-02     │  │  rhel-03     │   machine)         ││
│  │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘                    ││
│  │         │ sessions_send   │                 │                            ││
│  │         │ (intra-gateway) │                 │                            ││
│  │         └───────┬─────────┘                 │                            ││
│  │                 │                           │                            ││
│  │  ┌──────────────┴───────────────────────────┴────────────┐               ││
│  │  │                    A2A Bridge                         │               ││
│  │  │          (Google A2A JSON-RPC <--> OpenAI API)        │               ││
│  │  └───────────────────────┬───────────────────────────────┘               ││
│  └──────────────────────────┼────────────────────────────────────────────── ┘│
│                             │                                                │
│  ┌──────────────────┐  ┌────┴────────┐  ┌───────────────────────┐            │
│  │  MLflow          │  │ SPIRE       │  │  OTEL Collector       │            │
│  │                  │◄─│ Server      │  │  (receives traces     │            │
│  │ - Traces/spans   │  │             │  │   from all gateways)  │            │
│  │ - Experiments    │  │ Workload    │  └───────────┬───────────┘            │
│  │ - Audit trail    │  │ identity    │              │                        │
│  │ - Cost tracking  │  │ for A2A     │              │                        │
│  └──────────────────┘  └─────────────┘              │                        │
│                                                     │                        │
└──────────────────────────────┬──────────────────────┼────────────────────────┘
                               │                      │
                     A2A (SPIFFE mTLS)        OTEL (HTTP/protobuf)
                               │                       │
        ┌──────────────────────┼───────────────────────┼───────────────────┐
        │                      │                       │                   │
        │          ▼           ▼                       ▼                   │
        │  ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐  │
        │  │ Linux Machine 01 │ │ Linux Machine 02 │ │ Linux Machine 03 │  │
        │  │                  │ │                  │ │                  │  │
        │  │ ┌──────────────┐ │ │ ┌──────────────┐ │ │ ┌──────────────┐ │  │
        │  │ │ Quadlet Pod  │ │ │ │ Quadlet Pod  │ │ │ │ Quadlet Pod  │ │  │
        │  │ │              │ │ │ │              │ │ │ │              │ │  │
        │  │ │ ┌──────────┐ │ │ │ │  (stopped)   │ │ │ │ ┌──────────┐ │ │  │
        │  │ │ │ OpenClaw │ │ │ │ │              │ │ │ │ │ OpenClaw │ │ │  │
        │  │ │ │ Gateway  │ │ │ │ │  Activated   │ │ │ │ │ Gateway  │ │ │  │
        │  │ │ │ + Agent  │ │ │ │ │  only by     │ │ │ │ │ + Agent  │ │ │  │
        │  │ │ │ + OTEL   │ │ │ │ │  central     │ │ │ │ │ + OTEL   │ │ │  │
        │  │ │ │ + SPIRE  │ │ │ │ │  supervisor  │ │ │ │ │ + SPIRE  │ │ │  │
        │  │ │ └──────────┘ │ │ │ │              │ │ │ │ └──────────┘ │ │  │
        │  │ └──────────────┘ │ │ └──────────────┘ │ │ └──────────────┘ │  │
        │  │                  │ │                  │ │                  │  │
        │  │ exec/read/write  │ │                  │ │ exec/read/write  │  │
        │  │ on local machine │ │                  │ │ on local machine │  │
        │  └──────────────────┘ └──────────────────┘ └──────────────────┘  │
        │                                                    Factory Floor │
        └───────────────────────────────────────────────────────────────── ┘
```

## Supervision Model

The central supervisor controls the lifecycle of every Linux agent.
Linux agents **cannot act** unless the supervisor explicitly activates them.

```
  Central Supervisor                    Linux Machine
  ─────────────────                    ────────────

  1. Decide action needed
     (cron, alert, human)
          │
          ▼
  2. Start Linux agent ──── ssh ────►  systemctl --user start openclaw-agent
                                              │
                                              ▼
                                      Quadlet starts pod
                                      Agent boots, OTEL connects
                                      SPIRE agent gets identity
                                              │
          ◄──────── A2A registration ─────────┘
          │
          ▼
  3. Send task via A2A ──────────────► Agent receives task
                                              │
                                              ▼
                                      Agent executes locally:
                                        - exec: run commands
                                        - read: check files/logs
                                        - write: update configs
                                              │
                                              ▼
                                      OTEL traces ──────► MLflow
                                              │
          ◄──────── A2A response ─────────────┘
          │
          ▼
  4. Evaluate results
     (success? escalate?)
          │
          ▼
  5. Stop Linux agent ───── ssh ────►  systemctl --user stop openclaw-agent
                                              │
                                              ▼
                                      Pod stops. Agent inert.
                                      No autonomous action possible.
```

## Components

### Central OpenShift Gateway

The brain of the operation. Runs on OpenShift with:

- **Supervisor agents** (one per Linux machine) — each knows its machine's
  hostname, role, expected state, and what actions it's authorized to take
- **A2A bridge** — translates between OpenClaw's API and the Google A2A
  protocol for cross-gateway communication
- **OTEL sidecar** — collects traces from the central gateway and forwards
  to MLflow
- **Intra-gateway A2A** — supervisors can coordinate with each other via
  `sessions_send` (e.g., "machine-01's agent found a disk issue, tell
  machine-02's agent to check if it's affected too")

### Edge Machines

Each Linux machine runs OpenClaw as a podman Quadlet managed by systemd.
The agent is stopped by default (`Restart=no`) — only the central supervisor
can start it via SSH.

Key design choices:
- **Same container image** (`quay.io/aicatalyst/openclaw:latest`) as OpenShift — no drift
- **`Network=host`** — agent can reach local services, databases, APIs
- **SELinux enforcing** — `:Z` volume labeling, non-root container (uid 1000)
- **Persistent volume** — config, workspace, session history survive restarts

See [`agents/openclaw/edge/README.md`](../agents/openclaw/edge/README.md) for Quadlet files, config templates,
and the interactive setup script.

### Models

Edge agents support multiple model providers:

| Provider | Description |
|----------|-------------|
| **RHEL Lightspeed** (default) | Local LLM via [RamaLama + llama.cpp](https://www.redhat.com/en/blog/use-rhel-command-line-assistant-offline-new-developer-preview). Phi-4-mini (Q4_K_M, ~2.4GB) on CPU, no GPU required. Endpoint: `http://127.0.0.1:8888/v1`. Includes RAG database with RHEL documentation. |
| **Anthropic** (optional) | Claude Sonnet 4.6 via `https://api.anthropic.com`. Requires API key. |
| **Central vLLM** | In-cluster GPU model server on OpenShift. See [`agents/openclaw/llm/`](../agents/openclaw/llm/). |

The setup script (`edge/scripts/setup-edge.sh`) defaults to RHEL Lightspeed
and optionally adds Anthropic when an API key is provided.

### Observability (MLflow + OTEL)

Every agent action across the entire fleet flows to one place:

```
Edge Agent (exec "df -h")
    │
    ▼
Local OTEL Collector (127.0.0.1:4318)
    │
    ▼
Central MLflow (OpenShift route)
    │
    ▼
Dashboard: who did what, when, on which machine, what was the result
```

Traces include:
- `message.queued` / `message.processed` — full request lifecycle
- `model.inference` — every LLM call with token counts and cost
- `tool.execution` — every exec/read/write with arguments and results
- `run.completed` — agent run summary with duration and outcome

The local OTEL collector (`ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib`)
enriches traces with `host.name` and `deployment.environment: edge` attributes
for filtering in MLflow.

### Security Boundaries

```
┌─────────────────────────────────────────────────────────┐
│ Layer 1: Systemd (Linux)                                │
│   Agent pod is stopped by default. Only SSH from        │
│   authorized central gateway can start it.              │
│                                                         │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ Layer 2: SPIFFE/SPIRE (Identity)                    │ │
│ │   Each agent has a cryptographic workload identity. │ │
│ │   A2A calls are mutually authenticated via mTLS.    │ │
│ │   No static API keys on the wire.                   │ │
│ │                                                     │ │
│ │ ┌─────────────────────────────────────────────────┐ │ │
│ │ │ Layer 3: OpenClaw (Authorization)               │ │ │
│ │ │   exec tool restricted via allowlist:           │ │ │
│ │ │     safeBins: ["systemctl", "journalctl", ...]  │ │ │
│ │ │   Agent system prompt defines scope of action.  │ │ │
│ │ │   All actions traced to MLflow for audit.       │ │ │
│ │ └─────────────────────────────────────────────────┘ │ │
│ │                                                     │ │
│ │ ┌─────────────────────────────────────────────────┐ │ │
│ │ │ Layer 4: SELinux + Podman (Container)           │ │ │
│ │ │   Container runs as non-root (uid 1000).        │ │ │
│ │ │   Volume mounts labeled with :Z.                │ │ │
│ │ │   Network=host for local access only.           │ │ │
│ │ └─────────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## Implementation Phases

### Phase 1: Single Linux Machine (SSH, no A2A)

Prove the core loop: central agent manages a remote Linux agent.

- Central gateway on OpenShift with one supervisor agent
- Linux machine with OpenClaw Quadlet + local OTEL collector
- Supervisor uses SSH to start/stop the Quadlet and `curl` to send tasks
  to the Linux gateway's chat completions API
- All traces flow to central MLflow via the OTEL collector
- Demo: supervisor checks disk health, reviews logs, reports back

**No SPIRE/Keycloak needed.** Token auth between gateways.

### Phase 2: Multi-Machine Fleet

Scale to multiple Linux machines with intra-gateway coordination.

- Multiple supervisor agents on central gateway
- Multiple Linux machines with Quadlets
- Supervisors coordinate via `sessions_send`:
  *"Machine 01 found a kernel warning — check machines 02 and 03 for
  the same issue"*
- Fleet-wide view in MLflow

### Phase 3: A2A with SPIRE

Replace SSH+token auth with zero-trust A2A.

- SPIRE agents on Linux machines (systemd service)
- Full SPIFFE mTLS for all cross-gateway communication
- Keycloak token exchange for OAuth compliance
- No static credentials on any Linux machine
