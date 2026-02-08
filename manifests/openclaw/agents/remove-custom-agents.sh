#!/bin/bash
# Remove custom agents from OpenClaw
# Keeps: Shadowman, secrets, Moltbook registrations
# Removes: Agent configs, workspace files, cron jobs

set -e

echo "🧹 Removing custom agents from OpenClaw..."
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

# Remove cron jobs
echo "2. Removing cron jobs..."
oc exec -n openclaw $POD -c gateway -- bash -c '
cd /home/node
echo "   - Deleting philbot-daily-post..."
node /app/dist/index.js cron delete philbot-daily-post 2>/dev/null || echo "     (not found)"
echo "   - Deleting audit-reporter-scan..."
node /app/dist/index.js cron delete audit-reporter-scan 2>/dev/null || echo "     (not found)"
echo "   - Deleting resource-optimizer-scan..."
node /app/dist/index.js cron delete resource-optimizer-scan 2>/dev/null || echo "     (not found)"
echo "   - Deleting mlops-monitor-check..."
node /app/dist/index.js cron delete mlops-monitor-check 2>/dev/null || echo "     (not found)"
'
echo "   ✅ Cron jobs removed"
echo ""

# Remove agent workspace directories
echo "3. Removing agent workspace directories..."
oc exec -n openclaw $POD -c gateway -- sh -c '
  echo "   - Removing workspace-philbot..."
  rm -rf ~/.openclaw/workspace-philbot 2>/dev/null || echo "     (not found)"
  echo "   - Removing workspace-audit-reporter..."
  rm -rf ~/.openclaw/workspace-audit-reporter 2>/dev/null || echo "     (not found)"
  echo "   - Removing workspace-resource-optimizer..."
  rm -rf ~/.openclaw/workspace-resource-optimizer 2>/dev/null || echo "     (not found)"
  echo "   - Removing workspace-mlops-monitor..."
  rm -rf ~/.openclaw/workspace-mlops-monitor 2>/dev/null || echo "     (not found)"
'
echo "   ✅ Agent workspaces removed"
echo ""

# Apply base config (shadowman only)
echo "4. Applying base config (shadowman only)..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
oc apply -f "$SCRIPT_DIR/../base/openclaw-config-configmap.yaml"
echo "   ✅ Config updated to shadowman only"
echo ""

# Restart deployment
echo "5. Restarting OpenClaw deployment..."
oc rollout restart deployment/openclaw -n openclaw
echo "   ✅ Deployment restarting"
echo ""

echo "✅ Custom agents removed successfully!"
echo ""
echo "Remaining:"
echo "  - ✅ Shadowman agent (active)"
echo "  - ✅ Agent secrets (kept for future use)"
echo "  - ✅ Moltbook registrations (agents still registered)"
echo ""
echo "Removed:"
echo "  - ❌ philbot, audit_reporter, resource_optimizer, mlops_monitor (from OpenClaw UI)"
echo "  - ❌ Agent workspace directories"
echo "  - ❌ Cron jobs"
echo ""
echo "To re-add agents, run: ./setup-agent-workspaces.sh && oc apply -f agents-config-patch.yaml"
