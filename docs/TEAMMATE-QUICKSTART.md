# Teammate Quickstart

Get your own OpenClaw instance running in minutes.

## What You Need

- Access to the cluster (`oc login` or `kubectl` configured)
- (Optional) An Anthropic API key for Claude-powered agents

## Model Options

OpenClaw agents need an LLM endpoint. You have several options:

| Option | When to Use | Details |
|--------|------------|---------|
| **Anthropic API key** | You have an Anthropic API key and want to use Claude | Agents use `anthropic/claude-sonnet-4-5` |
| **Anthropic via Vertex** | Your org has Claude enabled on GCP Vertex AI | Agents use `anthropic-vertex/claude-sonnet-4-5`, billed through GCP |
| **Google Vertex AI** | Your org has a GCP project with Vertex AI enabled | Agents use `google-vertex/gemini-2.5-pro`, billed through GCP |
| **In-cluster vLLM** | Your cluster has a GPU node with vLLM deployed | Default `MODEL_ENDPOINT`: `http://vllm.openclaw-llms.svc.cluster.local/v1` |
| **Your own endpoint** | You already have an OpenAI-compatible model server | Supply your server's `/v1` URL as `MODEL_ENDPOINT` |

## Step 1: Deploy Your OpenClaw

```bash
git clone <this-repo>
cd openclaw-k8s

./scripts/setup.sh           # OpenShift
./scripts/setup.sh --k8s     # Kubernetes (KinD, minikube, etc.)
```

The script prompts you for:

1. **Namespace prefix** — use your name (e.g., `bob`). Creates `bob-openclaw`.
2. **Agent name** — pick a name for your agent (e.g., `Shadowman`, `Lynx`, `Atlas`).
3. **API keys** — Anthropic key (optional), model endpoint, Vertex AI (optional).

After setup completes, your instance has:
- A gateway with your named agent
- Control UI + WebChat

## Step 2: Access Your Platform

**OpenShift** — URL shown at the end of `setup.sh` output:
```
OpenClaw Gateway:  https://openclaw-<prefix>-openclaw.apps.YOUR-CLUSTER.com
```

The UI uses OpenShift OAuth. The Control UI prompts for your **Gateway Token**:
```bash
grep OPENCLAW_GATEWAY_TOKEN .env
```

**Kubernetes** — port-forward:
```bash
kubectl port-forward svc/openclaw 18789:18789 -n <prefix>-openclaw
# Open http://localhost:18789
```

## Step 3: Deploy Additional Agents (Optional)

To add the resource-optimizer and mlops-monitor agents:

```bash
./scripts/setup-agents.sh           # OpenShift
./scripts/setup-agents.sh --k8s     # Kubernetes
```

See [ADDITIONAL-AGENTS.md](ADDITIONAL-AGENTS.md) for details.

## Step 4: Enable A2A Communication (Optional, Advanced)

To enable cross-namespace agent communication with zero-trust authentication, redeploy with A2A:

```bash
./scripts/teardown.sh && ./scripts/setup.sh --with-a2a        # OpenShift
./scripts/teardown.sh --k8s && ./scripts/setup.sh --k8s --with-a2a  # Kubernetes
```

This requires SPIRE + Keycloak infrastructure on your cluster. The script will prompt for Keycloak configuration. With A2A enabled, your instance gets:
- An **A2A bridge** sidecar (port 8080) so other instances can discover and message your agent
- **AuthBridge** sidecars (SPIFFE + Envoy) for transparent zero-trust identity
- An **A2A skill** so your agent knows how to talk to other instances

On **OpenShift**, the AuthBridge sidecars need a custom SCC. Ask your admin to run:
```bash
oc adm policy add-scc-to-user openclaw-authbridge \
  -z openclaw-oauth-proxy -n <prefix>-openclaw
```

See [A2A-ARCHITECTURE.md](A2A-ARCHITECTURE.md) for the full architecture.

## Quick Iteration

To update cron jobs or the resource-report script without a full re-deploy:

```bash
./scripts/update-jobs.sh           # OpenShift
./scripts/update-jobs.sh --k8s     # Kubernetes
```

---

## Creating Your Own Custom Agent

Use the existing agents as templates. You need two things: a ConfigMap and a config entry.

### 1. Create the Agent ConfigMap

Copy an existing agent and customize it. Save in its own directory as `manifests/openclaw/agents/myagent/myagent-agent.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: myagent-agent
  namespace: <prefix>-openclaw
  labels:
    app: openclaw
    agent: myagent
data:
  AGENTS.md: |
    ---
    name: <prefix>_myagent
    description: What your agent does
    ---
    # My Agent
    Instructions for your agent go here.

  agent.json: |
    {
      "name": "<prefix>_myagent",
      "display_name": "My Agent",
      "description": "What your agent does",
      "capabilities": ["chat"],
      "tags": ["custom"],
      "version": "1.0.0"
    }
```

### 2. Add the Agent to OpenClaw Config

Edit `manifests/openclaw/agents/agents-config-patch.yaml.envsubst`. Add your agent to the `agents.list` array:

```json
{
  "id": "${OPENCLAW_PREFIX}_myagent",
  "name": "My Agent",
  "workspace": "~/.openclaw/workspace-${OPENCLAW_PREFIX}_myagent"
}
```

### 3. Deploy

```bash
# Apply ConfigMap
oc apply -f manifests/openclaw/agents/myagent/myagent-agent.yaml

# Apply updated config
oc apply -f manifests/openclaw/agents/agents-config-patch.yaml

# Restart OpenClaw to pick up the new agent
oc rollout restart deployment/openclaw -n <prefix>-openclaw
```

Or add your agent to `setup-agents.sh` for automated deployment on future runs.
