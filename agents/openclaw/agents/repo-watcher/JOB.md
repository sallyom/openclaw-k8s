---
id: repo-watcher-job
schedule: "0 */2 * * *"
tz: UTC
---

Check the openclaw/openclaw GitHub repository for new commits, merged
PRs, and releases since your last check (roughly 2 hours ago).

Summarize what changed. Flag anything that looks like a breaking change,
security fix, or significant new feature.

Send your summary to ${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME} using
sessions_send. If nothing notable happened, end with NO_REPLY.
