# How to Deploy Symphony

This guide covers end-to-end setup for running Symphony in production on AWS, with ClickUp as the
tracker backend, GitHub as the source host, and Codex as the coding agent.

For Linear setup, the same steps apply with the noted differences.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [ClickUp Setup](#2-clickup-setup)
3. [GitHub Setup](#3-github-setup)
4. [AWS Infrastructure](#4-aws-infrastructure)
5. [WORKFLOW.md Configuration](#5-workflowmd-configuration)
6. [Running the Service](#6-running-the-service)
7. [Verification Checklist](#7-verification-checklist)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Prerequisites

| Dependency | Version | Notes |
|------------|---------|-------|
| Elixir | 1.19+ (OTP 28) | Use [mise](https://mise.jdx.dev/) to manage versions |
| Git | 2.x+ | Workspace cloning in hooks |
| Codex CLI | Latest | `codex app-server` must be available on `$PATH` |
| OpenAI API key | — | Required by Codex; set `OPENAI_API_KEY` in the environment |

### Is this already covered in the codebase?

**Yes.** `elixir/README.md` documents Elixir/mise setup and basic run instructions.
The `SPEC.md` Section 3.3 lists external dependencies. The `.codex/worktree_init.sh` script
automates the Elixir build setup.

---

## 2. ClickUp Setup

### 2.1 Create a ClickUp API Token

1. Go to **ClickUp → Settings → Apps → API Token** (or use an OAuth integration).
2. Generate a personal API token.
3. Save it securely — you'll set it as `CLICKUP_API_KEY` on the deployment host.

> **Rate limits:** 100 requests/minute per token. If running multiple Symphony instances, use
> separate tokens or accept shared budget. See `docs/references/clickup-api.md`.

### 2.2 Identify Your List ID

Symphony polls a single ClickUp **List** for candidate tasks.

1. Open the target List in ClickUp.
2. The List ID is in the URL: `https://app.clickup.com/{workspace_id}/v/li/{list_id}`
   — or use the ClickUp API: `GET /team/{team_id}/space` → `GET /space/{space_id}/folder` →
   `GET /folder/{folder_id}/list`.
3. Record the List ID — you'll set it as `tracker.list_id` in `WORKFLOW.md`.

### 2.3 Configure Task Statuses

Symphony uses `active_states` and `terminal_states` to decide which tasks to pick up and which
to ignore or clean up.

**Defaults (if not overridden in `WORKFLOW.md`):**
- Active: `Todo`, `In Progress`
- Terminal: `Closed`, `Cancelled`, `Canceled`, `Duplicate`, `Done`

**If your ClickUp space uses custom statuses** (e.g., `Rework`, `Human Review`, `Merging`),
add them to `active_states` in `WORKFLOW.md`. Status comparison is case-insensitive.

### 2.4 (Optional) Configure Assignee Routing

If you run multiple Symphony instances against the same ClickUp List, set either:

- `tracker.assignee` in `WORKFLOW.md`, or
- `CLICKUP_ASSIGNEE` in the host environment

Use the ClickUp user ID (for example `12345`), not the username. When configured, Symphony marks
only tasks assigned to that user as routable to the current worker. Unassigned tasks and tasks
assigned to other users remain visible in tracker reads but are not dispatched by the orchestrator.

### 2.5 (Optional) Enable Custom Task IDs

If your ClickUp workspace has **Custom Task IDs** enabled (e.g., `PROJ-42`), Symphony will use
them as the human-readable `identifier`. Otherwise, the internal ClickUp task ID is used.

### 2.5 ClickUp vs. Linear — Key Differences

| Concern | ClickUp | Linear |
|---------|---------|--------|
| Config key | `tracker.list_id` | `tracker.project_slug` |
| Env var for API key | `CLICKUP_API_KEY` | `LINEAR_API_KEY` |
| Env var for assignee filter | `CLICKUP_ASSIGNEE` | `LINEAR_ASSIGNEE` |
| Agent tool | `clickup_api` (REST) | `linear_graphql` (GraphQL) |
| Status update | `PUT /task/{id}` with name | Resolve `stateId` + mutation |
| Branch name | Not available | Native field |

### Is this already covered in the codebase?

**Partially.** `elixir/README.md` has a brief "How to use it" section covering ClickUp config
keys. `docs/references/clickup-api.md` has the full API reference. `.codex/skills/clickup/SKILL.md`
documents the agent-side tool. What's **not documented** elsewhere is the step-by-step token
creation and List ID discovery process above.

---

## 3. GitHub Setup

### 3.1 Repository Secrets

Set these as GitHub Actions secrets (Settings → Secrets and variables → Actions) if you use
CI/CD, or as environment variables on your deployment host:

| Secret | Required | Purpose |
|--------|----------|---------|
| `CLICKUP_API_KEY` | Yes | ClickUp API token for Symphony tracker polling |
| `OPENAI_API_KEY` | Yes | OpenAI API key for Codex agent sessions |
| `CLICKUP_ASSIGNEE` | No | Filter tasks so only issues assigned to this ClickUp user ID are routed to this Symphony instance |

For Linear instead:

| Secret | Required | Purpose |
|--------|----------|---------|
| `LINEAR_API_KEY` | Yes | Linear API key |
| `LINEAR_ASSIGNEE` | No | Filter tasks by assignee |

### 3.2 GitHub Actions Workflows (Already in Repo)

The repository includes two CI workflows in `.github/workflows/`:

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `make-all.yml` | Push to `main`, PRs | Runs `make all` (format, lint, coverage, dialyzer) |
| `pr-description-lint.yml` | PR open/edit | Validates PR body against template |

**No additional GitHub Actions config is needed** for the Symphony service itself — it runs as a
long-lived process, not as a CI job.

### 3.3 Repository Access for Workspaces

Symphony clones your repo into per-issue workspace directories. The deployment host needs
Git access to your repository.

**Options:**
- **SSH key:** Add a deploy key (read-only is sufficient for most workflows; read-write if agents
  need to push branches/PRs).
- **Personal access token:** Use `https://` clone URLs with a PAT.
- **GitHub App:** For org-level access with fine-grained permissions.

Configure the clone command in `WORKFLOW.md` `hooks.after_create`:

```yaml
hooks:
  after_create: |
    git clone --depth 1 git@github.com:your-org/your-repo.git .
```

Or with HTTPS + PAT:

```yaml
hooks:
  after_create: |
    git clone --depth 1 https://${GITHUB_TOKEN}@github.com/your-org/your-repo.git .
```

### 3.4 GitHub CLI (`gh`) for PR Operations

If your workflow prompt instructs the agent to create PRs and manage reviews (as the default
`WORKFLOW.md` does), the deployment host also needs:

- `gh` CLI installed and authenticated (`gh auth login`), **or**
- `GITHUB_TOKEN` set in the environment with `repo` scope.

### Is this already covered in the codebase?

**Partially.** `elixir/README.md` mentions setting env vars and the hook clone pattern.
`.github/workflows/` contains the CI definitions. What's **not documented** elsewhere is the
explicit secrets list, deploy key setup, and `gh` CLI requirement for agent PR operations.

---

## 4. AWS Infrastructure

Symphony is a single long-running Elixir process. It does not require containers, Kubernetes,
or managed services beyond a compute instance and filesystem.

### 4.1 Minimal Architecture

```
┌─────────────────────────────────────────────┐
│  EC2 Instance (or ECS Task)                 │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │  Symphony (Elixir BEAM)             │    │
│  │  - Polls ClickUp every N seconds    │    │
│  │  - Spawns Codex subprocesses        │    │
│  │  - Manages workspace dirs on disk   │    │
│  └──────────┬──────────────────────────┘    │
│             │                               │
│  ┌──────────▼──────────────────────────┐    │
│  │  EBS Volume (workspace root)        │    │
│  │  ~/code/workspaces/<issue-id>/      │    │
│  └─────────────────────────────────────┘    │
│                                             │
│  Env vars:                                  │
│    CLICKUP_API_KEY, OPENAI_API_KEY,         │
│    GITHUB_TOKEN (optional)                  │
└─────────────────────────────────────────────┘
         │                    │
         ▼                    ▼
   ClickUp API          OpenAI API
   (polling +           (Codex agent
    tool calls)          sessions)
```

### 4.2 Compute Requirements

| Resource | Recommendation | Notes |
|----------|---------------|-------|
| Instance type | `t3.medium` or larger | 2 vCPUs, 4GB RAM minimum; scale up with `max_concurrent_agents` |
| Disk | 50GB+ EBS gp3 | Each workspace is a full repo clone; size depends on repo |
| OS | Amazon Linux 2023 or Ubuntu 22.04+ | Needs `bash`, `git`, `mise` (or manual Elixir install) |
| Network | Outbound HTTPS to ClickUp, OpenAI, GitHub | No inbound ports required unless using the dashboard |

### 4.3 Instance Setup

```bash
# 1. Install mise (manages Elixir/Erlang)
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
source ~/.bashrc

# 2. Clone Symphony
git clone https://github.com/your-org/symphony.git
cd symphony/elixir

# 3. Install Elixir/Erlang via mise
mise trust
mise install

# 4. Build
mise exec -- mix setup
mise exec -- mix build

# 5. Set environment variables
export CLICKUP_API_KEY="ck_your_token_here"
export OPENAI_API_KEY="sk-your_openai_key_here"
export GITHUB_TOKEN="ghp_your_token_here"  # optional, for PR operations

# 6. Copy and customize WORKFLOW.md for your project
cp WORKFLOW.md /path/to/your/workflow.md
# Edit: set tracker.kind, tracker.list_id, hooks.after_create, workspace.root, etc.

# 7. Run
mise exec -- ./bin/symphony /path/to/your/workflow.md
```

### 4.4 Running as a Systemd Service

Create `/etc/systemd/system/symphony.service`:

```ini
[Unit]
Description=Symphony Agent Orchestrator
After=network.target

[Service]
Type=simple
User=symphony
WorkingDirectory=/opt/symphony/elixir
Environment=CLICKUP_API_KEY=ck_your_token
Environment=OPENAI_API_KEY=sk-your_key
Environment=GITHUB_TOKEN=ghp_your_token
ExecStart=/opt/symphony/elixir/bin/symphony /opt/symphony/workflow.md --port 4000
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable symphony
sudo systemctl start symphony
```

### 4.5 Dashboard Access (Optional)

If you pass `--port 4000`, Symphony starts a Phoenix LiveView dashboard:

- **Dashboard:** `http://<instance-ip>:4000/`
- **JSON API:** `http://<instance-ip>:4000/api/v1/state`

To expose this, either:
- Open port 4000 in the instance's security group (restrict to your IP/VPN), or
- Put an ALB or SSH tunnel in front of it.

### 4.6 Logs

Symphony writes structured logs to stdout/stderr (captured by systemd journal) and optionally
to `./log/` (configurable via `--logs-root`).

```bash
# View live logs
journalctl -u symphony -f

# Or if using --logs-root
tail -f /opt/symphony/log/*.log
```

### 4.7 AWS Secrets Manager (Recommended for Production)

Instead of hardcoding secrets in the systemd unit file, use AWS Secrets Manager or SSM
Parameter Store:

```bash
# In the systemd ExecStartPre or a wrapper script:
export CLICKUP_API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id symphony/clickup-api-key \
  --query SecretString --output text)
export OPENAI_API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id symphony/openai-api-key \
  --query SecretString --output text)
```

### Is this already covered in the codebase?

**No.** The codebase documents local development setup (`elixir/README.md`) and the service
specification (`SPEC.md`), but does not include AWS deployment guidance, systemd configuration,
or production secrets management. This section is new.

---

## 5. WORKFLOW.md Configuration

### 5.1 Minimal ClickUp Example

```yaml
---
tracker:
  kind: clickup
  list_id: "900200100123"
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Closed
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 5
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a tracker issue {{ issue.identifier }}.

Title: {{ issue.title }}
Description: {{ issue.description }}
```

### 5.2 Production ClickUp Example (with custom statuses)

```yaml
---
tracker:
  kind: clickup
  list_id: "900200100123"
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 10000
workspace:
  root: /data/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://${GITHUB_TOKEN}@github.com/your-org/your-repo.git .
    if command -v mise >/dev/null 2>&1; then
      mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
  max_retry_backoff_ms: 300000
codex:
  command: codex --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
server:
  port: 4000
---

You are working on a tracker ticket `{{ issue.identifier }}`

{% if attempt %}
This is retry attempt #{{ attempt }}. Resume from the current workspace state.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}
```

### 5.3 Linear Example (for reference)

```yaml
---
tracker:
  kind: linear
  project_slug: "my-project-abc123"
  active_states:
    - Todo
    - In Progress
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:your-org/your-repo.git .
codex:
  command: codex app-server
---

You are working on {{ issue.identifier }}: {{ issue.title }}
```

### Is this already covered in the codebase?

**Yes.** `elixir/README.md` has a configuration section with examples and field documentation.
`SPEC.md` Section 5 has the full front matter schema. This section adds ClickUp-specific
production examples that weren't in the existing docs.

---

## 6. Running the Service

### 6.1 Local Development

```bash
cd symphony/elixir
mise exec -- ./bin/symphony ./WORKFLOW.md
```

### 6.2 With Dashboard

```bash
mise exec -- ./bin/symphony ./WORKFLOW.md --port 4000
```

### 6.3 Production (systemd)

See [Section 4.4](#44-running-as-a-systemd-service).

### 6.4 Docker (Alternative)

Symphony doesn't ship a Dockerfile, but the build is straightforward:

```dockerfile
FROM hexpm/elixir:1.19.5-erlang-28.3.3-alpine-3.21.3

WORKDIR /app
COPY elixir/ ./
RUN mix setup && mix build

ENV CLICKUP_API_KEY=""
ENV OPENAI_API_KEY=""

ENTRYPOINT ["./bin/symphony"]
CMD ["/app/WORKFLOW.md", "--port", "4000"]
```

### Is this already covered in the codebase?

**Mostly.** `elixir/README.md` covers local run and CLI flags. Docker and systemd are new.

---

## 7. Verification Checklist

After deployment, verify each layer:

- [ ] **Elixir runtime:** `./bin/symphony --help` runs without errors
- [ ] **ClickUp auth:** Service logs show successful tracker poll (no `missing_tracker_api_token`)
- [ ] **List ID:** Service finds tasks (no `missing_tracker_project_id`)
- [ ] **Git clone:** First task triggers workspace creation and `after_create` hook succeeds
- [ ] **Codex:** Agent session starts (check logs for `session_started`)
- [ ] **Dashboard:** (if `--port` set) `http://<host>:4000/` shows running sessions
- [ ] **Logs:** Structured logs include `issue_id=` and `issue_identifier=` fields

---

## 8. Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `missing_tracker_api_token` | `CLICKUP_API_KEY` not set | Set env var or `tracker.api_key` in WORKFLOW.md |
| `missing_tracker_project_id` | `tracker.list_id` not set | Add `list_id` to WORKFLOW.md tracker section |
| `unsupported_tracker_kind` | `tracker.kind` missing or typo | Must be `clickup` or `linear` |
| No tasks picked up | Status mismatch | Verify `active_states` match your ClickUp status names (case-insensitive) |
| `codex_not_found` | `codex` not on PATH | Install Codex CLI or set full path in `codex.command` |
| Hook timeout | Slow clone or deps install | Increase `hooks.timeout_ms` (default 60s) |
| Rate limit (429) | Too many ClickUp API calls | Reduce `max_concurrent_agents` or increase `polling.interval_ms` |
| Workspace path error | Path traversal safety check | Ensure `workspace.root` is an absolute path |

---

## Summary: What Was Already in the Codebase vs. What's New

| Topic | Already Documented | Where |
|-------|--------------------|-------|
| Elixir setup & run | ✅ | `elixir/README.md` |
| WORKFLOW.md schema | ✅ | `elixir/README.md`, `SPEC.md` §5 |
| ClickUp API reference | ✅ | `docs/references/clickup-api.md` |
| ClickUp agent skill | ✅ | `.codex/skills/clickup/SKILL.md` |
| Linear agent skill | ✅ | `.codex/skills/linear/SKILL.md` |
| Architecture overview | ✅ | `ARCHITECTURE.md` |
| CI workflows | ✅ | `.github/workflows/` |
| ClickUp token creation steps | ❌ New | This guide, §2.1 |
| ClickUp List ID discovery | ❌ New | This guide, §2.2 |
| GitHub secrets & deploy keys | ❌ New | This guide, §3.1, §3.3 |
| AWS infrastructure & sizing | ❌ New | This guide, §4 |
| Systemd service config | ❌ New | This guide, §4.4 |
| Docker alternative | ❌ New | This guide, §6.4 |
| AWS Secrets Manager | ❌ New | This guide, §4.7 |
| Production WORKFLOW.md examples | ❌ New | This guide, §5.2 |
| Verification checklist | ❌ New | This guide, §7 |
| Troubleshooting table | ❌ New | This guide, §8 |
