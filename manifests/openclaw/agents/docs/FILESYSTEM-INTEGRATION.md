# OpenClaw UI Filesystem Integration - Analysis & Fixes

> **Date**: 2026-02-09
> **Context**: Running OpenClaw on OpenShift/K8s with custom agents (philbot, audit-reporter, resource-optimizer, mlops-monitor)

## Issues Discovered

### 1. Reports Directories Not Visible in Files Tab

**Expected**: Files tab would show `reports/` directories in agent workspaces
**Actual**: Files tab only shows specific configuration files

**Root Cause**: The Files tab is intentionally limited to editing agent configuration files only.

**Code Location**: `/openclaw/src/gateway/server-methods/agents.ts`

```typescript
const ALLOWED_FILE_NAMES = new Set<string>([
  "AGENTS.md",      // Agent discovery/routing
  "SOUL.md",        // Agent personality/values
  "TOOLS.md",       // Tool guidance
  "IDENTITY.md",    // Agent identity metadata
  "USER.md",        // User context
  "HEARTBEAT.md",   // Monitoring instructions
  "BOOTSTRAP.md",   // General bootstrap
  "MEMORY.md",      // Primary memory
  "memory.md"       // Alternative memory
]);
```

**Why**: Security and UX design decision. The UI is focused on agent configuration, not arbitrary file browsing.

**Status**: ✅ **Not a bug** - working as designed

**Workaround**: Access reports via `oc exec`:
```bash
# List reports for audit-reporter
oc exec -n openclaw deployment/openclaw -c gateway -- \
  ls -lh ~/.openclaw/workspace-audit-reporter/reports/

# Read latest report
oc exec -n openclaw deployment/openclaw -c gateway -- \
  cat ~/.openclaw/workspace-audit-reporter/reports/latest.md
```

---

### 2. Usage View Empty (No Session Data)

**Expected**: Usage view would show agent activity, token usage, costs
**Actual**: Usage view was empty for custom agents

**Root Cause**: Missing session directories for custom agents.

**How Usage View Works**:
- Data source: Session transcript JSONL files
- Location: `~/.openclaw/agents/{agentId}/sessions/*.jsonl`
- Metadata: `~/.openclaw/agents/{agentId}/sessions/sessions.json`

**Code Location**: `/openclaw/src/gateway/server-methods/usage.ts`

The Usage view:
1. Scans `~/.openclaw/agents/{agentId}/sessions/` for `.jsonl` files
2. Parses each JSONL file to extract token counts, costs, model usage
3. Loads metadata from `sessions.json` for named sessions
4. Displays aggregated stats in the UI

**Problem**: Init container only created session directory for `shadowman`:
```bash
mkdir -p /home/node/.openclaw/agents/shadowman/sessions  # ✅
# Missing directories for philbot, audit_reporter, etc.
```

**Status**: ✅ **FIXED** (see below)

---

## Fixes Applied

### Fix 1: Updated `setup-agent-workspaces.sh`

**File**: `manifests/openclaw/agents/setup-agent-workspaces.sh`

**Changes**:
```bash
# Added session directory creation
mkdir -p ~/.openclaw/agents/philbot/sessions
mkdir -p ~/.openclaw/agents/audit_reporter/sessions
mkdir -p ~/.openclaw/agents/resource_optimizer/sessions
mkdir -p ~/.openclaw/agents/mlops_monitor/sessions

# Added permissions for agents directory
chmod -R 775 ~/.openclaw/agents
```

**When to run**: After deploying agents to existing OpenClaw instance

---

### Fix 2: Updated Deployment Init Container

**File**: `manifests/openclaw/base/openclaw-deployment.yaml`

**Changes**:
```bash
# Create session directories for add-on agents
mkdir -p /home/node/.openclaw/agents/philbot/sessions
mkdir -p /home/node/.openclaw/agents/audit_reporter/sessions
mkdir -p /home/node/.openclaw/agents/resource_optimizer/sessions
mkdir -p /home/node/.openclaw/agents/mlops_monitor/sessions
```

**When to run**: Fresh deployments or redeployments of OpenClaw

---

## Directory Structure (After Fixes)

```
~/.openclaw/
├── agents/                              # Agent metadata and session transcripts
│   ├── shadowman/
│   │   ├── agent/                       # Agent state
│   │   └── sessions/                    # Session transcripts ← Used by Usage view
│   │       ├── {sessionId}.jsonl
│   │       └── sessions.json
│   ├── philbot/
│   │   └── sessions/                    # ← FIXED: Now created
│   ├── audit_reporter/
│   │   └── sessions/                    # ← FIXED: Now created
│   ├── resource_optimizer/
│   │   └── sessions/                    # ← FIXED: Now created
│   └── mlops_monitor/
│       └── sessions/                    # ← FIXED: Now created
│
├── workspace/                           # Default agent (shadowman) workspace
│   ├── AGENTS.md
│   └── agent.json
│
├── workspace-philbot/                   # PhilBot workspace
│
├── workspace-audit-reporter/            # Audit Reporter workspace
│   └── reports/                         # Reports saved here
│       ├── 2026-02-09-1400-compliance-report.md
│       └── latest.md -> 2026-02-09-1400-compliance-report.md
│
├── workspace-resource-optimizer/        # Resource Optimizer workspace
│   └── reports/
│       ├── 2026-02-09-0800-cost-report.md
│       └── latest.md
│
└── workspace-mlops-monitor/             # MLOps Monitor workspace
    └── reports/
        ├── 2026-02-09-1200-mlops-report.md
        └── latest.md
```

---

## Volume Mount Configuration (✅ Already Correct)

**Deployment**: `manifests/openclaw/base/openclaw-deployment.yaml`

```yaml
volumeMounts:
- name: openclaw-home
  mountPath: /home/node/.openclaw        # ✅ Correct

volumes:
- name: openclaw-home
  persistentVolumeClaim:
    claimName: openclaw-home-pvc         # ✅ 20Gi RWO - sufficient
```

**Storage**: ReadWriteOnce (RWO) is correct for single-pod deployment.

**Size**: 20Gi is sufficient for session transcripts and reports.

---

## Verification Steps

### 1. Verify Session Directories Exist

```bash
POD=$(oc get pods -n openclaw -l app=openclaw -o jsonpath='{.items[0].metadata.name}')

oc exec -n openclaw $POD -c gateway -- ls -la ~/.openclaw/agents/
```

**Expected output**:
```
drwxrwxr-x  philbot
drwxrwxr-x  audit_reporter
drwxrwxr-x  resource_optimizer
drwxrwxr-x  mlops_monitor
drwxrwxr-x  shadowman
```

### 2. Verify Session Files Created After Agent Runs

```bash
# After a cron job runs
oc exec -n openclaw $POD -c gateway -- \
  ls -lh ~/.openclaw/agents/audit_reporter/sessions/
```

**Expected**: `.jsonl` files appear after agents execute tasks

### 3. Check Usage View in UI

1. Navigate to OpenClaw UI
2. Click "Usage" tab
3. Select an agent from dropdown (philbot, audit_reporter, etc.)
4. **Expected**: See session data, token counts, costs

---

## Future Enhancements (Optional)

### Option 1: Custom File Browser UI

**Goal**: Add a file browser to view arbitrary files in agent workspaces

**Implementation**:
1. Add new API endpoint: `agents.files.browse`
2. Add UI component: File tree view
3. Security: Restrict to agent workspace only

**Effort**: ~2-3 days of development

---

### Option 2: Reports API Endpoint

**Goal**: Expose reports via API without `oc exec`

**Implementation**:
```typescript
// New endpoint: agents.reports.list
export async function listAgentReports(agentId: string) {
  const workspace = resolveAgentWorkspaceDir(cfg, agentId);
  const reportsDir = path.join(workspace, 'reports');
  const files = await fs.readdir(reportsDir);
  return files.filter(f => f.endsWith('.md'));
}

// New endpoint: agents.reports.get
export async function getAgentReport(agentId: string, filename: string) {
  const workspace = resolveAgentWorkspaceDir(cfg, agentId);
  const reportPath = path.join(workspace, 'reports', filename);
  return fs.readFile(reportPath, 'utf-8');
}
```

**UI**:
- Add "Reports" tab to agent view
- List reports with timestamps
- Click to view report content

**Effort**: ~1 day of development

---

### Option 3: Integrate Reports into Moltbook

**Goal**: Post report summaries to Moltbook, link to full reports

**Current State**: ✅ **Already implemented!**

Agents are configured to:
1. Save full report to workspace: `~/.openclaw/workspace-{agent}/reports/`
2. Post short summary to Moltbook with link to full report

**Example** (from audit-reporter cron job):
```bash
# STEP 4: Create detailed report in workspace
cat > ~/.openclaw/workspace-audit-reporter/reports/${TIMESTAMP}-report.md

# STEP 5: Use moltbook skill to post SHORT announcement
# Posts to Moltbook with link: "Full report: ~/.openclaw/workspace-audit-reporter/reports/latest.md"
```

**Access full reports**:
```bash
oc exec -n openclaw deployment/openclaw -c gateway -- \
  cat ~/.openclaw/workspace-audit-reporter/reports/latest.md
```

---

## Summary

| Issue | Root Cause | Status | Fix |
|-------|-----------|--------|-----|
| Reports dirs not in Files tab | By design (security) | ✅ Not a bug | Use `oc exec` or build custom UI |
| Usage view empty | Missing session directories | ✅ Fixed | Updated init container + setup script |
| Volume mount issues | N/A | ✅ Already correct | No changes needed |

**Next Steps**:
1. ✅ Run `setup-agent-workspaces.sh` on existing deployment
2. ✅ Apply updated deployment manifest for future deployments
3. Wait for cron jobs to execute and verify session transcripts appear
4. Check Usage view in UI to confirm session data is visible

**Optional**:
- Build custom file browser UI (if needed)
- Build reports API endpoint (if needed)
