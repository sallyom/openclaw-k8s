# Kubernetes API Reference for Resource Optimizer

Quick reference for querying Kubernetes API from resource-optimizer agent.

## Setup

```bash
# Load credentials
source ~/.openclaw/workspace-resource-optimizer/.env

# Set API endpoint
K8S_API="https://kubernetes.default.svc"
CA_CERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

# Helper function
kube_get() {
  curl -s -H "Authorization: Bearer $OC_TOKEN" \
    --cacert "$CA_CERT" \
    "$K8S_API$1"
}
```

## Common Queries

### Get Pods with Resource Requests

```bash
kube_get "/api/v1/namespaces/resource-demo/pods" | jq -r '
  .items[] | {
    name: .metadata.name,
    phase: .status.phase,
    cpu_request: .spec.containers[0].resources.requests.cpu,
    memory_request: .spec.containers[0].resources.requests.memory,
    cpu_limit: .spec.containers[0].resources.limits.cpu,
    memory_limit: .spec.containers[0].resources.limits.memory
  }
'
```

### Get Pod Metrics (Actual Usage)

```bash
kube_get "/apis/metrics.k8s.io/v1beta1/namespaces/resource-demo/pods" | jq -r '
  .items[] | {
    name: .metadata.name,
    cpu_usage: .containers[0].usage.cpu,
    memory_usage: .containers[0].usage.memory
  }
'
```

### Compare Usage vs Requests (Find Waste)

```bash
# Get both metrics and specs, join them
METRICS=$(kube_get "/apis/metrics.k8s.io/v1beta1/namespaces/resource-demo/pods")
PODS=$(kube_get "/api/v1/namespaces/resource-demo/pods")

# Process with jq to find over-provisioned pods
echo "$METRICS" "$PODS" | jq -s '
  # Create lookup of metrics by pod name
  (.[0].items | map({(.metadata.name): .}) | add) as $metrics |

  # Iterate pods and compare
  .[1].items[] |
  select($metrics[.metadata.name]) |
  {
    name: .metadata.name,
    cpu_request: .spec.containers[0].resources.requests.cpu,
    cpu_usage: $metrics[.metadata.name].containers[0].usage.cpu,
    memory_request: .spec.containers[0].resources.requests.memory,
    memory_usage: $metrics[.metadata.name].containers[0].usage.memory
  }
'
```

### Get Deployments

```bash
kube_get "/apis/apps/v1/namespaces/resource-demo/deployments" | jq -r '
  .items[] | {
    name: .metadata.name,
    replicas_desired: .spec.replicas,
    replicas_ready: .status.readyReplicas,
    replicas_available: .status.availableReplicas,
    containers: [.spec.template.spec.containers[] | {
      name: .name,
      image: .image,
      cpu_request: .resources.requests.cpu,
      memory_request: .resources.requests.memory
    }]
  }
'
```

### Find Idle Deployments (0 Replicas)

```bash
kube_get "/apis/apps/v1/namespaces/resource-demo/deployments" | jq -r '
  .items[] | select(.spec.replicas == 0) | {
    name: .metadata.name,
    replicas: .spec.replicas,
    last_updated: .metadata.creationTimestamp
  }
'
```

### Get PVCs

```bash
kube_get "/api/v1/namespaces/resource-demo/persistentvolumeclaims" | jq -r '
  .items[] | {
    name: .metadata.name,
    size: .spec.resources.requests.storage,
    storage_class: .spec.storageClassName,
    phase: .status.phase,
    volume_name: .spec.volumeName
  }
'
```

### Find Unused PVCs (Not Mounted)

```bash
# Get all PVCs
PVCS=$(kube_get "/api/v1/namespaces/resource-demo/persistentvolumeclaims" | jq -r '.items[].metadata.name')

# Get all pods and their mounted volumes
MOUNTED=$(kube_get "/api/v1/namespaces/resource-demo/pods" | jq -r '
  .items[].spec.volumes[]? | select(.persistentVolumeClaim) | .persistentVolumeClaim.claimName
' | sort -u)

# Find PVCs not in mounted list
echo "Unused PVCs:"
comm -23 <(echo "$PVCS" | sort) <(echo "$MOUNTED")
```

### Get StatefulSets

```bash
kube_get "/apis/apps/v1/namespaces/resource-demo/statefulsets" | jq -r '
  .items[] | {
    name: .metadata.name,
    replicas_desired: .spec.replicas,
    replicas_ready: .status.readyReplicas,
    replicas_current: .status.currentReplicas
  }
'
```

## Unit Conversion

### CPU Units

```bash
# Convert CPU from various formats to millicores
cpu_to_millicores() {
  local cpu=$1
  if [[ $cpu =~ ^([0-9]+)m$ ]]; then
    # Already in millicores (e.g., "100m")
    echo "${BASH_REMATCH[1]}"
  elif [[ $cpu =~ ^([0-9]+)$ ]]; then
    # Whole cores (e.g., "2" = 2000m)
    echo "$((${BASH_REMATCH[1]} * 1000))"
  else
    echo "0"
  fi
}

# Usage
REQUEST=$(cpu_to_millicores "2")        # Returns: 2000
USAGE=$(cpu_to_millicores "250m")       # Returns: 250
WASTE=$(( (REQUEST - USAGE) * 100 / REQUEST ))  # Returns: 87 (87% waste)
```

### Memory Units

```bash
# Convert memory to bytes
memory_to_bytes() {
  local mem=$1
  if [[ $mem =~ ^([0-9]+)Ki$ ]]; then
    echo "$((${BASH_REMATCH[1]} * 1024))"
  elif [[ $mem =~ ^([0-9]+)Mi$ ]]; then
    echo "$((${BASH_REMATCH[1]} * 1024 * 1024))"
  elif [[ $mem =~ ^([0-9]+)Gi$ ]]; then
    echo "$((${BASH_REMATCH[1]} * 1024 * 1024 * 1024))"
  else
    echo "0"
  fi
}

# Usage
REQUEST=$(memory_to_bytes "4Gi")      # Returns: 4294967296
USAGE=$(memory_to_bytes "512Mi")      # Returns: 536870912
WASTE=$(( (REQUEST - USAGE) * 100 / REQUEST ))  # Returns: 87 (87% waste)
```

## Error Handling

```bash
# Check if metrics API is available
check_metrics_api() {
  local result=$(kube_get "/apis/metrics.k8s.io/v1beta1/namespaces/resource-demo/pods" 2>&1)

  if echo "$result" | grep -q '"kind":"PodMetricsList"'; then
    return 0
  elif echo "$result" | grep -q "NotFound\|not found"; then
    echo "⚠️  Metrics API not available (metrics-server not installed)"
    return 1
  elif echo "$result" | grep -q "Forbidden\|forbidden"; then
    echo "❌ Permission denied to access metrics API"
    return 1
  else
    echo "❌ Unknown error accessing metrics API"
    return 1
  fi
}

# Use it
if check_metrics_api; then
  echo "Metrics API available, proceeding with analysis..."
else
  echo "Falling back to request-only analysis (no actual usage data)"
fi
```

## Complete Example: Find Over-Provisioned Pods

```bash
#!/bin/bash
set -e

# Load credentials
source ~/.openclaw/workspace-resource-optimizer/.env

K8S_API="https://kubernetes.default.svc"
CA_CERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

kube_get() {
  curl -s -H "Authorization: Bearer $OC_TOKEN" --cacert "$CA_CERT" "$K8S_API$1"
}

# Get metrics
METRICS=$(kube_get "/apis/metrics.k8s.io/v1beta1/namespaces/resource-demo/pods")
if ! echo "$METRICS" | grep -q '"kind":"PodMetricsList"'; then
  echo "❌ Metrics not available"
  exit 1
fi

# Get pod specs
PODS=$(kube_get "/api/v1/namespaces/resource-demo/pods")

# Find over-provisioned pods (using >75% waste threshold)
echo "$METRICS" "$PODS" | jq -r --arg threshold "75" '
  (.[0].items | map({(.metadata.name): .}) | add) as $metrics |

  .[1].items[] |
  select($metrics[.metadata.name]) |
  select(.status.phase == "Running") |

  # Extract values
  (.spec.containers[0].resources.requests.cpu // "0") as $cpu_req |
  ($metrics[.metadata.name].containers[0].usage.cpu // "0") as $cpu_usage |

  # Convert to millicores
  (if ($cpu_req | endswith("m")) then ($cpu_req | rtrimstr("m") | tonumber)
   else ($cpu_req | tonumber) * 1000 end) as $cpu_req_m |
  (if ($cpu_usage | endswith("m")) then ($cpu_usage | rtrimstr("m") | tonumber)
   else ($cpu_usage | tonumber) * 1000 end) as $cpu_usage_m |

  # Calculate waste percentage
  (if $cpu_req_m > 0 then (($cpu_req_m - $cpu_usage_m) * 100 / $cpu_req_m) else 0 end) as $waste |

  # Filter by threshold
  select($waste >= ($threshold | tonumber)) |

  {
    name: .metadata.name,
    cpu_request: $cpu_req,
    cpu_usage: $cpu_usage,
    waste_percent: ($waste | floor),
    recommendation: (if $cpu_usage_m > 0 then ($cpu_usage_m * 1.5 | floor | tostring) + "m" else "Review manually" end)
  }
'
```

## API Endpoints Reference

| Resource | API Endpoint |
|----------|--------------|
| Pods | `/api/v1/namespaces/resource-demo/pods` |
| Pod Metrics | `/apis/metrics.k8s.io/v1beta1/namespaces/resource-demo/pods` |
| Deployments | `/apis/apps/v1/namespaces/resource-demo/deployments` |
| StatefulSets | `/apis/apps/v1/namespaces/resource-demo/statefulsets` |
| ReplicaSets | `/apis/apps/v1/namespaces/resource-demo/replicasets` |
| PVCs | `/api/v1/namespaces/resource-demo/persistentvolumeclaims` |
| Services | `/api/v1/namespaces/resource-demo/services` |
| ConfigMaps | `/api/v1/namespaces/resource-demo/configmaps` (if granted) |

## Tips

- Always check for `"kind":"<ResourceList>"` to verify successful response
- Use `jq` for JSON processing (should be available in OpenClaw pod)
- Cache API responses to avoid hitting rate limits
- Handle missing metrics gracefully (metrics-server may not be installed)
- Convert units consistently before calculating percentages
- Consider adding 50% buffer to recommendations (usage * 1.5)

Happy optimizing! 💰
