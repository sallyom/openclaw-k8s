# Additional Agents

Beyond the default interactive agent deployed by `setup.sh`, you can add specialized agents with K8s RBAC, CronJobs, and scheduled tasks.

## Deploy

```bash
# Wait for OpenClaw to be ready
oc rollout status deployment/openclaw -n <prefix>-openclaw --timeout=600s

# Deploy additional agents
./scripts/setup-agents.sh           # OpenShift
./scripts/setup-agents.sh --k8s     # Kubernetes
```

The script:
- Runs `envsubst` on agent templates
- Deploys agent ConfigMaps (identity files, instructions)
- Sets up RBAC (ServiceAccount, Roles, RoleBindings)
- Installs agent identity files (AGENTS.md, agent.json) into workspaces
- Deploys demo workloads for the resource-optimizer to analyze
- Configures cron jobs for scheduled agent tasks
- Restarts OpenClaw to load the new agents

## Agents

### Resource Optimizer

| Field | Value |
|-------|-------|
| Agent ID | `<prefix>_resource_optimizer` |
| Model | In-cluster (20B) |
| Schedule | CronJob every 8 hours + internal cron at 9 AM / 5 PM UTC |
| Namespace access | `resource-demo` (read-only) |

The resource-optimizer demonstrates K8s-native features compensating for small model limitations:

1. **K8s CronJob** (no LLM): Runs every 8 hours, queries the K8s API for resource metrics across the `resource-demo` namespace, builds a plain-text report, writes it to the `resource-report-latest` ConfigMap
2. **OpenClaw internal cron** (LLM): Wakes the agent at 9 AM and 5 PM UTC. Agent reads the pre-collected report from `/data/reports/resource-optimizer/report.txt` (mounted ConfigMap), analyzes it, and messages the default agent via `sessions_send` if anything notable is found

This split works well with small models — the CronJob handles the complex K8s API queries and JSON parsing, while the agent handles reading structured text and producing short summaries.

**RBAC setup:**
- ServiceAccount `resource-optimizer-sa` in `<prefix>-openclaw`
- Read-only access to pods, deployments, services, PVCs in `resource-demo`
- Write access to `resource-report-latest` ConfigMap in `<prefix>-openclaw`
- SA token injected into agent workspace `.env` as `OC_TOKEN`

**Demo workloads:**
- `setup-agents.sh` creates the `resource-demo` namespace and deploys sample workloads for the agent to analyze
- Manifests at `agents/openclaw/agents/demo-workloads/`

### MLOps Monitor

| Field | Value |
|-------|-------|
| Agent ID | `<prefix>_mlops_monitor` |
| Model | In-cluster (20B) |
| Schedule | CronJob every 6 hours + internal cron at 10 AM / 4 PM UTC |
| Data source | MLflow tracking server (NPS Agent traces + eval results) |

The MLOps monitor follows the same CronJob + agent pattern as the resource optimizer:

1. **K8s CronJob** (no LLM): Runs every 6 hours, queries the MLflow REST API for recent NPS Agent traces, computes stats (total traces, avg latency, error count, tool call breakdown, eval scores), writes a report to the `mlops-report-latest` ConfigMap
2. **OpenClaw internal cron** (LLM): Wakes the agent at 10 AM and 4 PM UTC. Agent reads the report from `/data/reports/mlops-monitor/report.txt`, analyzes for anomalies (high error rates >5%, latency spikes, low eval scores), and messages the default agent if anything notable is found

**RBAC setup:**
- ServiceAccount `mlops-monitor-sa` in `<prefix>-openclaw`
- Write access to `mlops-report-latest` ConfigMap
- MLflow tracking URI stored in `mlops-monitor-secrets` Secret

### NPS Agent (Separate Namespace)

| Field | Value |
|-------|-------|
| Namespace | `nps-agent` (own SPIFFE identity) |
| Source | https://github.com/Nehanth/nps_agent (S2I build) |
| API | A2A bridge on port 8080, `/invocations` on port 8090 |
| Model | In-cluster vLLM (`openai/gpt-oss-20b`) via `OpenAIChatCompletionsModel` |
| Deploy script | `./scripts/setup-nps-agent.sh` |

The NPS Agent is a standalone Python agent (OpenAI Agents SDK + MCP tools + MLflow tracing) that answers questions about U.S. national parks. It deploys to its own namespace with a full AuthBridge sidecar stack for cross-namespace A2A communication.

**Architecture:**
```
┌─ nps-agent pod ──────────────────────────────────────────┐
│  [proxy-init]         (init: iptables for Envoy)         │
│  [nps-agent]          port 8090  ← /invocations, /ping   │
│  [a2a-bridge]         port 8080  ← A2A JSON-RPC          │
│  [spiffe-helper]                 ← fetches SVIDs          │
│  [client-registration]           ← registers with Keycloak│
│  [envoy-proxy]        port 15123/15124 ← token exchange   │
└──────────────────────────────────────────────────────────┘
```

**MCP Tools:** `search_parks`, `get_park_alerts`, `get_park_campgrounds`, `get_park_events`, `get_visitor_centers`

**vLLM Compatibility:** The upstream agent uses `OpenAIResponsesModel`, which doesn't work with vLLM (MultiProvider strips the `openai/` prefix, and vLLM's Responses API can't handle `function_call_output` content). The `npsagent-patch.yaml` ConfigMap patches `npsagent.py` to use `OpenAIChatCompletionsModel` directly, mounted over the container's version.

#### NPS Agent Evaluation

A CronJob runs evaluation test cases against the NPS Agent and scores results using MLflow's GenAI scorers.

| Field | Value |
|-------|-------|
| Schedule | Weekly Monday 8 AM UTC |
| Test cases | 6 (parks by state, park codes, campgrounds, general knowledge) |
| Scorers | Correctness, RelevanceToQuery (LLM judge via in-cluster vLLM) |
| Results | MLflow experiment "NPSAgent" |

**Run an eval manually:**
```bash
oc create job nps-eval-$(date +%s) --from=cronjob/nps-eval -n nps-agent
```

**Check results:**
```bash
# Get the latest eval job name
JOB_NAME=$(oc get jobs -n nps-agent -l component=eval \
  --sort-by='{.metadata.creationTimestamp}' -o jsonpath='{.items[-1].metadata.name}')

# Read the eval output
oc logs -l job-name=$JOB_NAME -n nps-agent
```

**Quick eval (3 test cases, no MLflow):**
```bash
oc create job nps-eval-quick -n nps-agent \
  --image=image-registry.openshift-image-registry.svc:5000/nps-agent/nps-agent:latest \
  -- python3 /eval/run_eval.py --quick --standalone
```

The eval script (`nps-agent-eval.yaml` ConfigMap) includes retry logic (5 retries with 15s waits) and a 5s cooldown between requests, since the NPS Agent spawns an MCP subprocess per request. The CronJob sets `MLFLOW_GENAI_EVAL_MAX_WORKERS=1` to serialize requests.

#### NPS Skill

The default agent has an **nps** skill installed at `~/.openclaw/skills/nps/SKILL.md` that teaches it to query the NPS Agent via curl. The skill is deployed by `setup-agents.sh`.

### Future Agents

| Agent | Directory | Status |
|-------|-----------|--------|
| Audit Reporter | `agents/openclaw/agents/audit-reporter/` | Planned |

## Cron Jobs

The `update-jobs.sh` script writes OpenClaw's internal cron job definitions to `~/.openclaw/cron/jobs.json`. Use it for quick iteration without re-running the full `setup-agents.sh`:

```bash
./scripts/update-jobs.sh              # Update jobs + restart
./scripts/update-jobs.sh --skip-restart  # Update jobs only (called by setup-agents.sh)
```

## Per-Agent Model Configuration

Each agent can use a different model provider. The model is set in the config overlay:

```json
{
  "agents": {
    "defaults": {
      "model": { "primary": "nerc/openai/gpt-oss-20b" }
    },
    "list": [
      {
        "id": "prefix_lynx",
        "model": { "primary": "anthropic/claude-sonnet-4-6" }
      },
      {
        "id": "prefix_resource_optimizer"
      }
    ]
  }
}
```

Resolution order: agent-specific `model` > `agents.defaults.model.primary` > built-in default.

Model priority during setup (auto-detected):
1. Anthropic API key provided → `anthropic/claude-sonnet-4-6`
2. Google Vertex enabled → `google-vertex/gemini-2.5-pro`
3. Neither → `nerc/openai/gpt-oss-20b` (in-cluster vLLM)

## Files

| File | Description |
|------|-------------|
| `scripts/setup-agents.sh` | Agent deployment script (all agents + skills) |
| `scripts/setup-nps-agent.sh` | NPS Agent deployment script (separate namespace) |
| `scripts/update-jobs.sh` | Cron job quick-update script |
| `agents/openclaw/agents/shadowman/` | Default agent config (customizable name) |
| `agents/openclaw/agents/resource-optimizer/` | Resource optimizer agent, RBAC, CronJob |
| `agents/openclaw/agents/mlops-monitor/` | MLOps monitor agent, RBAC, CronJob |
| `agents/openclaw/skills/nps/SKILL.md` | NPS Agent query skill for default agent |
| `agents/openclaw/agents/agents-config-patch.yaml.envsubst` | Config overlay adding agent definitions |
| `agents/nps-agent/` | NPS Agent deployment (A2A bridge, AuthBridge, eval) |
| `agents/nps-agent/nps-agent-eval.yaml` | Eval script ConfigMap (6 test cases) |
| `agents/nps-agent/nps-agent-eval-job.yaml.envsubst` | Eval CronJob (weekly + on-demand) |
| `agents/nps-agent/npsagent-patch.yaml` | vLLM compatibility patch (ChatCompletions) |
