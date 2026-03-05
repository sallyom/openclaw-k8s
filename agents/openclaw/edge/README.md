# Edge Agent Setup

Deploy OpenClaw as a rootless podman Quadlet on a Linux machine (Fedora, RHEL 9+, CentOS Stream 9+), managed by systemd user services with SELinux enforcing. No root required.

## Prerequisites

- podman (Quadlet support, 4.4+)
- systemd
- SELinux enforcing (recommended)
- A local LLM endpoint (e.g., [RHEL Lightspeed](https://www.redhat.com/en/blog/use-rhel-command-line-assistant-offline-new-developer-preview) on port 8888, ollama, vllm)

## Quick Start

```bash
git clone https://github.com/redhat-et/openclaw-k8s.git
cd openclaw-k8s/agents/openclaw/edge
./scripts/setup-edge.sh
```

The script will:
1. Verify prerequisites (podman, systemd, SELinux)
2. Prompt for agent identity, model endpoint, and OTEL config
3. Generate Pod YAML, ConfigMaps, and Secrets from templates
4. Install `.kube` Quadlet files to `~/.config/containers/systemd/`
5. Pull container images (rootless)
6. Enable lingering (`loginctl enable-linger`) so services survive logout
7. Register systemd user units (without starting them)

## Start / Stop

```bash
# Start the OTEL collector (if enabled — stays running)
systemctl --user start otel-collector

# Start the agent
systemctl --user start openclaw-agent

# Stop the agent (collector keeps running)
systemctl --user stop openclaw-agent

# Watch logs
journalctl --user -u openclaw-agent -f
journalctl --user -u otel-collector -f
```

The agent is configured with `Restart=no` — it stays stopped until explicitly started. This is intentional: in the [fleet model](../docs/FLEET.md), the central OpenShift supervisor controls agent lifecycle via SSH.

## What Gets Installed

```
~/.config/containers/systemd/
├── openclaw-agent.kube                # Quadlet unit (references Pod YAML + ConfigMaps)
├── openclaw-agent-pod.yaml            # Pod spec (init container + agent container)
├── openclaw-agent-config.yaml         # ConfigMap: openclaw.json
├── openclaw-agent-secret.yaml         # Secret: gateway token, API keys
├── openclaw-agent-agents.yaml         # ConfigMap: AGENTS.md, agent.json
├── otel-collector.kube                # Quadlet unit (if OTEL enabled)
├── otel-collector-pod.yaml            # Pod spec for collector (if OTEL enabled)
└── otel-collector-config.yaml         # ConfigMap: collector config (if OTEL enabled)
```

### Template Sources

```
edge/quadlet/
├── openclaw-agent.kube                    # Static .kube Quadlet (copied as-is)
├── openclaw-agent-pod.yaml.envsubst       # Pod YAML template
├── openclaw-agent-config.yaml.envsubst    # ConfigMap template (openclaw.json)
├── openclaw-agent-secret.yaml.envsubst    # Secret template
├── openclaw-agent-agents.yaml.envsubst    # ConfigMap template (AGENTS.md, agent.json)
├── otel-collector.kube                    # Static .kube Quadlet (copied as-is)
├── otel-collector-pod.yaml.envsubst       # Pod YAML template
└── otel-collector-config.yaml.envsubst    # ConfigMap template (collector config)

edge/config/
├── openclaw.json.envsubst                 # Gateway config template
├── otel-collector-config.yaml.envsubst    # Collector config template
└── AGENTS.md.envsubst                     # Edge agent system prompt template
```

## Components

### OpenClaw Agent

Runs the same container image as OpenShift (`quay.io/aicatalyst/openclaw:latest`). Uses `hostNetwork: true` so it can reach local services. The agent has an allowlisted set of system commands it can execute:

`df`, `free`, `ps`, `uptime`, `uname`, `hostname`, `cat`, `grep`, `ls`, `wc`, `date`, `findmnt`, `lsblk`

This is a minimal read-only default. An init container copies `openclaw.json`, `AGENTS.md`, and `agent.json` from ConfigMaps into the persistent volume on each startup, matching the OpenShift deployment pattern.

### Agent Files

The edge agent gets a system prompt (`AGENTS.md`) and metadata (`agent.json`) delivered via ConfigMap, the same way the OpenShift deployment delivers agent configurations. The prompt defines the agent's role as a Linux system observer with the available tool allowlist.

### Local LLM (RHEL Lightspeed)

The default model endpoint is `http://127.0.0.1:8888/v1`, served by RHEL Lightspeed's RamaLama container running Phi-4-mini (Q4_K_M, ~2.4GB) via llama.cpp. No GPU required. See the [Lightspeed docs](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/interacting_with_the_command-line_assistant_powered_by_rhel_lightspeed/containerized-command-line-assistant-for-disconnected-environments) for installation.

### OTEL Collector (Optional)

When enabled, a local OpenTelemetry collector receives traces from the agent on `127.0.0.1:4318` and forwards them to the central MLflow instance on OpenShift. Uses the OTel collector contrib image (`ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib`).

Traces are enriched with `host.name` and `deployment.environment: edge` attributes for filtering in MLflow.

### Secrets

API keys and tokens are stored in a Kubernetes Secret YAML (base64-encoded), referenced by the Pod YAML via `secretKeyRef`. This replaces the previous approach of `sed`-injecting secrets into `.container` files.

## Re-running Setup

The script saves configuration to `.env.edge`. On subsequent runs, it detects existing config and skips prompts. Delete `.env.edge` to start fresh.

## Uninstall

```bash
./scripts/setup-edge.sh --uninstall
```

This stops services, removes all Quadlet and YAML files, and reloads systemd. Volume data is preserved — to remove it:

```bash
podman volume rm openclaw-data
```

## Architecture

See [FLEET.md](../docs/FLEET.md) for the full fleet management architecture — how the central OpenShift gateway supervises edge agents, coordinates across machines, and tracks everything in MLflow.
