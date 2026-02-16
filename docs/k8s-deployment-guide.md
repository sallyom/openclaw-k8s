# OpenClaw on K8s/OpenShift — Deployment Guide

Deep analysis of running OpenClaw in Kubernetes and OpenShift, covering connectivity, configuration, channels, tools, isolation, and operational concerns.

---

## 1. Connecting to the Gateway from a Local Laptop

### How It Works
- The gateway listens on port 18789 (WebSocket + HTTP multiplexed)
- The deployment uses `--bind lan` (0.0.0.0), which requires token auth (configured via `OPENCLAW_GATEWAY_TOKEN`)
- Connect via `kubectl port-forward` or OpenShift Route

### Device Pairing
- Even with a valid `--token`, the CLI requires **device pairing** (Ed25519 key exchange)
- Local connections (127.0.0.1) auto-approve pairing silently
- Remote connections require explicit operator approval via the Control UI
- `--token` authenticates the connection but does **not** bypass device pairing — hardcoded at `src/gateway/server/ws-connection/message-handler.ts:673`

### Recommended: Port-Forward
```bash
kubectl port-forward svc/openclaw 18789:18789 -n $OPENCLAW_NAMESPACE
```
This makes the connection appear as localhost, so device pairing auto-approves.

### Remote Config on Laptop
Configure `~/.openclaw/openclaw.json` on your local machine:
```json
{
  "gateway": {
    "mode": "remote",
    "remote": {
      "url": "ws://localhost:18789",
      "token": "your-gateway-token"
    }
  }
}
```
Then port-forward and run `openclaw` normally.

### Control UI Bypass (UI only, not CLI)
The Control UI has special options that only apply to the browser-based dashboard:
- `gateway.controlUi.dangerouslyDisableDeviceAuth: true`
- `gateway.controlUi.allowInsecureAuth: true`
These do **not** affect CLI connections.

### Bridge Port (18790)
Port 18790 is declared in the deployment but **not used by the gateway codebase**. It may be reserved for future use.

---

## 2. UI and Filesystem-Backed Configuration

### Control UI
- Static SPA served by the gateway HTTP server at `/ui/*`
- All configuration changes go through WebSocket RPC methods — the UI never touches the filesystem directly
- UI settings (theme, split ratio, etc.) are stored in browser localStorage only

### What Can Be Managed via UI

| What | RPC Methods | Filesystem Location |
|------|-------------|-------------------|
| Main config | `config.get/set/patch` | `~/.openclaw/openclaw.json` |
| Cron jobs | `cron.list/add/update/remove` | `~/.openclaw/cron/jobs.json` |
| Agent files | `agents.files.list/get/set` | `~/.openclaw/workspace/` |
| Agent config | `agents.list/create/update/delete` | In `openclaw.json` |
| Exec approvals | `exec.approvals.get/set` | `~/.openclaw/exec-approvals.json` |
| Sessions | `sessions.*` | `~/.openclaw/sessions/` |

### Hot-Reload
- Gateway watches `openclaw.json` with chokidar
- Changes to agents/tools/plugins trigger a graceful restart (SIGUSR1)
- Changes to cron/hooks/heartbeat are hot-reloaded without restart
- Config mode: `gateway.reload.mode` — `off`, `hot`, `restart`, `hybrid` (default)

### PVC Requirements
All of `~/.openclaw/` must be on a PersistentVolumeClaim:
- `openclaw.json` — main config
- `cron/jobs.json` — cron jobs
- `workspace/` — agent files
- `sessions/` — chat transcripts (JSONL, sync writes)
- `auth/`, `identity/` — credentials, device pairing
- Single-pod only — no file locking, sync writes would corrupt with multiple pods

---

## 3. Telegram Channel Setup

### Polling Mode (Recommended for K8s)
- Default when no `webhookUrl` is set
- Bot calls Telegram's `getUpdates` API continuously
- **No public URL or ingress needed**
- Single replica only (polling maintains update offset)

### Setup
1. Create a bot via BotFather, get the token
2. Add to the gateway as a K8s secret:
   ```yaml
   - name: TELEGRAM_BOT_TOKEN
     valueFrom:
       secretKeyRef:
         name: telegram-secrets
         key: bot-token
   ```
3. Configure in `openclaw.json`:
   ```json
   {
     "channels": {
       "telegram": {
         "dmPolicy": "allowlist",
         "allowFrom": ["your-telegram-user-id"],
         "groups": {}
       }
     }
   }
   ```

### Webhook Mode (Optional)
Requires public HTTPS URL (via Ingress/Route + TLS cert). Lower latency but more infrastructure.
Set `webhookUrl` in config. Webhook port defaults to 8787, path defaults to `/telegram-webhook`.

### Agent Routing
Messages route to agents via bindings config:
```json
{
  "bindings": [
    { "match": { "channel": "telegram", "peer": { "kind": "group", "id": "-100123..." } }, "agentId": "support" },
    { "match": { "channel": "telegram" }, "agentId": "main" }
  ]
}
```

### Security
- DM policies: `pairing` (default, requires approval), `allowlist`, `open`, `disabled`
- Group policies: `open`, `allowlist`, `disabled`
- Privacy mode: Bot only sees messages mentioning it unless disabled via BotFather or made admin

### Other Available Channels
Discord, Slack, Signal, LINE, Google Chat, Matrix, MS Teams, Mattermost, IRC, Twitch, Nostr, and more. All follow the same plugin architecture.

---

## 4. Tools and Web Search

### Container-Ready Tools
- `read`, `write`, `edit` — file operations (workspace on PVC)
- `exec`, `process` — shell commands (run in container)
- `web_search` — needs API key (Brave, Perplexity, or Grok)
- `web_fetch` — fetches and parses web pages (optional Firecrawl)
- `sessions_*` — agent session management
- `memory_search/get` — vector search over memories
- `cron` — scheduling (filesystem-based)
- `canvas` — visual artifacts
- `message` — send to channels

### Web Search Setup
```json
{
  "tools": {
    "web": {
      "search": {
        "provider": "brave",
        "apiKey": "${BRAVE_API_KEY}"
      },
      "fetch": { "enabled": true }
    }
  }
}
```
Env vars: `BRAVE_API_KEY`, `PERPLEXITY_API_KEY`, or `XAI_API_KEY` (Grok)

### Tools That Won't Work in Containers

| Tool | Why |
|------|-----|
| `browser` | Requires node host with Chromium |
| `nodes` | Requires connected device nodes (camera, screen, location) |
| `whatsapp_login` | Owner-only, needs browser |
| `tts` | Requires ElevenLabs API + audio output |

### Recommended K8s Tool Config
```json
{
  "tools": {
    "profile": "coding",
    "deny": ["browser", "nodes", "whatsapp_login", "tts"],
    "exec": {
      "security": "allowlist",
      "safeBins": ["curl", "jq"],
      "ask": "off",
      "timeoutSec": 30
    }
  },
  "gateway": {
    "nodes": {
      "browser": { "mode": "off" }
    }
  }
}
```

### Tool Profiles
- `minimal` — only `session_status`
- `coding` — file ops, runtime, sessions, memory, image
- `messaging` — messaging, sessions list/history/send
- `full` — all tools

### Tool Policy Hierarchy
1. Global level (`tools.*`)
2. Per-agent level (`agents.{id}.tools.*`)
3. Per-provider/model level (`tools.byProvider.*`)
4. Per-group level (channel-specific)
5. Sandbox level (subagent restrictions)

---

## 5. MCP Server Support

**MCP is not currently functional in OpenClaw.**

The codebase has ACP (Agent Client Protocol) integration, not MCP. The ACP translator explicitly ignores MCP servers:
```typescript
if (params.mcpServers.length > 0) {
  this.log("ignoring ${params.mcpServers.length} MCP servers");
}
```

MCP capabilities are declared as `{ http: false, sse: false }`.

Use OpenClaw's native tool system instead.

---

## 6. Agent Isolation and Workload Identity

### Current Isolation Model

**Session-Based Isolation:**
- Each agent gets its own workspace: `~/.openclaw/agents/{agentId}/agent/`
- Cron jobs with `sessionTarget: "isolated"` get fresh sessions per run
- Session keys: `agent:{agentId}:{mainKey}:{channel}:{peer}`

**Docker Sandbox (Available but not K8s-native):**
- Per-session or per-agent Docker containers
- Network isolation (`network: "none"`)
- Read-only root, dropped capabilities, memory/CPU/PID limits
- Workspace access control (none/ro/rw)
- Config: `agents.{id}.sandbox.*`

**Agent-to-Agent Policy:**
```json
{
  "tools": {
    "agentToAgent": {
      "enabled": true,
      "allow": [["agent-a", "agent-b"]]
    }
  }
}
```

**Per-Agent Tool Policies:**
Different allow/deny lists per agent via `agents.{id}.tools.*`

**Concurrency Limits:**
Default 4 concurrent agents, 8 subagents. Configurable via `agents.defaults.maxConcurrent`.

### What Doesn't Exist
- No K8s ServiceAccount per agent (but can be done manually — see resource-optimizer RBAC pattern)
- No workload identity integration
- No multi-pod agent isolation (all agents share one gateway process)
- No namespace-level isolation between agents

### ServiceAccount + RBAC Pattern (Recommended)
Each agent gets its own ServiceAccount with minimal RBAC:
```yaml
# ServiceAccount in openclaw namespace
# Role with read-only in target namespace
# RoleBinding granting access
# SA token injected into agent's workspace .env
```
See `manifests/openclaw/agents/resource-optimizer/resource-optimizer-rbac.yaml.envsubst` for a working example.

### Google A2A Protocol
OpenClaw has its own A2A implementation via `sessions_send` tool with ping-pong exchange and allow lists. It's not Google's A2A spec, but serves a similar purpose within the gateway.

---

## 7. Per-Agent Model Configuration

### Overview
Each agent can use a different model provider and API key.

### Config Example
```json
{
  "models": {
    "providers": {
      "nerc": {
        "baseUrl": "http://vllm-endpoint/v1",
        "api": "openai-completions",
        "apiKey": "fakekey",
        "models": [{
          "id": "openai/gpt-oss-20b",
          "name": "GPT OSS 20B",
          "reasoning": false,
          "input": ["text"],
          "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
          "contextWindow": 32768,
          "maxTokens": 8192
        }]
      },
      "anthropic": {
        "baseUrl": "https://api.anthropic.com",
        "api": "anthropic-messages",
        "models": []
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {"primary": "nerc/openai/gpt-oss-20b"}
    },
    "list": [
      {
        "id": "philbot",
        "model": {"primary": "anthropic/claude-sonnet-4-5"}
      },
      {
        "id": "resource_optimizer"
      }
    ]
  }
}
```

### Model Resolution Order
1. Agent-specific `model` field
2. `agents.defaults.model.primary`
3. Built-in default (`anthropic/claude-opus-4-6`)

### Cron Job Model Override
Cron payloads support `"model": "provider/model"` to override per-job.

### Different API Keys Per Agent
Two approaches:
1. **Separate provider entries** with different `apiKey` values
2. **Auth profiles** (`~/.openclaw/auth-profiles.json`) with per-agent `order` overrides

---

## 8. K8s Deployment Specifics

### Filesystem
- Gateway assumes writable `~/.openclaw/` — PVC is mandatory
- Session transcripts use synchronous `fs.writeFileSync()` — **single-pod only**
- No multi-pod sharing (no file locking, would corrupt state)
- Config writes are atomic (temp file -> rename)
- `/tmp` needed for gateway lock file (use `emptyDir`)

### Container
- Base image: `node:22-bookworm`
- Runs as non-root (`node`, uid 1000)
- OpenShift arbitrary UID compatible
- No privileged escalation

### Health Probes
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 18789
  initialDelaySeconds: 60
readinessProbe:
  httpGet:
    path: /health
    port: 18789
  initialDelaySeconds: 30
```

### Graceful Shutdown
- SIGTERM handler with 35s total grace period
- Drains active agent tasks, closes channels, broadcasts shutdown
- Set `terminationGracePeriodSeconds >= 40`

### Networking
- Outbound: Anthropic API, channel APIs, web search APIs
- Bonjour/mDNS runs but is harmless in K8s
- No K8s service DNS integration
- System DNS resolver used for all outbound

### Environment Variables
```
OPENCLAW_STATE_DIR    — Override ~/.openclaw state directory
OPENCLAW_HOME         — Override home directory
OPENCLAW_CONFIG_PATH  — Override config file path
OPENCLAW_GATEWAY_TOKEN — Gateway auth token
ANTHROPIC_API_KEY     — For agents using Anthropic models
TELEGRAM_BOT_TOKEN    — For Telegram channel
BRAVE_API_KEY         — For web search
```

### What Needs to Persist (PVC)
- `openclaw.json` — main config
- `cron/jobs.json` — cron jobs
- `workspace*/` — agent workspaces and files
- `sessions/` — chat transcripts
- `credentials/oauth.json` — channel auth tokens
- `identity/device-auth.json` — device pairing
- `skills/` — installed skills (e.g., moltbook)

### SIGUSR1 Restart
The gateway uses SIGUSR1 for in-process restart (hot-reload). This works within K8s pods but the restart sentinel file must be on the PVC to prevent infinite restart loops.

---

## 9. Cron Jobs

### Storage
Cron jobs are stored in `~/.openclaw/cron/jobs.json` on the PVC.

### CLI vs Filesystem
The CLI `cron add/delete` commands require WebSocket + device pairing, which doesn't work inside the pod (pairing required even with `--token`). Instead, write `jobs.json` directly to the PVC via `oc exec`.

### Gateway Pickup
The gateway loads `jobs.json` at startup. After writing, restart the deployment to pick up changes.

### Cron Job Schema
```json
{
  "version": 1,
  "jobs": [{
    "id": "unique-id",
    "agentId": "agent_name",
    "name": "display-name",
    "description": "what it does",
    "enabled": true,
    "schedule": {"kind": "cron", "expr": "0 9 * * *", "tz": "UTC"},
    "sessionTarget": "isolated",
    "wakeMode": "now",
    "payload": {
      "kind": "agentTurn",
      "message": "the prompt",
      "model": "optional/model-override",
      "thinking": "low"
    },
    "state": {}
  }]
}
```

---

## 10. Scripts Overview

| Script | Purpose |
|--------|---------|
| `scripts/setup.sh` | First-time deployment (secrets, namespaces, Moltbook, OpenClaw) |
| `scripts/setup-agents.sh` | Agent deployment (registration, RBAC, skills, cron jobs) |
| `scripts/update-jobs.sh` | Update cron jobs and resource-report script without full re-deploy |
| `scripts/teardown.sh` | Full cleanup (delete resources, namespaces, OAuthClients) |
| `manifests/openclaw/agents/remove-custom-agents.sh` | Remove agents only (keep gateway) |
| `manifests/openclaw/agents/resource-optimizer/setup-resource-optimizer-rbac.sh` | Manual RBAC setup for resource-optimizer |
| `manifests/openclaw/skills/install-moltbook-skill.sh` | Manual moltbook skill install |

All scripts support `--k8s` flag for vanilla Kubernetes (default is OpenShift/`oc`).
