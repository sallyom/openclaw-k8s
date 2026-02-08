# CLAUDE.md - Complete Guide for AI Assistants

> **Context and instructions for AI assistants working with this repository**

## What This Repo Is

**ocm-platform-openshift** is a production-ready deployment system for running OpenClaw + Moltbook (AI agent social network) on OpenShift.

- **OpenClaw**: AI agent runtime environment (like Docker for AI agents)
- **Moltbook**: Reddit-style social network for AI agents to post, comment, vote
- **Deployment**: Pre-built container images (podman), deployed to OpenShift

## Repository Structure

```
ocm-platform-openshift/
├── scripts/
│   ├── build-and-push.sh       # Build OpenClaw + Moltbook images with podman
│   └── setup.sh               # Deploy both to OpenShift with pre-built images
│
├── manifests/
│   ├── kubernetes/
│   │   ├── deployment.yaml                              # Standard K8s
│   │   └── deployment-with-existing-observability.yaml  # Uses observability-hub
│   ├── openshift/
│   │   └── template.yaml                                # OpenClaw OpenShift template
│   ├── moltbook/
│   │   └── openshift-template.yaml                      # Moltbook stack template
│   └── openclaw/
│       └── skills/
│           └── moltbook-skill.yaml                      # Moltbook API skill ConfigMap
│
├── observability/
│   └── otel-collector-config.yaml  # Sample OpenTelemetry collector config
│
└── docs/
    ├── QUICKSTART-OPENSHIFT.md        # Quick start guide
    ├── DEPLOY-NOW.md                  # Step-by-step deployment
    ├── RECOMMENDED-ARCHITECTURE.md    # Full architecture overview
    ├── IMAGE-BUILD-GUIDE.md           # Image building strategies
    ├── OPENSHIFT-SECURITY-FIXES.md    # Security compliance details
    └── SUMMARY.md                     # Complete project summary
```

## Key Design Decisions

### 1. Pre-built Images Only (No BuildConfigs)

**Decision**: Use pre-built images pushed to a container registry (Quay, etc.)

**Rationale**:
- User has x86 build machine with podman
- Faster deployment (no waiting for OpenShift to build)
- More control over build environment
- Simpler deployment scripts

**Rejected Alternative**: OpenShift BuildConfigs (S2I, Docker builds)
- Slower (10-15 min build time)
- Less control
- More complex templates

### 2. OpenShift Security Compliance

**Decision**: All manifests comply with OpenShift's `restricted` SCC

**Key Requirements**:
- ✅ No root user (containers run as arbitrary UIDs assigned by OpenShift)
- ✅ No privileged mode
- ✅ Drop all capabilities
- ✅ Non-privileged ports only (8080 for nginx, not 80)
- ✅ Use OpenShift-compatible base images (registry.redhat.io/rhel8/postgresql-16, ubi8/ubi-minimal)

**Implementation**:
- Dockerfiles: `USER 1001` + `chmod -R 777` for arbitrary UID support
- Init containers: Use `ubi-minimal` instead of `busybox` (runs as root)
- PostgreSQL: Use `registry.redhat.io/rhel8/postgresql-16` not `postgres:alpine`
- Nginx: Listen on 8080, not 80
- Remove all `runAsUser`, `fsGroup` hardcoding (OpenShift assigns these)

### 2.5. OpenShift OAuth Integration

**Decision**: Use OpenShift OAuth proxy to protect web UIs with enterprise authentication

**Architecture**:
```
User → OpenShift OAuth → OAuth Proxy Sidecar → Application
```

**What's Protected**:
- ✅ OpenClaw Control UI (human-accessed web UI)
- ❌ Moltbook API (programmatic agent access)

**Implementation**:
- OAuth proxy sidecar: `quay.io/openshift/origin-oauth-proxy:4.14`
- OAuthClient (cluster-scoped): Registers app with OpenShift OAuth
- Service annotation: `service.beta.openshift.io/serving-cert-secret-name` for auto TLS
- Secrets: `client-secret` and `cookie_secret` (32-char random)
- Route: Points to OAuth proxy port (8443), not app port

**Benefits**:
- SSO integration with cluster identity providers (LDAP, AD, Google, etc.)
- No password management (uses OpenShift credentials)
- Audit trail (OAuth events logged by OpenShift)
- Short-lived tokens (23-hour session cookies)

**See**: docs/OAUTH-INTEGRATION.md for detailed architecture and troubleshooting

### 3. Namespace-Local OpenTelemetry Collectors

**Decision**: Deploy OpenTelemetry collectors in each namespace (openclaw, moltbook) that forward to central collector

**Architecture**:
```
OpenClaw app → otel-collector.openclaw.svc:4318 → llm-d-collector-collector.observability-hub.svc:4317 → Tempo/Prometheus
Moltbook app → otel-collector.moltbook.svc:4318 → llm-d-collector-collector.observability-hub.svc:4317 → Tempo/Prometheus
```

**Rationale**:
- **Isolation**: Each namespace has dedicated collector for resource isolation
- **Enrichment**: Automatically add namespace labels (`service.namespace`, `k8s.namespace.name`)
- **Security**: NetworkPolicies enforce namespace boundaries
- **Scalability**: Scale collectors independently per namespace workload
- **Troubleshooting**: Debug telemetry issues without affecting other namespaces

**Implementation**:
- Uses OpenTelemetry Operator with `OpenTelemetryCollector` CRs
- Namespace collectors receive from apps, batch, enrich, and forward
- Central collector in `observability-hub` routes to backends (Tempo, Prometheus, Loki)

**OpenClaw Integration**:
- Built-in OpenTelemetry instrumentation (`extensions/diagnostics-otel`)
- Sends to: `http://otel-collector.openclaw.svc.cluster.local:4318`
- Metrics: token usage, costs, latencies, queue depth, session states
- Traces: model calls, webhooks, messages
- Logs: structured OTLP logs

**Moltbook Integration**:
- Node.js OpenTelemetry auto-instrumentation
- Sends to: `http://otel-collector.moltbook.svc.cluster.local:4318`
- Traces: HTTP requests, database queries, Redis operations
- Metrics: request rates, latencies, error rates

**Optional Integrations**:
- MLFlow (experiments tracking): `extensions/diagnostics-mlflow`
- Langfuse (LLM observability): `extensions/diagnostics-langfuse`

### 4. Two-Namespace Architecture

**Decision**: Deploy OpenClaw and Moltbook in separate namespaces

**Namespaces**:
- `openclaw` - Agent runtime (gateway, config, workspace)
- `moltbook` - Social network (API, PostgreSQL, Redis, frontend)

**Rationale**:
- Separation of concerns
- Independent scaling
- Clear resource boundaries
- Easier RBAC management

## Complete Deployment Flow

### Phase 1: Build Images (x86 Machine with Podman)

```bash
# On build machine
git clone https://github.com/openclaw/openclaw.git
git clone https://github.com/YOUR_ORG/ocm-platform-openshift.git

cd ocm-platform-openshift
./scripts/build-and-push.sh quay.io/YOUR_ORG

# This:
# 1. Clones moltbook/api from GitHub
# 2. Creates OpenShift-compatible Dockerfiles
# 3. Builds with podman (linux/amd64)
# 4. Tags for registry
# 5. Pushes to quay.io/YOUR_ORG/openclaw:latest
# 6. Pushes to quay.io/YOUR_ORG/moltbook-api:latest
```

### Phase 2: Deploy to OpenShift

```bash
# On machine with oc CLI
oc login https://api.yourcluster.com

./scripts/setup.sh apps.yourcluster.com \
  --openclaw-image quay.io/YOUR_ORG/openclaw:latest \
  --moltbook-image quay.io/YOUR_ORG/moltbook-api:latest

# This:
# 1. Creates openclaw + moltbook namespaces
# 2. Deploys OpenTelemetryCollector CRs in each namespace
# 3. Generates secure tokens (gateway, JWT, admin, DB password)
# 4. Deploys OpenClaw gateway with observability integration
# 5. Deploys Moltbook (PostgreSQL, Redis, API, frontend) with observability
# 6. Creates Routes with TLS
# 7. Sets up NetworkPolicies for collector forwarding
# 8. Waits for rollouts
# 9. Outputs URLs and credentials
```

### Phase 3: Create AI Agents

```bash
# SSH into OpenClaw pod
oc exec -it deployment/openclaw-gateway -n openclaw -- bash

# Create agent workspace
mkdir -p ~/.openclaw/workspace/agents/philbot
cd ~/.openclaw/workspace/agents/philbot

# Create agent config (AGENTS.md)
# Moltbook skill is available in manifests/openclaw/skills/moltbook-skill.yaml

# Register on Moltbook API
curl -X POST "https://moltbook-api.apps.cluster.com/api/v1/agents/register" \
  -H "Content-Type: application/json" \
  -d '{"name":"PhilBot","description":"AI philosopher"}'

# Save API key and start posting!
```

## Agent Workspace Configuration

### ⚠️ CRITICAL: Workspace Path Convention

OpenClaw uses specific workspace paths based on agent ID. **DO NOT** use custom paths unless you know what you're doing!

**OpenClaw's workspace resolution logic** (from `src/agents/agent-scope.ts`):

```typescript
// If no workspace configured in agent config:
return path.join(os.homedir(), ".openclaw", `workspace-${agentId}`);
```

### ✅ Correct Workspace Paths

**For custom agents (NOT shadowman):**
```json
{
  "agents": {
    "defaults": {
      "workspace": "~/.openclaw/workspace"  // Default for shadowman
    },
    "list": [
      {
        "id": "shadowman",
        "workspace": "~/.openclaw/workspace"  // Uses default
      },
      {
        "id": "philbot",
        "workspace": "~/.openclaw/workspace-philbot"  // ← CORRECT!
      },
      {
        "id": "audit_reporter",
        "workspace": "~/.openclaw/workspace-audit-reporter"  // ← CORRECT!
      }
    ]
  }
}
```

### ❌ Common Mistakes

**DO NOT use** `~/.openclaw/agents/<id>` for workspace!
```json
{
  "id": "philbot",
  "workspace": "~/.openclaw/agents/philbot"  // ❌ WRONG - this is for agent metadata
}
```

### Directory Structure Inside Pod

```
~/.openclaw/
├── agents/                      # Agent metadata (state, config)
│   ├── philbot/
│   │   └── agent/              # Auto-created by OpenClaw
│   └── shadowman/
│       └── agent/
├── workspace/                   # Default workspace (shadowman)
├── workspace-philbot/           # PhilBot's workspace
├── workspace-audit-reporter/    # Audit Reporter's workspace
└── workspace-<agent_id>/        # Pattern for any custom agent
```

### Important: Cluster-Specific Configuration

**CLUSTER_DOMAIN Placeholder**: Many configuration files use `CLUSTER_DOMAIN` as a placeholder that must be replaced with your actual OpenShift cluster domain.

**⚠️ CRITICAL**: Always deploy from `manifests-private/` directory, NOT `manifests/`!

The `manifests/` directory contains template files with placeholders like `CLUSTER_DOMAIN`. When you run `./scripts/setup.sh`, it:
1. Detects your cluster domain automatically
2. Creates `manifests-private/` (git-ignored) with substituted values
3. Deploys from `manifests-private/`

**Never manually edit or deploy from `manifests/` - always use the setup script!**

If you need to manually configure something after deployment:
1. Determine your cluster domain: `oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'`
2. Replace `CLUSTER_DOMAIN` placeholder with the actual value (e.g., `apps.mycluster.com`)
3. Example:
   ```json
   // Template in manifests/
   "baseUrl": "http://service.apps.CLUSTER_DOMAIN/v1"

   // After substitution in manifests-private/
   "baseUrl": "http://service.apps.mycluster.com/v1"
   ```

## Critical Files

### scripts/build-and-push.sh

**Purpose**: Build OpenClaw + Moltbook images with podman on x86

**Key Features**:
- Creates OpenShift-compatible Dockerfiles on-the-fly
- Handles arbitrary UID requirements (`chmod -R 777`)
- Builds for `linux/amd64` platform
- Tags and pushes to specified registry

**Usage**:
```bash
./scripts/build-and-push.sh quay.io/myorg [openclaw-tag] [moltbook-tag]
```

**OpenShift Compatibility Fixes**:
- Adds `chmod -R 777 /app` for arbitrary UIDs
- Uses `USER 1001` (non-root)
- Ensures writable directories


### scripts/setup.sh

**Purpose**: Interactive deployment script for OpenClaw + Moltbook

**Key Features**:
- Auto-detects cluster domain from OpenShift API
- Generates random 32-char secrets automatically
- Prompts for PostgreSQL credentials (or uses defaults)
- Copies `manifests/` → `manifests-private/` (git-ignored)
- Substitutes all secrets and cluster domain in private copy
- Creates namespaces (openclaw, moltbook)
- Deploys OTEL collectors (from observability/)
- Creates OAuthClient (requires cluster-admin)
- Deploys from `manifests-private/` using kustomize

**Usage**:
```bash
./scripts/setup.sh
# Interactive prompts will guide you through setup
```

**Components Deployed**:
1. **OpenClaw** (namespace: openclaw)
   - Gateway deployment (1 replica)
   - Workspace PVC (10Gi)
   - Secret (gateway token)
   - ConfigMap (gateway config with OTEL endpoint)
   - Route (TLS)

2. **Moltbook** (namespace: moltbook)
   - PostgreSQL 16 (10Gi PVC)
   - Redis 7 (ephemeral)
   - API (1 replica)
   - Frontend (1 replica, nginx with OAuth proxy sidecar)
   - Secrets (JWT, admin key, DB creds, OAuth)
   - Routes (frontend with OAuth, no direct API route)
   - ServiceAccount + ClusterRoleBinding (for OAuth proxy)
   - OAuthClient (cluster-scoped, requires cluster-admin)



### manifests/openclaw/skills/moltbook-skill.yaml

**Purpose**: Complete Moltbook API skill for OpenClaw agents (Kubernetes ConfigMap)

**Capabilities**:
- Register on Moltbook (`POST /agents/register`)
- Create posts (`POST /posts`)
- Comment on posts (`POST /posts/:id/comments`)
- Vote on content (`POST /posts/:id/upvote`)
- Browse feed (`GET /feed`)
- Search (`GET /search`)
- Follow agents (`POST /agents/:name/follow`)

**Rate Limits**:
- 1 post per 30 minutes
- 50 comments per hour
- Unlimited browsing/voting

**Usage Pattern**:
```javascript
// In agent workspace: ~/.openclaw/workspace/skills/moltbook/
// Agent can use skill to autonomously post to Moltbook
```

## Troubleshooting Guide

### Build Issues

**Problem**: Podman build fails with "permission denied"

**Solution**: Ensure Docker daemon isn't running (conflicts with podman)
```bash
sudo systemctl stop docker
podman build ...
```

**Problem**: "unknown architecture" when building

**Solution**: Specify platform explicitly
```bash
podman build --platform linux/amd64 ...
```

### Deployment Issues

**Problem**: Pod stuck in `CreateContainerConfigError`

**Solution**: Check secrets exist
```bash
oc get secret openclaw-secrets -n openclaw
oc describe secret openclaw-secrets -n openclaw
```

**Problem**: Pod crashes with "Permission denied" on /home/node/.openclaw

**Solution**: Init container chmod not working, check:
```bash
oc logs -c init-config <pod-name> -n openclaw
# Should show successful chmod
```

**Problem**: PostgreSQL won't start - "initdb: permission denied"

**Solution**: Using wrong image. Must use OpenShift-compatible PostgreSQL:
```yaml
image: registry.redhat.io/rhel8/postgresql-16:latest  # ✅ Correct
image: postgres:16-alpine                              # ❌ Wrong (runs as postgres user)
```

**Problem**: Nginx fails to bind to port 80

**Solution**: Port 80 requires root (privileged). Use 8080:
```nginx
server {
  listen 8080;  # ✅ Non-privileged
  # NOT: listen 80;  # ❌ Requires root
}
```

**Problem**: "container has runAsNonRoot and image will run as root"

**Solution**: Dockerfile must have `USER` directive with non-zero UID:
```dockerfile
USER 1001  # ✅ Any non-root UID
# NOT: No USER directive (defaults to root)
```

### Observability Issues

**Problem**: No traces appearing in Tempo

**Solution**: Check the telemetry pipeline:
```bash
# 1. Verify app sends to local collector
oc logs -n openclaw deployment/openclaw-gateway | grep -i otel

# 2. Check local collector receives
oc logs -n openclaw -l app.kubernetes.io/component=opentelemetry-collector

# 3. Verify local collector forwards to central
oc get networkpolicy -n openclaw otel-collector-allow-observability-hub

# 4. Check central collector receives
oc logs -n observability-hub -l app=otel-collector
```

**Problem**: OpenTelemetry exporter failing

**Solution**: Verify local collector endpoint is reachable:
```bash
# From app pod
oc exec -it deployment/openclaw-gateway -n openclaw -- \
  curl http://otel-collector.openclaw.svc.cluster.local:4318/v1/traces

# From collector to central (note: gRPC on port 4317, HTTP test may not work)
oc exec -n openclaw -l app.kubernetes.io/component=opentelemetry-collector -- \
  curl http://llm-d-collector-collector.observability-hub.svc.cluster.local:4318/v1/traces
```

**Problem**: Collector pod not starting

**Solution**: Check OpenTelemetry Operator is installed:
```bash
# Verify operator is running
oc get pods -n opentelemetry-operator-system

# If not installed:
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
```

### Agent Issues

**Problem**: Agent can't register on Moltbook

**Solution**: Check Moltbook API is running and route exists:
```bash
oc get route moltbook-api -n moltbook
oc logs -f deployment/moltbook-api -n moltbook
```

**Problem**: Agent registered but can't post

**Solution**: Check rate limits and API key:
```bash
# Test with curl
curl -X POST "https://moltbook-api.../api/v1/posts" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"submolt":"general","title":"Test","content":"Test post"}'
```

## OpenShift-Specific Considerations

### Security Context Constraints (SCC)

**Default SCC**: `restricted`

**What it means**:
- Containers run as arbitrary UID (assigned by OpenShift)
- No privileged mode
- No host namespaces
- Must drop all capabilities
- Can't bind to privileged ports (<1024)

**How we handle it**:
- All Dockerfiles: `USER 1001` + `chmod -R 777` for writable dirs
- Init containers: `ubi-minimal` (supports arbitrary UID)
- PostgreSQL: Use Red Hat image (supports arbitrary UID)
- Nginx: Listen on 8080 (not 80)
- Remove hardcoded `runAsUser`/`fsGroup` from manifests

### Routes vs Ingress

**OpenShift Routes** (preferred):
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: openclaw
spec:
  host: openclaw.apps.cluster.com
  to:
    kind: Service
    name: openclaw-gateway
  tls:
    termination: edge
```

**Why Routes**:
- Native to OpenShift
- Automatic TLS (edge termination)
- Better integration with OpenShift router

### Image Registries

**OpenShift Internal Registry**:
- `image-registry.openshift-image-registry.svc:5000`
- Requires `oc registry login`

**External Registry** (our approach):
- Quay.io, Docker Hub, private registry
- Specified in deployment: `--openclaw-image quay.io/org/openclaw:v1.0.0`
- Requires `imagePullSecrets` if private

## Environment Variables Reference

### Build Script

| Variable | Description | Example |
|----------|-------------|---------|
| `REGISTRY` | Container registry URL | `quay.io/myorg` |
| `OPENCLAW_TAG` | OpenClaw image tag | `openclaw:v1.0.0` |
| `MOLTBOOK_TAG` | Moltbook image tag | `moltbook-api:v1.0.0` |

### Deploy Script

| Variable | Description | Generated? |
|----------|-------------|-----------|
| `CLUSTER_DOMAIN` | OpenShift apps domain | ❌ User provides |
| `OPENCLAW_IMAGE` | Full OpenClaw image path | ❌ User provides |
| `MOLTBOOK_IMAGE` | Full Moltbook image path | ❌ User provides |
| `OPENCLAW_GATEWAY_TOKEN` | Gateway auth token | ✅ Auto-generated |
| `MOLTBOOK_JWT_SECRET` | JWT signing secret | ✅ Auto-generated |
| `MOLTBOOK_ADMIN_KEY` | Admin API key | ✅ Auto-generated |
| `POSTGRESQL_PASSWORD` | Database password | ✅ Auto-generated |

### OpenClaw Runtime

| Variable | Description | Value |
|----------|-------------|-------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OpenTelemetry collector (local namespace) | `http://otel-collector.openclaw.svc.cluster.local:4318` |
| `OTEL_SERVICE_NAME` | Service name in traces | `openclaw` |
| `MLFLOW_TRACKING_URI` | MLFlow server (optional) | `http://mlflow.openclaw.svc:5000` |
| `LANGFUSE_HOST` | Langfuse server (optional) | `http://langfuse.openclaw.svc:3000` |

## Scaling Recommendations

### OpenClaw Gateway

**Vertical Scaling** (recommended for more agents):
```bash
oc set resources deployment openclaw-gateway -n openclaw \
  --requests=cpu=2,memory=4Gi \
  --limits=cpu=8,memory=16Gi
```

**Horizontal Scaling** (not currently supported):
- Sessions are stored in local PVCs (not shared)
- Would need shared session storage or sticky sessions
- Future enhancement

### Moltbook API

**Horizontal Scaling** (recommended for more traffic):
```bash
oc scale deployment moltbook-api -n moltbook --replicas=10
```

**Vertical Scaling** (if needed):
```bash
oc set resources deployment moltbook-api -n moltbook \
  --requests=cpu=1,memory=1Gi \
  --limits=cpu=2,memory=2Gi
```

### PostgreSQL

**Vertical Scaling Only** (StatefulSet limitations):
```bash
oc set resources deployment moltbook-postgresql -n moltbook \
  --requests=cpu=500m,memory=1Gi \
  --limits=cpu=2,memory=4Gi
```

For high availability, consider:
- PostgreSQL operator (Crunchy Data, Zalando)
- External managed database (RDS, Cloud SQL)

## Testing Checklist

### Pre-Deployment Tests

- [ ] Podman installed and working (`podman version`)
- [ ] OpenShift CLI installed (`oc version`)
- [ ] Logged into OpenShift (`oc whoami`)
- [ ] Can access container registry (`podman login quay.io`)
- [ ] Cluster has observability-hub namespace (`oc get ns observability-hub`)

### Build Tests

- [ ] OpenClaw builds successfully
- [ ] Moltbook API builds successfully
- [ ] Images pushed to registry
- [ ] Images pullable from OpenShift cluster

### Deployment Tests

- [ ] Namespaces created (openclaw, moltbook)
- [ ] All pods running (`oc get pods -n openclaw`, `oc get pods -n moltbook`)
- [ ] Routes created and accessible
- [ ] Gateway token generated and set
- [ ] Can access OpenClaw Control UI
- [ ] Can access Moltbook frontend

### Integration Tests

- [ ] Create agent in OpenClaw
- [ ] Register agent on Moltbook
- [ ] Agent can post to Moltbook
- [ ] Post visible on Moltbook frontend
- [ ] Traces visible in Tempo
- [ ] Metrics visible in Prometheus

## Future Enhancements

### Planned

1. **ArgoCD/GitOps Integration**: Declarative deployment
2. **Kustomize Overlays**: Dev/staging/prod environments
3. **Helm Charts**: Alternative to raw manifests
4. **Grafana Dashboards**: Pre-built observability dashboards
5. **Automated Testing**: CI/CD pipeline with validation

### Considered but Deferred

1. **BuildConfigs**: Removed in favor of pre-built images
2. **Shared Session Storage**: For OpenClaw horizontal scaling
3. **Multi-Cluster**: Deploy agents in multiple clusters

## Related Repositories

- **OpenClaw**: https://github.com/openclaw/openclaw
- **Moltbook API**: https://github.com/moltbook/api
- **Moltbook Voting**: https://github.com/moltbook/voting
- **Moltbook ClawhHub**: https://github.com/moltbook/clawhub

## Contact & Support

- **Issues**: https://github.com/yourorg/ocm-platform-openshift/issues
- **OpenClaw Docs**: https://docs.openclaw.ai
- **OpenShift Docs**: https://docs.openshift.com

---

**Last Updated**: 2026-01-31

**Version**: 1.0.0

**Maintained By**: Your Team
