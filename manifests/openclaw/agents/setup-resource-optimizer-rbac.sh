#!/bin/bash
# Setup RBAC for resource-optimizer agent
# Creates ServiceAccount + token, grants minimal read-only access to resource-demo namespace

set -e

echo "🔐 Setting up RBAC for resource-optimizer agent..."
echo ""

# Step 1: Apply RBAC resources
echo "1. Creating ServiceAccount and RBAC..."
oc apply -f resource-optimizer-rbac.yaml
echo "   ✅ RBAC resources created"
echo ""

# Step 2: Wait for token to be generated
echo "2. Waiting for ServiceAccount token..."
for i in {1..30}; do
  TOKEN=$(oc get secret resource-optimizer-sa-token -n openclaw -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "")
  if [ -n "$TOKEN" ]; then
    echo "   ✅ Token generated"
    break
  fi
  echo "   Waiting... ($i/30)"
  sleep 2
done

if [ -z "$TOKEN" ]; then
  echo "   ❌ ERROR: Token not generated after 60 seconds"
  echo "   Check if the secret was created:"
  echo "     oc get secret resource-optimizer-sa-token -n openclaw"
  exit 1
fi

echo "   Token: ${TOKEN:0:20}..."
echo ""

# Step 3: Find OpenClaw pod
echo "3. Finding OpenClaw pod..."
POD=$(oc get pods -n openclaw -l app=openclaw --field-selector=status.phase=Running -o json | \
  jq -r '.items[] | select(.metadata.ownerReferences[0].kind=="ReplicaSet") | .metadata.name' | head -1)

if [ -z "$POD" ]; then
  echo "   ❌ ERROR: No OpenClaw deployment pod found"
  exit 1
fi

echo "   Found: $POD"
echo ""

# Step 4: Update .env file with token
echo "4. Adding OC_TOKEN to resource-optimizer .env..."

# Check if .env exists
if ! oc exec -n openclaw $POD -c gateway -- test -f /home/node/.openclaw/workspace-resource-optimizer/.env; then
  echo "   ❌ ERROR: .env file not found"
  echo "   Run setup-agent-workspaces.sh first"
  exit 1
fi

# Add OC_TOKEN to .env (or update if exists)
oc exec -n openclaw $POD -c gateway -- bash -c "
  ENV_FILE=/home/node/.openclaw/workspace-resource-optimizer/.env

  # Remove old OC_TOKEN line if exists
  grep -v '^OC_TOKEN=' \$ENV_FILE > \$ENV_FILE.tmp || true
  mv \$ENV_FILE.tmp \$ENV_FILE

  # Add new OC_TOKEN
  echo 'OC_TOKEN=$TOKEN' >> \$ENV_FILE

  # Verify
  echo '✅ Updated .env file:'
  cat \$ENV_FILE
"

echo ""
echo "   ✅ OC_TOKEN added to .env"
echo ""

# Step 5: Verify permissions (with retry for token propagation)
echo "5. Verifying permissions..."

# Test read access to resource-demo using Kubernetes API
echo "   Testing read access to resource-demo namespace..."
echo "   (Token may need a few seconds to propagate to API server...)"

MAX_RETRIES=10
RETRY_COUNT=0
SUCCESS=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  TEST_OUTPUT=$(oc exec -n openclaw $POD -c gateway -- bash -c "
    source ~/.openclaw/workspace-resource-optimizer/.env
    K8S_API='https://kubernetes.default.svc'
    curl -s -H 'Authorization: Bearer \$OC_TOKEN' \
      --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
      \"\$K8S_API/api/v1/namespaces/resource-demo/pods\" 2>&1 | head -20
  " 2>&1 || echo "FAILED")

  if echo "$TEST_OUTPUT" | grep -q '"kind":"PodList"'; then
    echo "   ✅ Can read pods in resource-demo"
    SUCCESS=true
    break
  elif echo "$TEST_OUTPUT" | grep -q "Unauthorized"; then
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
      echo "   Waiting for token to propagate... (attempt $RETRY_COUNT/$MAX_RETRIES)"
      sleep 2
    fi
  else
    echo "   ❌ Permission test failed:"
    echo "$TEST_OUTPUT" | head -10
    exit 1
  fi
done

if [ "$SUCCESS" != "true" ]; then
  echo "   ❌ Permission test failed after $MAX_RETRIES attempts"
  echo "   Token may need more time to propagate. Try running verification manually:"
  echo "     oc exec -n openclaw $POD -c gateway -- bash -c 'source ~/.openclaw/workspace-resource-optimizer/.env && curl -s -H \"Authorization: Bearer \$OC_TOKEN\" --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt https://kubernetes.default.svc/api/v1/namespaces/resource-demo/pods'"
  exit 1
fi

# Test metrics access
echo "   Testing metrics access..."
METRICS_TEST=$(oc exec -n openclaw $POD -c gateway -- bash -c "
  source ~/.openclaw/workspace-resource-optimizer/.env
  K8S_API='https://kubernetes.default.svc'
  curl -s -H 'Authorization: Bearer \$OC_TOKEN' \
    --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    \"\$K8S_API/apis/metrics.k8s.io/v1beta1/namespaces/resource-demo/pods\" 2>&1
" 2>&1 || echo "FAILED")

if echo "$METRICS_TEST" | grep -q '"kind":"PodMetricsList"'; then
  echo "   ✅ Can read pod metrics"
elif echo "$METRICS_TEST" | grep -q "NotFound\|not found"; then
  echo "   ⚠️  Metrics API not available (metrics-server may not be installed)"
  echo "   Agent can still analyze resource requests vs limits, but won't have actual usage data"
elif echo "$METRICS_TEST" | grep -q "Unauthorized"; then
  echo "   ⚠️  Metrics API: Token not yet propagated (may work after a few seconds)"
else
  echo "   ⚠️  Metrics test inconclusive"
  echo "$METRICS_TEST" | head -5
fi

# Test that agent CANNOT write
echo "   Testing write protection (should be denied)..."
WRITE_TEST=$(oc exec -n openclaw $POD -c gateway -- bash -c "
  source ~/.openclaw/workspace-resource-optimizer/.env
  K8S_API='https://kubernetes.default.svc'
  curl -s -X DELETE \
    -H 'Authorization: Bearer \$OC_TOKEN' \
    --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    \"\$K8S_API/api/v1/namespaces/resource-demo/pods/nonexistent\" 2>&1
" 2>&1 || echo "BLOCKED")

if echo "$WRITE_TEST" | grep -q "Forbidden\|forbidden"; then
  echo "   ✅ Write operations blocked (as expected)"
elif echo "$WRITE_TEST" | grep -q "NotFound"; then
  echo "   ⚠️  Write test inconclusive (got NotFound instead of Forbidden)"
  echo "   This may indicate write access - check RBAC permissions"
else
  echo "   ⚠️  Write test result unclear"
  echo "$WRITE_TEST" | head -3
fi

echo ""
echo "✅ RBAC setup complete!"
echo ""
echo "Summary:"
echo "  - ServiceAccount: resource-optimizer-sa (in openclaw namespace)"
echo "  - Token: Saved to ~/.openclaw/workspace-resource-optimizer/.env as OC_TOKEN"
echo "  - Permissions: Read-only access to resource-demo namespace"
echo "  - Resources: pods, pvcs, deployments, metrics"
echo ""
echo "Agent can now use Kubernetes API:"
echo "  curl -H \"Authorization: Bearer \$OC_TOKEN\" \\"
echo "    --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \\"
echo "    https://kubernetes.default.svc/api/v1/namespaces/resource-demo/pods"
echo ""
echo "See AGENTS.md for complete API examples and helper functions."
echo ""
