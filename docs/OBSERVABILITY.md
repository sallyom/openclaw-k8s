# Observability with OpenTelemetry and MLflow

This guide documents the production observability setup for OpenClaw and Moltbook using OpenTelemetry collector sidecars and MLflow Tracking.

## Architecture Overview

The observability stack uses **sidecar-based OTEL collectors** that send traces directly to MLflow:

```
┌─────────────────────────────────────────────────────────────────┐
│ Pod: openclaw-xxxxxxxxx-xxxxx (openclaw namespace)              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────┐         ┌──────────────────────────────┐  │
│  │  Gateway         │  OTLP   │  OTEL Collector Sidecar      │  │
│  │  Container       │──────▶  │  (auto-injected)             │  │
│  │                  │  :4318  │                              │  │
│  │  diagnostics-    │         │  - Batches traces            │  │
│  │  otel plugin     │         │  - Adds metadata             │  │
│  └──────────────────┘         │  - Exports to MLflow         │  │
│                               └──────────────────────────────┘  │
│                                         │                       │
└─────────────────────────────────────────┼───────────────────────┘
                                          │
                                          ▼ OTLP/HTTP (in-cluster)
┌─────────────────────────────────────────────────────────────────┐
│ MLflow Tracking Server (mlflow namespace)                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Service: mlflow-service.mlflow.svc.cluster.local:5000          │
│  Endpoint: /v1/traces (OTLP standard path)                      │
│                                                                 │
│  Features:                                                      │
│  ✅ Trace ingestion via OTLP                                    │
│  ✅ Automatic span→trace conversion                             │
│  ✅ LLM-specific trace metadata                                 │
│  ✅ Request/Response column population                          │
│  ✅ Session grouping for multi-turn conversations               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

The same pattern applies to Moltbook pods in the `moltbook` namespace.

## Why Sidecars?

### Benefits

1. **Zero application changes**: Apps send to `localhost:4318` - no network complexity
2. **Automatic injection**: OpenTelemetry Operator injects sidecars based on pod annotations
3. **Resource isolation**: Each pod has its own collector with dedicated resources
4. **Batch optimization**: Sidecars batch traces before sending to reduce network overhead
5. **Metadata enrichment**: Add namespace, environment, and MLflow-specific attributes
6. **Direct to MLflow**: No intermediate collectors - simpler architecture

### How It Works

1. **Pod annotation** triggers sidecar injection:

2. **OpenTelemetry Operator** sees the annotation and injects a sidecar container

3. **Application** sends OTLP traces to `http://localhost:4318/v1/traces`

4. **Sidecar** receives, processes, and forwards to MLflow

## Components

### 1. OpenClaw Gateway (openclaw namespace)

**Built-in OTLP instrumentation** via `extensions/diagnostics-otel`:

- **Span creation**: Root spans for each message.process event
- **Nested tool spans**: Tool usage creates child spans under the root
- **LLM metadata**: Captures model, provider, usage, cost
- **MLflow-specific attributes**:
  - `mlflow.spanInputs` (OpenAI chat message format: `{"role":"user","content":"..."}`)
  - `mlflow.spanOutputs` (OpenAI chat message format: `{"role":"assistant","content":"..."}`)
  - `mlflow.trace.session` (for multi-turn conversation grouping)
  - `gen_ai.prompt` and `gen_ai.completion` (raw text)

**Configuration** (in `openclaw.json`):
```json
{
  "diagnostics": {
    "enabled": true,
    "otel": {
      "enabled": true,
      "endpoint": "http://localhost:4318",
      "traces": true,
      "metrics": true,
      "logs": false
    }
  }
}
```

### 2. OTEL Collector Sidecar (openclaw namespace)

**Auto-injected** by OpenTelemetry Operator based on pod annotation.

**Configuration** (`observability/openclaw-otel-sidecar.yaml.envsubst`):

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: openclaw-sidecar
  namespace: ${OPENCLAW_NAMESPACE}
spec:
  mode: sidecar

  config: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 127.0.0.1:4317
          http:
            endpoint: 127.0.0.1:4318

    processors:
      batch:
        timeout: 5s
        send_batch_size: 100

      memory_limiter:
        check_interval: 1s
        limit_mib: 256
        spike_limit_mib: 64

      resource:
        attributes:
          - key: service.namespace
            value: ${OPENCLAW_NAMESPACE}
            action: upsert
          - key: deployment.environment
            value: production
            action: upsert

    exporters:
      # Uses in-cluster service URL to avoid DNS rebinding rejection on the external route
      otlphttp:
        endpoint: http://mlflow-service.mlflow.svc.cluster.local:5000
        headers:
          x-mlflow-experiment-id: "4"
          x-mlflow-workspace: "openclaw"
        tls:
          insecure: true

      debug:
        verbosity: detailed

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [otlphttp, debug]
```

**Key points**:
- Listens on `localhost:4317` (gRPC) and `localhost:4318` (HTTP), only accessible within pod
- Batches traces for efficiency
- Adds namespace and environment metadata
- Uses in-cluster service URL (`mlflow-service.mlflow.svc:5000`) — avoids DNS rebinding rejection from MLflow's `HostValidationMiddleware` when going through the external route
- Path `/v1/traces` is auto-appended by the OTLP exporter
- Custom headers for MLflow experiment/workspace routing

### 3. Moltbook API (moltbook namespace)

**Same sidecar pattern** as OpenClaw.

**Configuration** (`observability/moltbook-otel-sidecar.yaml`):

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: moltbook-sidecar
  namespace: moltbook
spec:
  mode: sidecar

  config: |
    receivers:
      otlp:
        protocols:
          http:
            endpoint: 127.0.0.1:4318

    processors:
      batch:
        timeout: 10s
        send_batch_size: 1024

      memory_limiter:
        check_interval: 1s
        limit_mib: 256
        spike_limit_mib: 64

      probabilistic_sampler:
        sampling_percentage: 10.0  # Sample 10% of traces

      resource:
        attributes:
          - key: service.namespace
            value: moltbook
            action: upsert
          - key: mlflow.experimentName
            value: OpenClaw
            action: upsert

    exporters:
      otlphttp:
        endpoint: http://mlflow-service.mlflow.svc.cluster.local:5000
        headers:
          x-mlflow-experiment-id: "4"
          x-mlflow-workspace: "moltbook"
        tls:
          insecure: true

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, probabilistic_sampler, resource, batch]
          exporters: [otlphttp, debug]
```

**Differences from OpenClaw**:
- **10% sampling** (probabilistic_sampler) to reduce trace volume
- Larger batch size (1024 vs 100)
- Different MLflow workspace header

### 4. MLflow Tracking Server (mlflow namespace)

**OTLP Ingestion**:
- In-cluster: `http://mlflow-service.mlflow.svc.cluster.local:5000/v1/traces`
- External route: `https://mlflow-route-mlflow.CLUSTER_DOMAIN` (for UI access only)
- Accepts OTLP traces via HTTP/Protobuf
- Automatically converts spans to MLflow traces

> **Note:** Use the in-cluster service URL for trace export from sidecars. The external route triggers MLflow's `HostValidationMiddleware` (DNS rebinding protection, added in MLflow 3.5.0+), which rejects requests with unexpected `Host` headers. The in-cluster URL avoids this entirely.

**MLflow UI Features**:
- **Traces tab**: Browse all traces with filters
- **Request/Response columns**: Populated from `mlflow.spanInputs`/`mlflow.spanOutputs` on ROOT span
- **Session column**: Groups multi-turn conversations via `mlflow.trace.session` attribute
- **Nested span hierarchy**: Tools appear as children under LLM spans
- **Metadata**: Model, provider, usage, cost, duration

**Known Limitations**:
- User/Prompt columns don't populate from OTLP (MLflow UI limitation)
- Trace-level attributes must be on ROOT span, not child spans
- Must use OpenAI chat message format for Input/Output: `{"role":"user","content":"..."}`

## Deployment

### Available Sidecar Configurations

This repository includes three OTEL collector sidecar configurations:

| Sidecar | Namespace | Purpose | Sampling | Batch Size | Exports To |
|---------|-----------|---------|----------|------------|------------|
| `openclaw-sidecar` | `${OPENCLAW_NAMESPACE}` | OpenClaw agent traces | 100% | 100 | MLflow Experiment 4 |
| `moltbook-sidecar` | `moltbook` | Moltbook API traces | 10% | 1024 | MLflow Experiment 4 |
| `vllm-sidecar` | `demo-mlflow-agent-tracing` | vLLM inference traces (dual-export) | 100% | 100 | MLflow Experiments 2 & 4 |

**Key differences:**
- **OpenClaw**: Full sampling, optimized for LLM agent tracing with MLflow-specific attributes
- **Moltbook**: 10% sampling to reduce high-volume API trace data
- **vLLM**: Dual-pipeline export - Experiment 2 for direct vLLM calls, Experiment 4 for OpenClaw-initiated traces

### Prerequisites

1. **OpenTelemetry Operator** installed in cluster

2. **MLflow** with OTLP endpoint accessible

3. **Network connectivity** from openclaw/moltbook namespaces to MLflow service (`mlflow-service.mlflow.svc.cluster.local:5000`)

### Deploy OTEL Collector Sidecars

**Note:** If you used `./scripts/setup.sh`, the `.envsubst` templates have already been processed and deployed.

#### Option 1: Automated Deployment (Recommended)

The setup script automatically runs `envsubst` on sidecar templates and deploys them:

```bash
./scripts/setup.sh
# Generates from .envsubst templates:
# - observability/openclaw-otel-sidecar.yaml
# - observability/moltbook-otel-sidecar.yaml
# - observability/vllm-otel-sidecar.yaml
```

#### Option 2: Manual Deployment

Run `envsubst` on templates and deploy:

```bash
# Source the generated secrets
source .env && set -a

# Generate YAML from templates
ENVSUBST_VARS='${CLUSTER_DOMAIN} ${OPENCLAW_NAMESPACE}'
for tpl in observability/*.envsubst; do
  envsubst "$ENVSUBST_VARS" < "$tpl" > "${tpl%.envsubst}"
done

# Deploy each sidecar configuration
oc apply -f observability/openclaw-otel-sidecar.yaml
oc apply -f observability/moltbook-otel-sidecar.yaml
oc apply -f observability/vllm-otel-sidecar.yaml
```

#### Verify Sidecar Configurations

```bash
# Check OpenClaw sidecar config
oc get opentelemetrycollector openclaw-sidecar -n openclaw

# Check Moltbook sidecar config
oc get opentelemetrycollector moltbook-sidecar -n moltbook

# Check vLLM sidecar config
oc get opentelemetrycollector vllm-sidecar -n demo-mlflow-agent-tracing
```

### Enable Sidecar Injection on Deployments

Once the `OpenTelemetryCollector` resources are deployed, enable sidecar injection by adding an annotation to your pod templates.

#### OpenClaw Deployment

Edit `manifests/openclaw/base/openclaw-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openclaw
  namespace: openclaw
spec:
  template:
    metadata:
      annotations:
        # This triggers automatic sidecar injection
        sidecar.opentelemetry.io/inject: "openclaw-sidecar"
    spec:
      containers:
      - name: gateway
        # ... rest of container spec
```

Then apply the change:
```bash
oc apply -k manifests/openclaw/overlays/openshift/
oc rollout restart deployment/openclaw -n openclaw
```

#### Moltbook API Deployment

Edit `manifests/moltbook/base/moltbook-api-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: moltbook-api
  namespace: moltbook
spec:
  template:
    metadata:
      annotations:
        # This triggers automatic sidecar injection
        sidecar.opentelemetry.io/inject: "moltbook-sidecar"
    spec:
      containers:
      - name: api
        # ... rest of container spec
```

Then apply the change:
```bash
oc apply -k manifests/moltbook/overlays/openshift/
oc rollout restart deployment/moltbook-api -n moltbook
```

#### vLLM Deployment (Optional)

For vLLM deployments that need dual-export to multiple MLflow experiments:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gpt-oss-20b
  namespace: demo-mlflow-agent-tracing
spec:
  template:
    metadata:
      annotations:
        # This triggers automatic sidecar injection
        sidecar.opentelemetry.io/inject: "vllm-sidecar"
    spec:
      containers:
      - name: vllm
        # ... rest of container spec
```

#### Verify Sidecar Injection

After restarting the deployments, verify the sidecar was injected:

```bash
# OpenClaw - should show 2 containers (gateway + otc-container)
oc get pods -n openclaw -l app=openclaw -o jsonpath='{.items[0].spec.containers[*].name}'

# Moltbook - should show 2 containers (api + otc-container)
oc get pods -n moltbook -l app=moltbook-api -o jsonpath='{.items[0].spec.containers[*].name}'

# Check sidecar logs
oc logs -n openclaw -l app=openclaw -c otc-container
oc logs -n moltbook -l app=moltbook-api -c otc-container
```

### Update Cluster-Specific Values

**Important:** The `observability/` directory contains `.envsubst` templates with `${OPENCLAW_NAMESPACE}` and `${CLUSTER_DOMAIN}` placeholders. The OpenClaw sidecar uses the in-cluster MLflow service URL (no cluster domain needed), but the vLLM sidecar still references `${CLUSTER_DOMAIN}` for the external route.

**Automated (recommended):**
```bash
# setup.sh runs envsubst on all templates automatically
./scripts/setup.sh
```

**Manual:**
```bash
# Source .env for all variables
source .env

# Generate YAML from templates
for tpl in observability/*.envsubst; do
  envsubst '${CLUSTER_DOMAIN} ${OPENCLAW_NAMESPACE}' < "$tpl" > "${tpl%.envsubst}"
done

# Then deploy
oc apply -f observability/openclaw-otel-sidecar.yaml
oc apply -f observability/moltbook-otel-sidecar.yaml
oc apply -f observability/vllm-otel-sidecar.yaml
```

### Verify Traces in MLflow

1. Access MLflow UI via route: `https://mlflow-route-mlflow.apps.YOUR_CLUSTER_DOMAIN`
   - Or port-forward: `oc port-forward svc/mlflow-service 5000:5000 -n mlflow`
2. Navigate to **Traces** tab
3. Filter by workspace: `openclaw` or `moltbook`
4. Click a trace to see:
   - Request/Response columns populated
   - Nested span hierarchy (message.process → llm → tool spans)
   - Metadata (model, usage, cost)

## Configuration Reference

### Sidecar Resource Limits

**Recommended values**:
```yaml
resources:
  requests:
    memory: 128Mi
    cpu: 100m
  limits:
    memory: 256Mi
    cpu: 200m
```

Increase if experiencing OOM or CPU throttling.

### Batch Processing

**Balance latency vs throughput**:
```yaml
batch:
  timeout: 5s          # Max time to wait before sending batch
  send_batch_size: 100 # Max traces per batch
```

- Lower timeout = lower latency, more network overhead
- Higher batch size = better throughput, higher memory usage

### Sampling

**Reduce trace volume** (Moltbook example):
```yaml
probabilistic_sampler:
  sampling_percentage: 10.0  # Sample 10% of traces
```

Useful for high-traffic services.

### MLflow Headers

**Route traces to experiments/workspaces**:
```yaml
headers:
  x-mlflow-experiment-id: "4"      # MLflow experiment ID
  x-mlflow-workspace: "openclaw"   # Arbitrary workspace tag
```

## Best Practices

1. **Use sidecars for applications**: Simplest pattern, no network complexity
2. **Batch aggressively**: Reduces network overhead and MLflow ingestion load
3. **Sample high-volume services**: Use probabilistic sampling for high-traffic APIs
4. **Monitor sidecar health**: Set up alerts for OOM or high CPU
5. **Set MLflow attributes on ROOT span**: Only root span attributes become trace-level metadata
6. **Use OpenAI chat format**: MLflow expects `{"role":"user","content":"..."}` for Input/Output columns
7. **Handle tool phases correctly**: Agent emits `phase="result"` not `"end"`

## Context Propagation (Distributed Tracing)

OpenClaw now supports **W3C Trace Context** propagation to downstream services, enabling end-to-end distributed tracing across:
- **OpenClaw → vLLM**: See LLM inference as nested spans under agent traces
- **OpenClaw → Moltbook**: See API calls as nested spans (when Moltbook has OTLP instrumentation)
- **OpenClaw → Any OTLP-instrumented service**: Full request path visibility

### How It Works

When OpenClaw makes an HTTP request to an LLM provider (like vLLM):

1. **OpenClaw** gets the active OpenTelemetry span context
2. **Trace context injector** formats W3C `traceparent` header:
   ```
   traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
   ```
3. **HTTP request** includes the header
4. **vLLM** (or other service) extracts the header and creates child spans
5. **MLflow** displays the full nested trace hierarchy

### vLLM Configuration

vLLM has built-in OpenTelemetry support. To enable trace context extraction:

**Environment variables** (vLLM deployment):
```yaml
            env:
            - name: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
              # Use in-cluster URL (preferred) or external route
              value: 'http://mlflow-service.mlflow.svc.cluster.local:5000/v1/traces'
            - name: OTEL_EXPORTER_OTLP_TRACES_HEADERS
              value: x-mlflow-experiment-id=2
            - name: OTEL_SERVICE_NAME
              value: vllm-gpt-oss-20b
            - name: OTEL_EXPORTER_OTLP_TRACES_PROTOCOL
              value: http/protobuf
```

**vLLM startup** (if using direct MLflow export):
```bash
            args:
            - |
              pip install 'opentelemetry-sdk>=1.26.0,<1.27.0' \
                'opentelemetry-api>=1.26.0,<1.27.0' \
                'opentelemetry-exporter-otlp>=1.26.0,<1.27.0' \
                'opentelemetry-semantic-conventions-ai>=0.4.1,<0.5.0' && \
              vllm serve openai/gpt-oss-20b \
                --tool-call-parser openai \
                --enable-auto-tool-choice \
                --otlp-traces-endpoint http://mlflow-service.mlflow.svc.cluster.local:5000/v1/traces \
                --collect-detailed-traces all
```

### Nested Trace Example

**Before context propagation** (separate traces):
```
Trace 1 (OpenClaw):
└─ message.process (root)
   └─ llm (child)
   └─ tool.exec (child)

Trace 2 (vLLM) - SEPARATE:
└─ /v1/chat/completions (root)
   └─ model.forward (child)
```

**After context propagation** (nested):
```
Trace 1 (OpenClaw):
└─ message.process (root)
   └─ llm (child)
      └─ /v1/chat/completions (NESTED - from vLLM)
         └─ model.forward (child)
         └─ tokenization (child)
   └─ tool.exec (child)
```

## Troubleshooting

### DNS Rebinding / Host Header Rejected (HTTP 403)

**Problem:** Sidecar logs show `Permanent error: rpc error: code = PermissionDenied desc = ... 403`

MLflow 3.5.0+ includes `HostValidationMiddleware` (`fastapi_security.py`) that rejects requests where the `Host` header doesn't match `--allowed-hosts`. When using in-cluster service URLs, the `Host` header includes the port (e.g., `mlflow-service.mlflow.svc.cluster.local:5000`) but `--allowed-hosts` may only list the hostname without port.

**Solution:** Add port variants to MLflow's `--allowed-hosts`:
```
--allowed-hosts "localhost,localhost:5000,mlflow-service,mlflow-service:5000,mlflow-service.mlflow.svc.cluster.local,mlflow-service.mlflow.svc.cluster.local:5000"
```

**Verify in MLflow logs:**
```bash
# Check what hosts are allowed
oc logs deployment/mlflow-deployment -n mlflow | grep "Allowed hosts"

# Check for rejections
oc logs deployment/mlflow-deployment -n mlflow | grep "Rejected request"
```

### High Cardinality Warnings

**Problem:** MLflow UI shows warnings about high cardinality attributes

**Solution:**
1. Enable sampling for high-volume services (like Moltbook):
   ```yaml
   processors:
     probabilistic_sampler:
       sampling_percentage: 10.0  # Sample 10%
   ```

2. Remove high-cardinality attributes in the collector:
   ```yaml
   processors:
     attributes:
       actions:
         - key: http.request.header.x-request-id
           action: delete
   ```

### Request/Response Columns Not Populating

**Problem:** MLflow Traces tab shows traces but Input/Output columns are empty

**Solution:**
This is expected behavior when using OTLP. The MLflow UI limitations are:
- Input/Output columns only populate from `mlflow.spanInputs`/`mlflow.spanOutputs` on **ROOT span**
- User/Prompt columns don't populate from OTLP at all
- Must use OpenAI chat message format: `{"role":"user","content":"..."}`

To verify your attributes are correct:
```bash
# Check OpenClaw is emitting the right attributes
oc logs -n openclaw -l app=openclaw -c gateway | grep -i "mlflow.spanInputs"
```

Expected format on root span:
- `mlflow.spanInputs`: `{"role":"user","content":"Hello"}`
- `mlflow.spanOutputs`: `{"role":"assistant","content":"Hi there!"}`

## Related Documentation

- [OpenClaw Diagnostics Plugin](../extensions/diagnostics-otel/)
- [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator)
- [MLflow Tracing](https://mlflow.org/docs/latest/llms/tracing/index.html)
- [OTLP Specification](https://opentelemetry.io/docs/specs/otlp/)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/)
