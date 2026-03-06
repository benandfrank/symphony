# Symphony Architecture

This document describes the layered architecture of the Symphony service. The Elixir implementation
in `elixir/` is the reference implementation; the layers below map directly to modules in
`elixir/lib/symphony_elixir/`.

For the full language-agnostic specification see [`SPEC.md`](SPEC.md).

## Layers

Symphony is organized into six layers of decreasing abstraction. Each layer depends only on layers
below it.

```
┌──────────────────────────────────────────────┐
│  1. Policy Layer                             │  WORKFLOW.md
│     Prompt template + team workflow rules    │
├──────────────────────────────────────────────┤
│  2. Configuration Layer                      │  Config, Workflow
│     Typed getters, defaults, env resolution  │
├──────────────────────────────────────────────┤
│  3. Coordination Layer                       │  Orchestrator
│     Polling, eligibility, concurrency,       │
│     retries, reconciliation                  │
├──────────────────────────────────────────────┤
│  4. Execution Layer                          │  AgentRunner, Workspace
│     Workspace lifecycle, prompt building,    │
│     coding-agent subprocess protocol         │
├──────────────────────────────────────────────┤
│  5. Integration Layer                        │  Tracker, Linear.*, ClickUp.*
│     Issue tracker adapters (read + write)    │
├──────────────────────────────────────────────┤
│  6. Observability Layer                      │  StatusDashboard, HTTP server, logs
│     Operator visibility; never required for  │
│     correctness                              │
└──────────────────────────────────────────────┘
```

## Layer Details

### 1. Policy Layer — `WORKFLOW.md`

The repository-owned runtime contract. The YAML front matter configures all tunable parameters;
the Markdown body is the Liquid prompt template rendered per issue before each agent turn.

Changes here take effect without a restart (the service watches the file for changes).

### 2. Configuration Layer — `SymphonyElixir.Config`, `SymphonyElixir.Workflow`

- `Workflow` reads and parses `WORKFLOW.md` (YAML front matter + prompt body).
- `Config` exposes typed, defaulted getters for every tuneable. All runtime code reads config
  through `Config`; there are no ad-hoc `System.get_env/1` calls outside this module.
- Supports `$VAR_NAME` indirection for secrets and path values.
- Validates required fields before each dispatch cycle (tracker kind, API key, project ID, codex
  command).

### 3. Coordination Layer — `SymphonyElixir.Orchestrator`

The single authoritative GenServer that owns all scheduling state. Nothing else mutates the
orchestrator's in-memory map.

Responsibilities:
- **Poll tick** — reconcile active runs, validate config, fetch candidates, dispatch.
- **Dispatch** — eligibility checks (state, concurrency slots, blocker rules), priority sort,
  re-validation before launch.
- **Retry queue** — exponential backoff for failures; short fixed delay for normal-exit
  continuations.
- **Reconciliation** — stall detection (inactivity timeout) and tracker-state refresh every tick.
- **Startup cleanup** — remove stale workspaces for issues already in terminal states.

State is purely in-memory; recovery after restart is driven by re-polling the tracker.

### 4. Execution Layer — `SymphonyElixir.AgentRunner`, `SymphonyElixir.Workspace`, `SymphonyElixir.PromptBuilder`

- `Workspace` maps issue identifiers to filesystem paths, enforces path-safety invariants, and
  runs lifecycle hooks (`after_create`, `before_run`, `after_run`, `before_remove`).
- `PromptBuilder` renders the Liquid prompt template against the normalized issue struct.
- `AgentRunner` owns the coding-agent subprocess lifecycle: launches via `bash -lc <codex.command>`,
  speaks the JSON-RPC app-server protocol over stdio, streams events back to the orchestrator.
- `Codex.AppServer` handles the low-level protocol (initialize, thread/start, turn/start, streaming
  turn results, approval auto-handling, dynamic tool dispatch).

**Safety invariants (never relax):**
- Agent subprocess `cwd` must equal the per-issue workspace path.
- Workspace path must be a strict child of `workspace.root`.
- Workspace key characters are restricted to `[A-Za-z0-9._-]`.

### 5. Integration Layer — `SymphonyElixir.Tracker`, `SymphonyElixir.Linear.*`, `SymphonyElixir.ClickUp.*`

`Tracker` is the adapter boundary: a behaviour with five callbacks
(`fetch_candidate_issues/0`, `fetch_issues_by_states/1`, `fetch_issue_states_by_ids/1`,
`create_comment/2`, `update_issue_state/2`). The orchestrator and agent runner call only the
`Tracker` module; they have no knowledge of which backend is active.

Current adapters:
- `Linear.Adapter` + `Linear.Client` — GraphQL-over-HTTP client for Linear.
- `ClickUp.Adapter` + `ClickUp.Client` — REST client for ClickUp.
- `Tracker.Memory` — in-memory stub for tests and local development.

Adding a new tracker means adding a new adapter module under
`lib/symphony_elixir/<tracker>/` and a new clause in `Tracker.adapter/0`.

The normalized issue struct (`SymphonyElixir.Issue`) is tracker-agnostic; all adapters produce the
same struct shape.

The optional dynamic tool (`Codex.DynamicTool`) is tracker-aware: it advertises `linear_graphql`
when `tracker.kind == "linear"` and `clickup_api` when `tracker.kind == "clickup"`. Each tool
gives the agent direct API access using Symphony's configured auth. The `clickup_api` tool
enforces guardrails: method allowlist (`GET`, `POST`, `PUT`), path prefix allowlist
(`/task/`, `/list/`, `/team/`), payload size limits, and error redaction.

### 6. Observability Layer — `SymphonyElixir.StatusDashboard`, HTTP server, Logger

- `StatusDashboard` renders a live terminal table of running sessions, retry queue, token counters,
  and rate limits. It is updated via PubSub notifications from the orchestrator.
- The optional Phoenix HTTP server (enabled by `server.port` or `--port`) exposes the same data
  via a LiveView dashboard at `/` and a JSON API at `/api/v1/*`.
- Structured logs use stable `key=value` phrasing and always include `issue_id`,
  `issue_identifier`, and `session_id` where applicable (see `elixir/docs/logging.md`).

Observability is never required for correctness. Removing it does not affect orchestrator behavior.

## Key Data Flow

```
WORKFLOW.md
    │  (on tick or file change)
    ▼
Config.validate!()
    │  (ok)
    ▼
Tracker.fetch_candidate_issues()
    │  {:ok, [%Issue{}]}
    ▼
Orchestrator.choose_issues()
    │  (eligible issues)
    ▼
AgentRunner.run(issue, orchestrator_pid)
    ├── Workspace.ensure(issue.identifier)
    ├── PromptBuilder.build_prompt(issue, attempt: n)
    └── Codex.AppServer.run(workspace, prompt, ...)
            │  (streams {:codex_worker_update, issue_id, event})
            ▼
        Orchestrator  ←── token accounting, rate limits, stall detection
```

## Concurrency Model

- One `Orchestrator` GenServer serializes all state mutations.
- Each agent run is a supervised `Task` under `SymphonyElixir.TaskSupervisor`.
- Workers communicate back to the orchestrator via `send/2` (no shared state).
- The orchestrator monitors each task via `Process.monitor/1` and handles `:DOWN` messages to
  trigger retries or continuations.
