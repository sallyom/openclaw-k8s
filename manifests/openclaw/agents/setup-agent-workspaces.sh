#!/bin/bash
# Setup agents in OpenClaw workspace
# Runs commands inside the existing pod via oc exec

set -e

echo "🔧 Setting up agents in OpenClaw..."
echo ""

# Get running pod (exclude job pods)
echo "1. Finding OpenClaw deployment pod..."
POD=$(oc get pods -n openclaw -l app=openclaw --field-selector=status.phase=Running -o json | \
  jq -r '.items[] | select(.metadata.ownerReferences[0].kind=="ReplicaSet") | .metadata.name' | head -1)
if [ -z "$POD" ]; then
  echo "❌ ERROR: No OpenClaw deployment pod found"
  exit 1
fi
echo "   Found: $POD"
echo ""

# Setup agent directories
echo "2. Setting up agent workspaces..."
oc exec -n openclaw $POD -c gateway -- sh -c '
  set -e
  echo "  Creating agent workspace directories..."
  mkdir -p ~/.openclaw/workspace-philbot
  mkdir -p ~/.openclaw/workspace-audit-reporter
  mkdir -p ~/.openclaw/workspace-resource-optimizer
  mkdir -p ~/.openclaw/workspace-mlops-monitor

  echo "  Setting permissions..."
  chmod -R 775 ~/.openclaw/workspace-*

  echo "  ✅ Agent workspace directories created"
'
echo ""

# Create .env files with API keys from secrets
echo "3. Creating .env files with API keys..."

# Get API keys from secrets
PHILBOT_KEY=$(oc get secret philbot-moltbook-key -n openclaw -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d || echo "")
AUDIT_REPORTER_KEY=$(oc get secret audit-reporter-moltbook-key -n openclaw -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d || echo "")
RESOURCE_OPTIMIZER_KEY=$(oc get secret resource-optimizer-moltbook-key -n openclaw -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d || echo "")
MLOPS_MONITOR_KEY=$(oc get secret mlops-monitor-moltbook-key -n openclaw -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d || echo "")

# Create philbot .env
if [ -n "$PHILBOT_KEY" ]; then
  cat <<EOF | oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > ~/.openclaw/workspace-philbot/.env'
MOLTBOOK_API_URL=http://moltbook-api.moltbook.svc.cluster.local:3000
MOLTBOOK_API_KEY=$PHILBOT_KEY
AGENT_NAME=philbot
EOF
  echo "   ✅ philbot .env created"
else
  echo "   ⚠️  philbot API key not found - skipping"
fi

# Create audit-reporter .env
if [ -n "$AUDIT_REPORTER_KEY" ]; then
  cat <<EOF | oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > ~/.openclaw/workspace-audit-reporter/.env'
MOLTBOOK_API_URL=http://moltbook-api.moltbook.svc.cluster.local:3000
MOLTBOOK_API_KEY=$AUDIT_REPORTER_KEY
AGENT_NAME=audit_reporter
EOF
  echo "   ✅ audit_reporter .env created"
else
  echo "   ⚠️  audit_reporter API key not found - skipping"
fi

# Create resource-optimizer .env
if [ -n "$RESOURCE_OPTIMIZER_KEY" ]; then
  cat <<EOF | oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > ~/.openclaw/workspace-resource-optimizer/.env'
MOLTBOOK_API_URL=http://moltbook-api.moltbook.svc.cluster.local:3000
MOLTBOOK_API_KEY=$RESOURCE_OPTIMIZER_KEY
AGENT_NAME=resource_optimizer
EOF
  echo "   ✅ resource_optimizer .env created"
else
  echo "   ⚠️  resource_optimizer API key not found - skipping"
fi

# Create mlops-monitor .env
if [ -n "$MLOPS_MONITOR_KEY" ]; then
  cat <<EOF | oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > ~/.openclaw/workspace-mlops-monitor/.env'
MOLTBOOK_API_URL=http://moltbook-api.moltbook.svc.cluster.local:3000
MOLTBOOK_API_KEY=$MLOPS_MONITOR_KEY
AGENT_NAME=mlops_monitor
EOF
  echo "   ✅ mlops_monitor .env created"
else
  echo "   ⚠️  mlops_monitor API key not found - skipping"
fi

echo ""

# Copy agent ConfigMaps into workspace
echo "4. Copying agent AGENTS.md and agent.json files..."

# philbot
oc get configmap philbot-agent -n openclaw -o jsonpath='{.data.AGENTS\.md}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > ~/.openclaw/workspace-philbot/AGENTS.md' && \
  echo "   ✅ philbot AGENTS.md copied" || echo "   ⚠️  philbot ConfigMap not found"

oc get configmap philbot-agent -n openclaw -o jsonpath='{.data.agent\.json}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > ~/.openclaw/workspace-philbot/agent.json' && \
  echo "   ✅ philbot agent.json copied" || echo "   ⚠️  philbot agent.json not found"

# audit-reporter
oc get configmap audit-reporter-agent -n openclaw -o jsonpath='{.data.AGENTS\.md}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > ~/.openclaw/workspace-audit-reporter/AGENTS.md' && \
  echo "   ✅ audit_reporter AGENTS.md copied" || echo "   ⚠️  audit-reporter ConfigMap not found"

oc get configmap audit-reporter-agent -n openclaw -o jsonpath='{.data.agent\.json}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > ~/.openclaw/workspace-audit-reporter/agent.json' && \
  echo "   ✅ audit_reporter agent.json copied" || echo "   ⚠️  audit-reporter agent.json not found"

# resource-optimizer
oc get configmap resource-optimizer-agent -n openclaw -o jsonpath='{.data.AGENTS\.md}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > ~/.openclaw/workspace-resource-optimizer/AGENTS.md' && \
  echo "   ✅ resource_optimizer AGENTS.md copied" || echo "   ⚠️  resource-optimizer ConfigMap not found"

oc get configmap resource-optimizer-agent -n openclaw -o jsonpath='{.data.agent\.json}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > ~/.openclaw/workspace-resource-optimizer/agent.json' && \
  echo "   ✅ resource_optimizer agent.json copied" || echo "   ⚠️  resource-optimizer agent.json not found"

# mlops-monitor
oc get configmap mlops-monitor-agent -n openclaw -o jsonpath='{.data.AGENTS\.md}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > ~/.openclaw/workspace-mlops-monitor/AGENTS.md' && \
  echo "   ✅ mlops_monitor AGENTS.md copied" || echo "   ⚠️  mlops-monitor ConfigMap not found"

oc get configmap mlops-monitor-agent -n openclaw -o jsonpath='{.data.agent\.json}' 2>/dev/null | \
  oc exec -i -n openclaw $POD -c gateway -- sh -c 'cat > ~/.openclaw/workspace-mlops-monitor/agent.json' && \
  echo "   ✅ mlops_monitor agent.json copied" || echo "   ⚠️  mlops-monitor agent.json not found"

echo ""

# Verify
echo "5. Verifying agent workspaces..."
oc exec -n openclaw $POD -c gateway -- sh -c 'ls -la ~/.openclaw/ | grep workspace'
echo ""

echo "✅ Agent setup complete!"
echo ""
echo "Next steps:"
echo "  1. Apply agents-config-patch.yaml to add agents to OpenClaw config"
echo "  2. Restart OpenClaw: oc rollout restart deployment/openclaw -n openclaw"
echo "  3. Setup cron jobs after OpenClaw restarts"
