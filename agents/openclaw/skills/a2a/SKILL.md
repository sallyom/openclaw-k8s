---
name: a2a
description: Communicate with agents on other OpenClaw instances via A2A protocol
metadata: { "openclaw": { "emoji": "🔗", "requires": { "bins": ["curl"] } } }
---

# A2A Skill — Cross-Instance Agent Communication

You have the ability to communicate with AI agents running on **other OpenClaw instances** using the Agent-to-Agent (A2A) protocol. Each OpenClaw instance runs in its own Kubernetes namespace with its own SPIFFE workload identity. Authentication is handled transparently — you just make the call.

## How It Works

Each OpenClaw instance runs an A2A bridge sidecar on port 8080. You send JSON-RPC messages to remote bridges, and they route your message to the appropriate agent. The Envoy AuthBridge transparently handles identity and authorization using SPIFFE and Keycloak — you never deal with tokens.

## 1. Discover Remote Agents

Before communicating, discover what agents are available on a remote instance:

```bash
curl -s http://openclaw.<namespace>.svc.cluster.local:8080/.well-known/agent.json | jq .
```

This returns an agent card with the instance's available skills (agents):

```json
{
  "name": "openclaw",
  "description": "OpenClaw AI Agent Gateway",
  "url": "http://openclaw.<namespace>.svc.cluster.local:8080",
  "skills": [
    {"id": "bob_shadowman", "name": "Shadowman", "description": "Chat with Shadowman"},
    {"id": "bob_resource_optimizer", "name": "Resource Optimizer", "description": "..."}
  ]
}
```

Each skill `id` corresponds to an agent you can talk to.

## 2. Send a Message to a Remote Agent

Use the A2A `message/send` JSON-RPC method:

```bash
curl -s -X POST http://openclaw.<namespace>.svc.cluster.local:8080/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": "1",
    "method": "message/send",
    "params": {
      "message": {
        "role": "user",
        "parts": [{"kind": "text", "text": "Your message here"}]
      }
    }
  }'
```

The response contains the remote agent's reply:

```json
{
  "jsonrpc": "2.0",
  "id": "1",
  "result": {
    "status": {
      "state": "COMPLETED",
      "message": {
        "role": "agent",
        "parts": [{"kind": "text", "text": "The agent's response..."}]
      }
    }
  }
}
```

Extract the response text from `.result.status.message.parts[0].text`.

## 3. Known OpenClaw Instances

Your peer table is maintained in your **MEMORY.md** file. Check it for current peers:

```bash
cat ~/.openclaw/workspace-*/MEMORY.md
```

Look for the "Known A2A Peers" section. You can update that table yourself
when you discover new peers or the user tells you about one. Use the format:

```
| owner_name | owner-namespace | http://openclaw.owner-namespace.svc.cluster.local:8080 |
```

To discover instances dynamically, look for services with the `kagenti.io/type: agent` label:

```bash
# This requires K8s API access — use only if you have the k8s tool
kubectl get svc -A -l kagenti.io/type=agent -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PORT:.spec.ports[0].port
```

## 4. Practical Examples

### Ask a remote agent a question

```bash
RESPONSE=$(curl -s -X POST http://openclaw.bob-openclaw.svc.cluster.local:8080/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": "1",
    "method": "message/send",
    "params": {
      "message": {
        "role": "user",
        "parts": [{"kind": "text", "text": "What is the current resource utilization in your namespace?"}]
      }
    }
  }')

echo "$RESPONSE" | jq -r '.result.status.message.parts[0].text // "No response"'
```

### Introduce yourself to a remote agent

```bash
curl -s -X POST http://openclaw.bob-openclaw.svc.cluster.local:8080/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": "1",
    "method": "message/send",
    "params": {
      "message": {
        "role": "user",
        "parts": [{"kind": "text", "text": "Hi, I am {{AGENT_NAME}} from {{OPENCLAW_NAMESPACE}}. I would like to collaborate with you."}]
      }
    }
  }'
```

### Relay information between instances

If you receive useful information from a remote agent, you can share it with agents on your own instance using `sessions_send`:

```
Use sessions_send to relay the response to your local colleague.
```

## 5. Security Model

You do NOT need to handle authentication. The AuthBridge (Envoy sidecar) transparently:

1. **Outbound**: Intercepts your curl request, obtains an OAuth token from Keycloak using your instance's SPIFFE identity, and injects it into the request
2. **Inbound**: The remote instance's Envoy validates the token before forwarding to the A2A bridge

Your SPIFFE identity: `spiffe://demo.example.com/ns/{{OPENCLAW_NAMESPACE}}/sa/openclaw-oauth-proxy`

This means:
- No API keys or tokens in your requests
- Identity is cryptographically verified (X.509 + JWT)
- Access can be audited and revoked per-instance
- Each OpenClaw instance has a unique identity

## 6. Error Handling

| Error | Meaning | Action |
|-------|---------|--------|
| `Connection refused` | Remote instance is down | Try again later or check if the namespace exists |
| `HTTP 401` | Auth token rejected | AuthBridge may not be configured on remote — report to admin |
| `HTTP 404` | Endpoint not found | Check the namespace name and that A2A bridge is deployed |
| `jsonrpc error -32602` | Invalid message format | Check your JSON structure matches the examples above |
| `jsonrpc error -32603` | Remote agent error | The remote agent failed to process — try rephrasing |

## 7. Session Persistence

A2A conversations maintain history per remote agent. When a remote agent sends you multiple messages, they all go to the same session, so you can reference prior exchanges. The remote agent's SPIFFE identity (or explicit user header) is used to pin the session automatically.

This means you can have multi-turn conversations with remote agents. They will remember what you discussed earlier in the same session.

## 8. Best Practices

- **Discover first**: Always fetch the agent card before sending messages to confirm the instance is up and see available agents
- **Be concise**: Remote agents may use small models — keep messages clear and specific
- **Identify yourself**: Include your agent name and namespace so the remote agent knows who's calling
- **Don't loop**: If a remote agent asks you to call another agent who calls you back, break the cycle
- **Relay selectively**: Only forward information that's relevant to the recipient
- **Respect boundaries**: Each instance is owned by a different person — be a good neighbor
