# Tech Debt Tracker

Out-of-scope improvements discovered during implementation. Each item is a candidate for a future
work ticket. Agents should append here instead of silently dropping the finding.

## How to use

When an agent discovers a meaningful improvement that is out of scope for the current ticket:

1. Append an entry to the **Open** table below.
2. File a tracker issue (Linear/ClickUp) and record the issue ID in the `Ticket` column.
3. If a tracker issue is not filed during the current change, temporarily use `—` in the `Ticket`
   column and carry the follow-up into merge triage / PR review.
4. Move the entry to **Closed** once the work is done or explicitly decided against.

Do not expand scope to fix items here mid-ticket. Log and move on.

## Open

| Area | Finding | Discovered in | Ticket | Added |
|------|---------|--------------|--------|-------|


## Closed

| Area | Finding | Resolution | Ticket | Closed |
|------|---------|-----------|--------|--------|
| Config | ClickUp config contract mismatch: implementation relied on `tracker.project_slug`; add and prefer `tracker.list_id` with fallback for compatibility | Added `tracker.list_id` to schema/extraction; `tracker_project_id/0` now resolves `list_id || project_slug` for ClickUp. Added config tests for preferred and fallback behavior. | — | 2026-03-05 |
| Config | `tracker_assignee/0` env var fallback hardcoded `LINEAR_ASSIGNEE` for all tracker kinds including ClickUp | `tracker_assignee/0` now uses tracker-kind-aware env fallback (`CLICKUP_ASSIGNEE` for ClickUp, `LINEAR_ASSIGNEE` otherwise). Added ClickUp config test. | — | 2026-03-05 |
| ClickUp | Dependency type mapping inversion for `blocked_by` extraction (`type` 0/1 swapped) | Corrected extraction logic (`type == 0` means waiting on). Updated tests and `docs/references/clickup-api.md`. | — | 2026-03-05 |
| Testing | `DynamicTool.clickup_error_payload/1` had multiple untested clauses | Added 11 tests covering all `clickup_error_payload` clauses plus nil `tracker_kind` guard. | — | 2026-03-06 |
| DynamicTool | `execute/3` silently failed as "unsupported" when `Config.tracker_kind()` returned `nil` | Added explicit `{nil, _tool}` guard clause with clear error message. | — | 2026-03-06 |
| Tests | `FakeLinearClient` in `extensions_test.exs` used `Process.put` result sequencing | Replaced module-swap and `Process.put` test seams with injected adapter functions / sequential helpers. | — | 2026-03-06 |
| Tests | `Application.put_env(:linear_client_module, FakeModule)` module-swap seam | Removed module-replacement seam from `Linear.Adapter` and extension tests; tests now use function injection. | — | 2026-03-06 |
| Config | Deprecated `Config.linear_*` compatibility aliases | Removed deprecated compatibility getters after tracker-agnostic call sites were in place. | — | 2026-03-06 |
| ClickUp | Blocker detection was best-effort only via inline task `dependencies` | Added dependency-endpoint fallback when task payloads omit `dependencies`; updated tests and reference docs. | — | 2026-03-06 |
| Testing | `mix.exs` coverage ignore included `SymphonyElixir.ClickUp.Adapter` | Added direct adapter tests and removed `ClickUp.Adapter` from the ignore list. | — | 2026-03-06 |
| Process | Phase work stacked on `feat/tracker-abstraction-phase-1` rather than per-phase branch split | Documented the exception in the PR body and merged with explicit reviewer guidance about stacked phases. | — | 2026-03-06 |
| Testing | `mix.exs` coverage ignore included `SymphonyElixir.ClickUp.Client` (~89% direct coverage) | Extracted `default_request/4` to `ClickUp.HTTP` module, added `on_timeout: :kill_task` for testable async exits, added injectable `async_timeout` opt, wrote tests for all 13 uncovered lines. Module now at 100% and removed from ignore list. | — | 2026-03-05 |
