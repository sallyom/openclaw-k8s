#!/bin/bash
# Quick script to update resource-optimizer agent after changes

set -e

echo "🔄 Updating resource-optimizer agent..."
echo ""

# Find pod
POD=$(oc get pods -n openclaw -l app=openclaw --field-selector=status.phase=Running -o json | \
  jq -r '.items[] | select(.metadata.ownerReferences[0].kind=="ReplicaSet") | .metadata.name' | head -1)

if [ -z "$POD" ]; then
  echo "❌ ERROR: No OpenClaw pod found"
  exit 1
fi

echo "1. Applying updated ConfigMap..."
oc apply -f resource-optimizer-agent.yaml

echo "2. Updating AGENTS.md in pod..."
oc get configmap resource-optimizer-agent -n openclaw -o jsonpath='{.data.AGENTS\.md}' | \
  oc exec -i -n openclaw $POD -c gateway -- bash -c 'cat > /home/node/.openclaw/workspace-resource-optimizer/AGENTS.md'

echo "3. Removing resource-optimizer job from jobs.json..."
oc exec -n openclaw $POD -c gateway -- bash -c '
  # Remove the specific job from jobs.json
  if [ -f ~/.openclaw/cron/jobs.json ]; then
    cat ~/.openclaw/cron/jobs.json | jq "del(.[] | select(.name == \"resource-optimizer-scan\"))" > ~/.openclaw/cron/jobs.json.tmp
    mv ~/.openclaw/cron/jobs.json.tmp ~/.openclaw/cron/jobs.json
    echo "   Removed old job"
  else
    echo "   No jobs.json file found"
  fi
'

echo "4. Creating updated cron job..."
oc exec -n openclaw $POD -c gateway -- bash -c 'cd /home/node && node /app/dist/index.js cron add \
  --name "resource-optimizer-scan" \
  --description "Daily cost optimization analysis" \
  --agent "resource-optimizer" \
  --session "isolated" \
  --cron "0 8 * * *" \
  --tz "UTC" \
  --message "1) source ~/.openclaw/workspace-resource-optimizer/.env 2) Query K8s API (see AGENTS.md). 3) Save report to ~/reports/DATE-cost-report.md 4) Create announcement. 5) EXECUTE: curl -s -X POST \\\$MOLTBOOK_API_URL/api/v1/posts -H \\\"Authorization: Bearer \\\$MOLTBOOK_API_KEY\\\" -H \\\"Content-Type: application/json\\\" -d '{\\\"submolt\\\":\\\"cost_resource_analysis\\\",\\\"title\\\":\\\"YOUR_TITLE\\\",\\\"content\\\":\\\"YOUR_CONTENT\\\"}' DO NOT just describe - RUN the curl. Never echo keys." \
  --thinking "low"'

echo ""
echo "✅ Resource-optimizer updated!"
echo ""
echo "Test it:"
echo "  oc exec -n openclaw $POD -c gateway -- bash -c 'cd /home/node && node /app/dist/index.js cron trigger resource-optimizer-scan'"
echo ""
