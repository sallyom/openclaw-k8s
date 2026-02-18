---
name: nps
description: Query the National Park Service agent for park information
metadata: { "openclaw": { "emoji": "\ud83c\udfde\ufe0f", "requires": { "bins": ["curl", "jq"] } } }
---

# NPS Skill -- National Park Service Queries

You can query the **NPS Agent** for information about U.S. national parks. The NPS Agent is an AI assistant running in the `nps-agent` namespace that has access to the National Park Service API. It can answer questions about parks, alerts, campgrounds, events, and visitor centers.

## How It Works

The NPS Agent runs as a standalone service with its own model and MCP tools. You send questions via HTTP and receive natural language answers. Authentication is handled transparently by the AuthBridge -- you just make the call.

## Query the NPS Agent

```bash
RESPONSE=$(curl -s --max-time 300 -X POST \
  http://nps-agent.nps-agent.svc.cluster.local:8080/invocations \
  -H "Content-Type: application/json" \
  -d '{"input": "Your question about national parks here"}')

echo "$RESPONSE" | jq -r '.output[-1].content[-1].text // .output'
```

**Important:** The NPS Agent may take up to 60 seconds on the first request (cold start). Use `--max-time 300` to allow for this.

## Input Format

The `/invocations` endpoint accepts JSON with an `input` field:

```json
{"input": "What national parks are in California?"}
```

Or with conversation history:

```json
{"input": [{"role": "user", "content": "What campgrounds are at Yosemite?"}]}
```

## Output Format

The response follows the MLflow ResponsesAgent format:

```json
{
  "output": [
    {
      "role": "assistant",
      "content": [
        {
          "type": "text",
          "text": "California has nine national parks..."
        }
      ]
    }
  ]
}
```

Extract the answer: `jq -r '.output[-1].content[-1].text'`

## What the NPS Agent Can Answer

The agent has 5 MCP tools connected to the NPS API:

| Tool | What It Does | Example Question |
|------|-------------|-----------------|
| `search_parks` | Find parks by state, code, or keyword | "What parks are in Utah?" |
| `get_park_alerts` | Current alerts and hazards | "Are there any alerts for Yellowstone?" |
| `get_park_campgrounds` | Campground info and amenities | "What campgrounds are at Grand Canyon?" |
| `get_park_events` | Upcoming events and activities | "What events are happening at Acadia?" |
| `get_visitor_centers` | Visitor center locations and hours | "Where are the visitor centers at Zion?" |

## Examples

### Find parks in a state

```bash
RESPONSE=$(curl -s --max-time 300 -X POST \
  http://nps-agent.nps-agent.svc.cluster.local:8080/invocations \
  -H "Content-Type: application/json" \
  -d '{"input": "What national parks are in Colorado?"}')
echo "$RESPONSE" | jq -r '.output[-1].content[-1].text'
```

### Check park alerts

```bash
RESPONSE=$(curl -s --max-time 300 -X POST \
  http://nps-agent.nps-agent.svc.cluster.local:8080/invocations \
  -H "Content-Type: application/json" \
  -d '{"input": "Are there any current alerts or closures at Yellowstone National Park?"}')
echo "$RESPONSE" | jq -r '.output[-1].content[-1].text'
```

### Get campground info

```bash
RESPONSE=$(curl -s --max-time 300 -X POST \
  http://nps-agent.nps-agent.svc.cluster.local:8080/invocations \
  -H "Content-Type: application/json" \
  -d '{"input": "What campgrounds are available at the Grand Canyon and what amenities do they have?"}')
echo "$RESPONSE" | jq -r '.output[-1].content[-1].text'
```

## Health Check

Verify the NPS Agent is running:

```bash
curl -s http://nps-agent.nps-agent.svc.cluster.local:8080/ping
```

Returns `200 OK` if healthy.

## Error Handling

| Error | Meaning | Action |
|-------|---------|--------|
| Connection refused | NPS Agent pod is down or not deployed | Check `oc get pods -n nps-agent` |
| Timeout (>300s) | Agent is processing a complex query or cold starting | Retry with a simpler question |
| Empty response | Agent couldn't find relevant data | Try a more specific query (include park name or state code) |
| 500 error | Agent encountered an internal error | Check NPS Agent logs: `oc logs deployment/nps-agent -n nps-agent` |
