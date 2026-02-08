# Observability with OpenTelemetry and MLflow

This guide documents the production observability setup for OpenClaw and Moltbook using OpenTelemetry collector sidecars and MLflow Tracking.

## Architecture Overview

The observability stack uses **sidecar-based OTEL collectors** that send traces directly to MLflow:

```
┌─────────────────────────────────────────────────────────────────┐
│ Pod: openclaw-xxxxxxxxx-xxxxx (openclaw namespace)              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────┐         ┌──────────────────────────────┐ │
│  │  Gateway         │  OTLP   │  OTEL Collector Sidecar      │ │
│  │  Container       │──────▶  │  (auto-injected)             │ │
│  │                  │  :4318  │                              │ │
│  │  diagnostics-    │         │  - Batches traces            │ │
│  │  otel plugin     │         │  - Adds metadata             │ │
│  └──────────────────┘         │  - Exports to MLflow         │ │
│                               └──────────────────────────────┘ │
│                                         │                       │
└─────────────────────────────────────────┼───────────────────────┘
                                          │
                                          ▼ OTLP/HTTP (HTTPS)
┌─────────────────────────────────────────────────────────────────┐
│ MLflow Tracking Server (demo-mlflow-agent-tracing namespace)    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Route: mlflow-route-mlflow.apps.CLUSTER_DOMAIN                │
│  Endpoint: /v1/traces (OTLP standard path)                     │
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

**Configuration** (`observability/openclaw-otel-sidecar.yaml`):

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: openclaw-sidecar
  namespace: openclaw
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
        timeout: 5s
        send_batch_size: 100

      memory_limiter:
        check_interval: 1s
        limit_mib: 256
        spike_limit_mib: 64

      resource:
        attributes:
          - key: service.namespace
            value: openclaw
            action: upsert
          - key: deployment.environment
            value: production
            action: upsert

    exporters:
      otlphttp:
        endpoint: https://mlflow-route-mlflow.apps.CLUSTER_DOMAIN
        headers:
          x-mlflow-experiment-id: "4"
          x-mlflow-workspace: "openclaw"
        tls:
          insecure: false

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
- Listens on `localhost:4318` (only accessible within pod)
- Batches traces for efficiency
- Adds namespace and environment metadata
- Sends to MLflow OTLP endpoint (path `/v1/traces` auto-appended)
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
        endpoint: https://mlflow-route-mlflow.apps.CLUSTER_DOMAIN
        headers:
          x-mlflow-experiment-id: "4"
          x-mlflow-workspace: "moltbook"
        tls:
          insecure: false

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

### 4. MLflow Tracking Server

**OTLP Ingestion**:
- Endpoint: `https://mlflow-route-mlflow.apps.CLUSTER_DOMAIN/v1/traces`
- Accepts OTLP traces via HTTP/Protobuf
- Automatically converts spans to MLflow traces

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
| `openclaw-sidecar` | `openclaw` | OpenClaw agent traces | 100% | 100 | MLflow Experiment 4 |
| `moltbook-sidecar` | `moltbook` | Moltbook API traces | 10% | 1024 | MLflow Experiment 4 |
| `vllm-sidecar` | `demo-mlflow-agent-tracing` | vLLM inference traces (dual-export) | 100% | 100 | MLflow Experiments 2 & 4 |

**Key differences:**
- **OpenClaw**: Full sampling, optimized for LLM agent tracing with MLflow-specific attributes
- **Moltbook**: 10% sampling to reduce high-volume API trace data
- **vLLM**: Dual-pipeline export - Experiment 2 for direct vLLM calls, Experiment 4 for OpenClaw-initiated traces

### Prerequisites

1. **OpenTelemetry Operator** installed in cluster

2. **MLflow** with OTLP endpoint accessible

3. **Network connectivity** from openclaw/moltbook namespaces to MLflow route

### Deploy OTEL Collector Sidecars

**Note:** If you used `./scripts/setup.sh`, patched versions are already created in `manifests-private/observability/`!

#### Option 1: Automated Deployment (Recommended)

The setup script automatically creates and deploys sidecar configurations:

```bash
./scripts/setup.sh
# Creates patched versions in manifests-private/observability/
# - openclaw-otel-sidecar.yaml
# - moltbook-otel-sidecar.yaml
# - vllm-otel-sidecar.yaml
```

#### Option 2: Manual Deployment

Deploy each sidecar configuration from the patched versions:

```bash
# 1. Deploy OpenClaw sidecar (for openclaw namespace)
oc apply -f manifests-private/observability/openclaw-otel-sidecar.yaml

# 2. Deploy Moltbook sidecar (for moltbook namespace)
oc apply -f manifests-private/observability/moltbook-otel-sidecar.yaml

# 3. Deploy vLLM sidecar (for demo-mlflow-agent-tracing namespace)
oc apply -f manifests-private/observability/vllm-otel-sidecar.yaml
```

#### Option 3: Create Patches Manually

If you don't have `manifests-private/` created yet:

```bash
# Get your cluster domain
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

# Create patched versions
mkdir -p manifests-private/observability

for file in openclaw-otel-sidecar.yaml moltbook-otel-sidecar.yaml vllm-otel-sidecar.yaml; do
  sed "s/CLUSTER_DOMAIN/$CLUSTER_DOMAIN/g" \
    observability/$file > \
    manifests-private/observability/$file
done

# Deploy them
oc apply -f manifests-private/observability/openclaw-otel-sidecar.yaml
oc apply -f manifests-private/observability/moltbook-otel-sidecar.yaml
oc apply -f manifests-private/observability/vllm-otel-sidecar.yaml
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
  name: openclaw-gateway
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
oc apply -k manifests-private/openclaw/
oc rollout restart deployment/openclaw-gateway -n openclaw
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
oc apply -k manifests-private/moltbook/
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

**Important:** The `observability/` directory contains templates with `CLUSTER_DOMAIN` placeholders.

**Automated (recommended):**
```bash
# setup.sh automatically creates patched versions in manifests-private/
./scripts/setup.sh
```

**Manual:**
```bash
# Get your cluster domain
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

# Create patched version
mkdir -p manifests-private/observability
sed "s/CLUSTER_DOMAIN/$CLUSTER_DOMAIN/g" \
  observability/vllm-otel-sidecar.yaml > \
  manifests-private/observability/vllm-otel-sidecar.yaml

# Then deploy
oc apply -f manifests-private/observability/vllm-otel-sidecar.yaml
```

### Verify Traces in MLflow

1. Access MLflow UI: `https://mlflow-route-mlflow.apps.YOUR_CLUSTER_DOMAIN`
   - Get your cluster domain: `oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'`
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
              value: 'https://mlflow-route-mlflow.apps.YOUR_CLUSTER_DOMAIN/v1/traces'
            - name: OTEL_EXPORTER_OTLP_TRACES_HEADERS
              value: x-mlflow-experiment-id=2
            - name: OTEL_SERVICE_NAME
              value: vllm-gpt-oss-20b
            - name: OTEL_EXPORTER_OTLP_TRACES_PROTOCOL
              value: http/protobuf
```

Replace `YOUR_CLUSTER_DOMAIN` with your actual cluster domain (e.g., `ocp-prod.example.com`).

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
                --otlp-traces-endpoint https://mlflow-route-mlflow.apps.YOUR_CLUSTER_DOMAIN/v1/traces \
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

### Sidecar Not Injected

**Problem:** Pod only has one container (no `otc-container` sidecar)

**Solution:**
1. Verify the `OpenTelemetryCollector` resource exists:
   ```bash
   oc get opentelemetrycollector -n openclaw
   oc get opentelemetrycollector -n moltbook
   ```

2. Check the pod annotation is correct:
   ```bash
   oc get pod <pod-name> -n openclaw -o yaml | grep -A2 annotations
   ```
   Should show: `sidecar.opentelemetry.io/inject: "openclaw-sidecar"`

3. Verify OpenTelemetry Operator is running:
   ```bash
   oc get pods -n opentelemetry-operator-system
   ```

4. Check operator logs for errors:
   ```bash
   oc logs -n opentelemetry-operator-system -l app.kubernetes.io/name=opentelemetry-operator
   ```

### Traces Not Appearing in MLflow

**Problem:** Sidecar is injected but no traces in MLflow

**Solution:**
1. Check sidecar is receiving traces from application:
   ```bash
   oc logs -n openclaw -l app=openclaw -c otc-container
   ```
   Look for: `Trace received` or batch export messages

2. Verify MLflow endpoint is reachable from the pod:
   ```bash
   oc exec -n openclaw deployment/openclaw-gateway -c gateway -- \
     curl -v https://mlflow-route-mlflow.apps.YOUR_CLUSTER_DOMAIN/v1/traces
   ```

3. Check for TLS errors in sidecar logs:
   ```bash
   oc logs -n openclaw -l app=openclaw -c otc-container | grep -i "tls\|certificate\|error"
   ```

4. Verify the MLflow experiment ID exists:
   - Open MLflow UI
   - Check that Experiment 4 exists
   - If not, create it in the MLflow UI

### Sidecar Running Out of Memory

**Problem:** Sidecar pod shows OOMKilled status

**Solution:**
1. Check memory usage:
   ```bash
   oc adm top pods -n openclaw --containers | grep otc-container
   ```

2. Increase memory limits in the `OpenTelemetryCollector` resource:
   ```yaml
   resources:
     limits:
       memory: 512Mi  # Increase from 256Mi
   ```

3. Reduce batch size to lower memory usage:
   ```yaml
   processors:
     batch:
       send_batch_size: 50  # Reduce from 100
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
