#!/bin/bash
# Create required submolts for OpenClaw agents
# Runs inside OpenClaw pod via oc exec

set -e

echo "🎯 Creating submolts for OpenClaw agents..."
echo ""

# Find OpenClaw pod
echo "1. Finding OpenClaw deployment pod..."
POD=$(oc get pods -n openclaw -l app=openclaw --field-selector=status.phase=Running -o json | \
  jq -r '.items[] | select(.metadata.ownerReferences[0].kind=="ReplicaSet") | .metadata.name' | head -1)

if [ -z "$POD" ]; then
  echo "❌ ERROR: No OpenClaw deployment pod found"
  exit 1
fi

echo "   Found: $POD"
echo ""

# Get API key from secret
echo "2. Getting API key from audit-reporter secret..."
MOLTBOOK_API_KEY=$(oc get secret audit-reporter-moltbook-key -n openclaw -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d)

if [ -z "$MOLTBOOK_API_KEY" ]; then
  echo "❌ ERROR: Could not get API key from audit-reporter-moltbook-key secret"
  echo "   Make sure audit-reporter is registered first."
  exit 1
fi

echo "   ✅ Got API key: ${MOLTBOOK_API_KEY:0:10}..."
echo ""

echo "3. Creating submolts (from inside pod)..."
echo ""

# Function to create submolt (runs inside pod)
create_submolt() {
  local name=$1
  local display_name=$2
  local description=$3

  echo "   Creating: $name..."

  RESULT=$(oc exec -n openclaw $POD -c gateway -- bash -c "
    curl -s -X POST \
      'http://moltbook-api.moltbook.svc.cluster.local:3000/api/v1/submolts' \
      -H 'Authorization: Bearer $MOLTBOOK_API_KEY' \
      -H 'Content-Type: application/json' \
      -d '{\"name\":\"$name\",\"display_name\":\"$display_name\",\"description\":\"$description\"}'
  " 2>&1)

  if echo "$RESULT" | grep -q '"submolt":\s*{'; then
    echo "     ✅ Created: $name"
  elif echo "$RESULT" | grep -qi "already exists\|conflict"; then
    echo "     ⚠️  Already exists: $name"
  else
    echo "     ❌ Failed: $name"
    echo "        Response: $RESULT"
  fi
}

# Create submolts for each agent
create_submolt "compliance" "Compliance" "Governance and audit reports from AI agents"
create_submolt "cost_resource_analysis" "Cost & Resources" "Cloud cost optimization and resource efficiency recommendations"
create_submolt "mlops" "MLOps" "Machine learning operations monitoring and experiment tracking"
create_submolt "philosophy" "Philosophy" "Philosophical discussions and thought-provoking questions"

echo ""
echo "✅ Submolt creation complete!"
echo ""
echo "Verify submolts:"
echo "  oc exec -n openclaw $POD -c gateway -- curl -s http://moltbook-api.moltbook.svc.cluster.local:3000/api/v1/submolts | jq '.submolts[] | {name, display_name}'"
echo ""
