# Tracker Abstraction — Design Decision

**Status:** Accepted  
**Date:** 2026-03-05

---

## Context

Symphony is designed to be tracker-agnostic at the specification level (`SPEC.md` §11: "A
non-Linear implementation may change transport details, but the normalized outputs must match the
domain model"). In practice the Elixir implementation hardcodes Linear in at least six places
outside the adapter boundary:

| Leak | Location |
|------|----------|
| Issue struct namespace | `SymphonyElixir.Linear.Issue` used everywhere |
| Config getter names | `Config.linear_api_token/0`, `Config.linear_project_slug/0`, etc. |
| Validation error atoms | `:missing_linear_api_token`, `:missing_linear_project_slug` |
| Orchestrator log messages | `"Linear API token missing"`, `"Failed to fetch from Linear"` |
| Dynamic tool | `linear_graphql` hardcoded in `DynamicTool`; not tracker-aware |
| Status dashboard | `linear_project_url/1` hardcoded URL pattern |

The `SymphonyElixir.Tracker` behaviour and `Tracker.adapter/0` dispatch are the *right* boundary.
Everything above is noise that leaked through it.

Adding ClickUp without fixing this first would double the debt: two parallel sets of
Linear-specific names, two hardcoded URL formats, two dynamic tools wired with `if tracker_kind ==
"linear"` guards scattered across unrelated modules.

---

## Decision

**Complete the existing abstraction before adding ClickUp.** The work has two distinct parts:

### Part A — Close the leaks (pure refactor, no behavior change)

1. **Move the issue struct** to `SymphonyElixir.Issue`. Keep a `SymphonyElixir.Linear.Issue`
   type alias for any backward-compat references. All adapters produce `%SymphonyElixir.Issue{}`.

2. **Rename config getters** to tracker-agnostic names. The getters already read from the generic
   `tracker:` YAML section — their names are wrong, not their logic:

   | Old | New |
   |-----|-----|
   | `Config.linear_api_token/0` | `Config.tracker_api_token/0` |
   | `Config.linear_endpoint/0` | `Config.tracker_endpoint/0` |
   | `Config.linear_project_slug/0` | `Config.tracker_project_id/0` |
   | `Config.linear_assignee/0` | `Config.tracker_assignee/0` |
   | `Config.linear_active_states/0` | `Config.tracker_active_states/0` |
   | `Config.linear_terminal_states/0` | `Config.tracker_terminal_states/0` |

3. **Rename validation error atoms** to tracker-agnostic terms:

   | Old | New |
   |-----|-----|
   | `:missing_linear_api_token` | `:missing_tracker_api_token` |
   | `:missing_linear_project_slug` | `:missing_tracker_project_id` |

4. **Update `Tracker.adapter/0`** to explicitly handle every supported kind and raise on unknown
   kinds rather than silently falling back to Linear.

5. **Make `DynamicTool` tracker-aware.** Each tracker kind can optionally expose one dynamic tool
   to the agent session. The tool name, schema, and implementation are tracker-specific; the
   dispatch mechanism is generic. `DynamicTool.tool_specs/0` and `DynamicTool.execute/3` consult
   `Config.tracker_kind/0` to return the right tool for the active tracker.

   ```
   tracker.kind == "linear"  →  advertise + execute  linear_graphql
   tracker.kind == "clickup" →  advertise + execute  clickup_api
   tracker.kind == "memory"  →  no dynamic tool advertised
   ```

   This is the cleanest extension point: adding a new tracker with its own agent-facing API
   requires only a new case in `DynamicTool`, not changes to the app-server session startup.

6. **Make `StatusDashboard` tracker-aware** for the project URL it renders. Each adapter module
   can optionally export a `project_url/0` function, or the dashboard can branch on
   `Config.tracker_kind/0`.

### Part B — Add ClickUp adapter

Implement `SymphonyElixir.ClickUp.Client` and `SymphonyElixir.ClickUp.Adapter` following the
same structure as the Linear pair. Key differences from Linear:

| Concern | Linear | ClickUp |
|---------|--------|---------|
| Transport | GraphQL over HTTP POST | REST over HTTP GET/POST/PUT |
| Base URL | `https://api.linear.app/graphql` | `https://api.clickup.com/api/v2` |
| Auth env var | `LINEAR_API_KEY` | `CLICKUP_API_KEY` |
| Project identifier | `project_slug` (string) | `list_id` (numeric string) |
| Candidate fetch | GraphQL filter on project + state | `GET /list/{list_id}/task?statuses[]=...` |
| Fetch by IDs | GraphQL `ids: [ID!]!` filter | `GET /task/{task_id}` per ID |
| Pagination | Cursor-based (`endCursor`) | Page-based (`?page=0,1,...`) |
| Labels | `labels.nodes[].name` | `tags[].name` |
| Blockers | `inverseRelations` where type is `blocks` | `GET /task/{id}/dependency` |
| Assignee | `assignee.id` (single) | `assignees[].id` (array) |
| Branch name | `branchName` native field | Not available — always `nil` |
| State update | Two-step: resolve state ID → issueUpdate mutation | `PUT /task/{id}` with `{status: name}` |
| Comment create | `commentCreate` mutation | `POST /task/{id}/comment` |
| Dynamic tool | `linear_graphql` (raw GraphQL passthrough) | `clickup_api` (REST passthrough: method + path + body) |

The `clickup_api` dynamic tool gives the agent direct REST access to ClickUp using Symphony's
configured auth, equivalent to what `linear_graphql` provides for Linear.

---

## Review Insights (2026-03-05)

A follow-up review validated this direction and added four execution constraints:

1. **Unsupported tracker kinds must fail cleanly.**
   - User-facing failure should come from `Config.validate!/0` (`{:unsupported_tracker_kind, ...}`),
     not from noisy runtime crashes.
   - Any runtime raise in `Tracker.adapter/0` is defensive only.

2. **Keep migration compatibility longer.**
   - Keep deprecated `Config.linear_*` aliases through the ClickUp rollout window.
   - Remove them in a dedicated cleanup PR after ClickUp paths are stable.

3. **Dependency mapping needs a spike.**
   - ClickUp dependency semantics must be validated with real payloads before finalizing
     `blocked_by` mapping.

4. **Dynamic tool needs first-pass guardrails.**
   - Limit methods/paths, cap payload sizes, and redact sensitive error details in `clickup_api`.

---

## Alternatives Considered

### Just add ClickUp in parallel without refactoring

Add a ClickUp adapter, add `clickup_*` config getters alongside `linear_*`, branch on
`tracker.kind` where needed.

**Rejected.** Every future tracker doubles the debt. After three trackers the config module has
`linear_api_token/0`, `clickup_api_token/0`, and `github_projects_api_token/0` all reading from
the same `tracker.api_key` YAML key. The abstraction collapses into a naming mess.

### Full runtime protocol for dynamic tools (behaviour + registry)

Define a `TrackerTool` behaviour and have each adapter register its tool implementation.

**Too much for now.** There are at most a handful of trackers; a `case Config.tracker_kind()` in
`DynamicTool` is readable and sufficient. Promote to a registry if the number of trackers grows
past three or if dynamic tool logic becomes complex.

### Rename `SymphonyElixir.Linear.*` modules to `SymphonyElixir.Tracker.Linear.*`

Move modules into the `Tracker` namespace to match the adapter pattern.

**Fine either way.** `SymphonyElixir.Linear.Client` and `SymphonyElixir.Linear.Adapter` are clear
enough as-is. The important thing is that the `Issue` struct leaves the `Linear` namespace, not
the implementation modules.

---

## Consequences

**Makes easier:**
- Adding a new tracker: create `lib/symphony_elixir/<tracker>/client.ex` + `adapter.ex`, add a
  case in `Tracker.adapter/0`, add a tool case in `DynamicTool`, add a URL case in
  `StatusDashboard`. No changes to orchestrator, config getter names, or issue struct.
- Reading the code: `Config.tracker_api_token/0` is obviously generic; `Config.linear_api_token/0`
  requires the reader to check whether it's actually generic.
- Testing: tests no longer need Linear-named helpers; the memory adapter tests already use
  `SymphonyElixir.Issue` after the struct rename.

**Makes harder / watch out for:**
- The rename of `Config.linear_*` functions is a breaking change in name only — behavior is
  identical. Any external consumer of the Elixir config API (unlikely, but possible in forks) will
  need to update call sites.
- The issue struct rename touches every file that aliases `SymphonyElixir.Linear.Issue`. The
  change is mechanical but broad — run `mix specs.check` and `make all` after to confirm nothing
  was missed.
- ClickUp's lack of a native `branch_name` field means the `branch_name` field in
  `SymphonyElixir.Issue` will always be `nil` for ClickUp tasks. The WORKFLOW.md prompt and any
  skill that references `issue.branch_name` should handle nil gracefully.
