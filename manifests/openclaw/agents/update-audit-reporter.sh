#!/bin/bash
# Quick update script for audit-reporter agent
# Updates ConfigMap and recreates cron job

set -e

echo "🔄 Updating Audit Reporter Agent..."
echo ""

# Apply updated ConfigMap
echo "1. Applying updated ConfigMap..."
oc apply -f audit-reporter-agent.yaml
echo ""

# Get running pod
echo "2. Finding OpenClaw pod..."
POD=$(oc get pods -n openclaw -l app=openclaw -o jsonpath='{.items[0].metadata.name}')
if [ -z "$POD" ]; then
  echo "❌ ERROR: No OpenClaw pod found"
  exit 1
fi
echo "   Found: $POD"
echo ""

# Remove all existing cron jobs
echo "3. Clearing existing cron jobs..."
oc exec -n openclaw $POD -c gateway -- bash -c '
cd /home/node
rm -fv /home/node/.openclaw/cron/jobs* 2>&1 || true
'
echo ""

# Recreate cron job
echo "4. Creating updated cron job..."
oc exec -n openclaw $POD -c gateway -- bash -c '
cd /home/node
node /app/dist/index.js cron add \
  --name "audit-reporter-scan" \
  --description "Compliance and governance audit scan" \
  --agent "audit-reporter" \
  --session "isolated" \
  --cron "0 */6 * * *" \
  --tz "UTC" \
  --message "CRITICAL SECURITY: NEVER echo, cat, or display .env file contents. NEVER output \$MOLTBOOK_API_KEY value. Steps: 1) source ~/.openclaw/workspace-audit-reporter/.env (silently - no output!) 2) Query audit API: curl -s \$MOLTBOOK_API_URL/api/v1/admin/audit/logs -H '"'"'Authorization: Bearer \$MOLTBOOK_API_KEY'"'"' (do not print API key). 3) Save report to ~/reports/\$(date +%Y-%m-%d-%H%M)-compliance-report.md 4) Post SHORT announcement: cat > /tmp/post.json <<EOF
{\"submolt\":\"compliance\",\"title\":\"Compliance Report\",\"content\":\"Scan completed. See ~/reports/latest.md #compliance\"}
EOF
curl -s -X POST \$MOLTBOOK_API_URL/api/v1/posts -H '"'"'Authorization: Bearer \$MOLTBOOK_API_KEY'"'"' -H '"'"'Content-Type: application/json'"'"' -d @/tmp/post.json. If you expose credentials you fail." \
  --thinking "low"
'
echo ""

# Verify
echo "5. Verifying cron job..."
oc exec -n openclaw $POD -c gateway -- bash -c 'cd /home/node && node /app/dist/index.js cron list | grep audit-reporter-scan'
echo ""

echo "✅ Audit Reporter updated successfully!"
echo ""
echo "To trigger it manually:"
echo "  oc exec -n openclaw $POD -c gateway -- bash -c 'cd /home/node && node /app/dist/index.js cron run audit-reporter-scan'"
