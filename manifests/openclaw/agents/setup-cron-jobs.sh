#!/bin/bash
# Setup cron jobs for agents
# For RWO (ReadWriteOnce) PVCs - runs commands inside the existing pod

set -e

echo "🕐 Setting up cron jobs for agents..."
echo ""

# Get running pod
echo "1. Finding OpenClaw pod..."
POD=$(oc get pods -n openclaw -l app=openclaw -o jsonpath='{.items[0].metadata.name}')
if [ -z "$POD" ]; then
  echo "❌ ERROR: No OpenClaw pod found"
  exit 1
fi
echo "   Found: $POD"
echo ""

# Delete jobs files and clear all jobs
echo "2. Clearing existing cron jobs..."
oc exec -n openclaw $POD -c gateway -- bash -c '
cd /home/node

# Delete jobs.json files first
echo "  Removing jobs files..."
rm -fv /home/node/.openclaw/cron/jobs* 2>&1 || echo "  No jobs files found"
'
echo ""

# Setup cron jobs
echo "3. Creating fresh cron jobs..."
cat <<'SETUP_SCRIPT' | oc exec -i -n openclaw $POD -c gateway -- bash
cd /home/node

echo "  Creating fresh cron jobs..."

# PhilBot - Daily at 9AM UTC
echo "    - PhilBot: Daily at 9AM UTC (philosophy)"
node /app/dist/index.js cron add \
  --name "philbot-daily-post" \
  --description "Daily philosophical post" \
  --agent "philbot" \
  --cron "0 9 * * *" \
  --tz "UTC" \
  --message "CRITICAL: Run ALL steps in ONE command. NEVER expose credentials. Execute: . ~/.openclaw/workspace-philbot/.env && cat > /tmp/post.json <<'EOF' && curl -s -X POST \$MOLTBOOK_API_URL/api/v1/posts -H 'Authorization: Bearer \$MOLTBOOK_API_KEY' -H 'Content-Type: application/json' -d @/tmp/post.json && rm /tmp/post.json
{\"submolt\":\"philosophy\",\"title\":\"Daily Thought\",\"content\":\"[Your question]\\n\\n#philosophy\"}
EOF
" \
  --thinking "low"

# Audit Reporter - Every 6 hours
echo "    - Audit Reporter: Every 6 hours (compliance)"
node /app/dist/index.js cron add \
  --name "audit-reporter-scan" \
  --description "Compliance and governance audit scan" \
  --agent "audit-reporter" \
  --cron "0 */6 * * *" \
  --tz "UTC" \
  --message "CRITICAL: Run ALL steps in ONE command. NEVER expose credentials. Execute: . ~/.openclaw/workspace-audit-reporter/.env && cat > /tmp/post.json <<'EOF' && curl -s -X POST \$MOLTBOOK_API_URL/api/v1/posts -H 'Authorization: Bearer \$MOLTBOOK_API_KEY' -H 'Content-Type: application/json' -d @/tmp/post.json && rm /tmp/post.json
{\"submolt\":\"compliance\",\"title\":\"Compliance Report\",\"content\":\"Report generated.\\n\\n#compliance\"}
EOF
" \
  --thinking "low"

# Resource Optimizer - Daily at 8AM UTC
echo "    - Resource Optimizer: Daily at 8AM UTC (cost analysis)"
node /app/dist/index.js cron add \
  --name "resource-optimizer-scan" \
  --description "Daily cost optimization analysis" \
  --agent "resource-optimizer" \
  --cron "0 8 * * *" \
  --tz "UTC" \
  --message "CRITICAL: Run ALL steps in ONE command. NEVER expose credentials. Execute: . ~/.openclaw/workspace-resource-optimizer/.env && cat > /tmp/post.json <<'EOF' && curl -s -X POST \$MOLTBOOK_API_URL/api/v1/posts -H 'Authorization: Bearer \$MOLTBOOK_API_KEY' -H 'Content-Type: application/json' -d @/tmp/post.json && rm /tmp/post.json
{\"submolt\":\"cost_resource_analysis\",\"title\":\"Cost Report\",\"content\":\"Report generated.\\n\\n#cost #finops\"}
EOF
" \
  --thinking "low"

# MLOps Monitor - Every 4 hours
echo "    - MLOps Monitor: Every 4 hours (ML operations)"
node /app/dist/index.js cron add \
  --name "mlops-monitor-check" \
  --description "ML operations monitoring" \
  --agent "mlops-monitor" \
  --cron "0 */4 * * *" \
  --tz "UTC" \
  --message "CRITICAL: Run ALL steps in ONE command. NEVER expose credentials. Execute: . ~/.openclaw/workspace-mlops-monitor/.env && cat > /tmp/post.json <<'EOF' && curl -s -X POST \$MOLTBOOK_API_URL/api/v1/posts -H 'Authorization: Bearer \$MOLTBOOK_API_KEY' -H 'Content-Type: application/json' -d @/tmp/post.json && rm /tmp/post.json
{\"submolt\":\"mlops\",\"title\":\"MLOps Update\",\"content\":\"ML monitoring update.\\n\\n#mlops #experiments\"}
EOF
" \
  --thinking "low"

echo ""
echo "✅ Cron jobs configured!"
SETUP_SCRIPT
echo ""

# List cron jobs to verify
echo "4. Verifying cron jobs..."
oc exec -n openclaw $POD -c gateway -- bash -c 'cd /home/node && node /app/dist/index.js cron list'
echo ""

echo "✅ Cron setup complete!"
echo ""
echo "Enterprise DevOps agents will autonomously monitor and post to Moltbook:"
echo "  - PhilBot:            9AM UTC daily (philosophy submolt)"
echo "  - Audit Reporter:     Every 6 hours (compliance submolt)"
echo "  - Resource Optimizer: 8AM UTC daily (cost_resource_analysis submolt)"
echo "  - MLOps Monitor:      Every 4 hours (mlops submolt)"
