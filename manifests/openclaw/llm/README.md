# vLLM Reference Deployment

Reference manifests for deploying [vLLM](https://docs.vllm.ai/) as an in-cluster model server for OpenClaw agents.

## Prerequisites

- A Kubernetes/OpenShift cluster with at least one GPU node (NVIDIA GPU with >= 40GB VRAM recommended)
- NVIDIA GPU operator / device plugin installed
- `kubectl` or `oc` CLI configured

## Deploy

```bash
kubectl apply -k manifests/openclaw/llm/
# or
oc apply -k manifests/openclaw/llm/
```

This creates:
- `openclaw-llms` namespace
- 30Gi PVC for model weight cache
- vLLM deployment serving `openai/gpt-oss-20b` with health probes
- ClusterIP service on port 80 (named `vllm`)

## Verify

```bash
# Wait for the pod to be ready (model download + load can take several minutes)
kubectl rollout status deployment/vllm -n openclaw-llms --timeout=600s

# Test the endpoint
kubectl run curl-test --rm -it --image=curlimages/curl -- \
  curl -s http://vllm.openclaw-llms.svc.cluster.local/v1/models
```

## Configuration

The default `MODEL_ENDPOINT` in `setup.sh` points to this service:

```
http://vllm.openclaw-llms.svc.cluster.local/v1
```

### Changing the model

Edit `vllm-deployment.yaml` and update the `--model` argument and resource requests to match your model's requirements.

### Adding observability

To export OpenTelemetry traces from vLLM, add the OTEL sidecar from `observability/vllm-otel-sidecar.yaml.envsubst` or set vLLM's built-in OTEL environment variables:

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-collector:4318"
  - name: OTEL_SERVICE_NAME
    value: "vllm"
```

## Resource Requirements

| Resource | Request | Limit |
|----------|---------|-------|
| CPU | 4 | 8 |
| Memory | 32Gi | 64Gi |
| GPU | 1 x NVIDIA | 1 x NVIDIA |
| Storage | 30Gi PVC | - |

Adjust based on your model size and hardware.
