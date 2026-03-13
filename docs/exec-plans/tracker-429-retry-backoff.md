# Execution Plan: Tracker 429 Retry / Backoff

**Status:** Done  
**Owner:** Unassigned  
**Related tech-debt entries:** `docs/exec-plans/tech-debt-tracker.md` (ClickUp 429 / `Retry-After`)  
**Cycle:** Think → Spec → 🔴 Red → Implement → 🟢 Green → 🔵 Refactor → Deliver

---

## Problem

Both tracker clients currently treat HTTP 429 like any other API failure:

- `SymphonyElixir.ClickUp.Client` returns `{:error, {:clickup_api_status, 429}}`
- `SymphonyElixir.Linear.Client` returns `{:error, {:linear_api_status, 429}}`

That means Symphony gives up immediately instead of honoring the tracker's retry signal. In practice,
this causes avoidable polling failures, reconciliation gaps, and dynamic-tool request failures during
short-lived rate-limit windows.

The desired behavior is tracker-aware retry with bounded backoff:

- honor `Retry-After` when provided,
- otherwise fall back to a local bounded backoff policy,
- retry only for 429s,
- preserve existing error behavior for all non-429 responses.

---

## Scope

### In scope

1. Add bounded retry/backoff handling for tracker HTTP 429 responses in:
   - `SymphonyElixir.ClickUp.Client`
   - `SymphonyElixir.Linear.Client`
2. Honor `Retry-After` response headers when present and parseable.
3. Apply the behavior to both polling/reconciliation reads and direct client entry points used by
   dynamic tools:
   - ClickUp `rest/4`
   - Linear `graphql/3`
4. Add deterministic tests for retry success, retry exhaustion, and non-retry cases.
5. Update reference docs and close the matching tech-debt tracker entry when implemented.

### Out of scope

- General retry for non-429 statuses (500, network timeouts, etc.)
- Orchestrator-level rescheduling redesign
- Circuit breaking or shared global rate-limit budgeting across multiple Symphony instances
- Dynamic-tool user-facing error message redesign beyond preserving current behavior
- Multi-operation GraphQL validation
- Tracker-level `update_comment` API expansion

---

## Current behavior review

### ClickUp

`ClickUp.Client` currently handles list reads, task reads, dependency reads, and direct REST calls by
pattern-matching on `%{status: ...}` and immediately returning an error for any non-success status.
A 429 response is indistinguishable from a hard failure.

### Linear

`Linear.Client.graphql/3` currently treats any non-200 response as an immediate
`{:error, {:linear_api_status, status}}`. The higher-level fetch functions do not have a retry seam
above that.

### Testing seam status

- ClickUp already supports injected `request_fun:` options in client tests.
- Linear already supports injected `request_fun:` in `graphql/3`.
- There is no dedicated `linear_client_test.exs` today; current Linear client tests live in
  `test/symphony_elixir/workspace_and_config_test.exs`.

This means the feature is testable without introducing mocks or module replacement.

---

## Proposed design

### 1. Introduce a small shared retry helper

Add a narrow helper module, for example:

- `lib/symphony_elixir/tracker/retry.ex`

Responsibilities:

- execute a request function,
- inspect the normalized response for retryability,
- sleep between attempts using an injectable sleeper,
- stop after a bounded retry count,
- return the final response unchanged.

Suggested public API shape:

```elixir
@spec with_rate_limit_retry((-> response), keyword()) :: response
```

Where options include:

- `max_attempts:` total attempts including the first try (default: `3`)
- `base_backoff_ms:` fallback base delay (default: `1_000`)
- `max_backoff_ms:` cap (default: `30_000`)
- `sleep_fun:` injectable function for tests (default: `Process.sleep/1`)

Keep this helper intentionally small and response-shape-agnostic; each client can provide
client-specific callbacks for:

- `retryable?`
- `retry_after_ms`

This avoids overfitting a complex generic HTTP abstraction.

### 2. Normalize response-header access without changing the public client API

Both clients should continue returning the same success/error tuples they return today.

Internally, the retry logic needs access to response headers. Support an optional response shape like:

```elixir
%{status: 429, body: %{}, headers: [{"retry-after", "2"}]}
```

or equivalent header maps.

The implementation should accept both list and map header shapes defensively. If headers are absent,
retry still works via fallback backoff.

### 3. Retry policy

Retry **only** when all are true:

- HTTP status is `429`
- remaining attempts exist

Delay selection:

1. If `Retry-After` header exists and parses as a positive integer number of seconds, use it.
2. Otherwise use exponential fallback backoff:
   - attempt 1 retry delay: `base_backoff_ms`
   - attempt 2 retry delay: `base_backoff_ms * 2`
   - capped at `max_backoff_ms`

If `Retry-After` is invalid, blank, zero, or negative, ignore it and use fallback backoff.

### 4. Logging

Add low-noise retry logs at `debug` or `info` level with tracker context, for example:

- tracker kind / client module
- status `429`
- chosen delay
- attempt number / max attempts
- whether delay came from `Retry-After` or fallback

Do **not** log full auth headers or request bodies.

### 5. Preserve current non-429 behavior

Important invariant: if the response is not a 429, behavior must remain unchanged.

Examples:

- ClickUp 503 still returns `{:error, {:clickup_api_status, 503}}`
- Linear 400 still returns `{:error, {:linear_api_status, 400}}`
- transport errors remain immediate errors unless explicitly expanded in a separate ticket

---

## Acceptance criteria

### Functional

- [ ] ClickUp client retries 429 list polling responses and eventually succeeds when a later attempt succeeds.
- [ ] ClickUp client retries 429 task/dependency reads and eventually succeeds when a later attempt succeeds.
- [ ] ClickUp `rest/4` retries 429 responses and preserves the current return shape.
- [ ] Linear `graphql/3` retries 429 responses and preserves the current return shape.
- [ ] `Retry-After` header is honored when present and parseable.
- [ ] Missing or invalid `Retry-After` falls back to bounded exponential backoff.
- [ ] Non-429 HTTP responses are not retried.
- [ ] Transport errors are not retried.
- [ ] Retry exhaustion returns the same final 429 error shape each client currently exposes.

### Safety / maintainability

- [ ] No public API regression in `ClickUp.Client.rest/4` or `Linear.Client.graphql/3`.
- [ ] Tests remain deterministic without real sleeping.
- [ ] Coverage remains 100%.
- [ ] Docs updated in the same change.

---

## Validation checklist

- [ ] Focused ClickUp client tests pass.
- [ ] Focused Linear client tests pass.
- [ ] `make all` passes.
- [ ] Coverage report remains 100%.
- [ ] Tech-debt tracker updated to close or annotate the 429 entry.

---

## 🔴 Red phase plan

Write failing tests before production changes.

### ClickUp red tests

Add tests in `test/symphony_elixir/clickup_client_test.exs` for:

1. `fetch_candidate_issues/1` retries once after a 429 list response, honoring `Retry-After`.
2. `fetch_candidate_issues/1` falls back to exponential backoff when 429 has no header.
3. `fetch_candidate_issues/1` returns final `{:error, {:clickup_api_status, 429}}` after retry exhaustion.
4. `rest/4` retries a 429 and succeeds on a later attempt.
5. `rest/4` does not retry non-429 responses.
6. dependency fetch path retries a 429 from `/task/{id}/dependency`.
7. task reconciliation path retries a 429 from `/task/{id}`.

Implementation note for tests:

- use `Agent`-backed sequential request functions to return scripted responses,
- inject `sleep_fun` to capture requested delays instead of sleeping,
- assert on both output and recorded delay values.

### Linear red tests

Add tests in either:

- a new `test/symphony_elixir/linear_client_test.exs`, or
- the existing `test/symphony_elixir/workspace_and_config_test.exs`

Cover:

1. `graphql/3` retries a 429 and succeeds on a later attempt.
2. `graphql/3` honors `Retry-After` when present.
3. `graphql/3` falls back when `Retry-After` is invalid/missing.
4. `graphql/3` returns final `{:error, {:linear_api_status, 429}}` after retry exhaustion.
5. `graphql/3` does not retry non-429 responses.
6. a higher-level fetch path (`fetch_candidate_issues/0` or `fetch_issue_states_by_ids/1`) benefits from the retry behavior through `graphql/3`.

Red exit criterion:

- new tests fail specifically because retry/backoff is missing,
- all existing tests still pass.

---

## Implement plan

### Step 1: add shared retry helper

Create `Tracker.Retry` with:

- bounded attempt loop,
- delay selection,
- injected sleep function,
- minimal logging.

Prefer pure functions for:

- header extraction,
- `Retry-After` parsing,
- fallback backoff computation.

### Step 2: wire ClickUp client

Apply retry wrapper around:

- list endpoint requests,
- single-task fetches,
- dependency endpoint fetches,
- `rest/4` direct calls.

Keep the final external return values unchanged.

### Step 3: wire Linear client

Apply retry wrapper inside `graphql/3`, since this is the common path used by higher-level fetches.

Ensure the logging and error shaping stay consistent with current behavior.

### Step 4: harden response/header parsing

Support header extraction from both:

- list-of-tuples header representations,
- map-style header representations,
- mixed-case header names.

Keep the parsing logic local to the retry helper or a tiny private companion module.

---

## 🟢 Green phase

After implementation:

1. run focused client tests,
2. fix any coverage gaps introduced by new branches,
3. run full `make all`,
4. confirm no dialyzer or credo regressions.

Green exit criterion:

- `make all` passes,
- coverage remains 100%,
- all new retry paths are directly tested.

---

## 🔵 Refactor phase

Allowed cleanup after green:

- reduce duplication between ClickUp and Linear retry call sites,
- tighten helper names/specs,
- improve log wording,
- document any newly discovered out-of-scope retry concerns in the tech-debt tracker.

Do **not** expand scope to:

- retrying non-429 transport failures,
- adding shared token-bucket coordination,
- introducing orchestrator-wide backpressure redesign.

---

## Docs to update when implementing

- `docs/references/clickup-api.md`
  - note that the client honors `Retry-After` for 429s
- `docs/references/index.md`
  - update if a new tracker reference doc is added
- `README.md` / `elixir/README.md`
  - only if user-visible operator behavior changes materially
- `docs/exec-plans/tech-debt-tracker.md`
  - close or annotate the 429 entry with the follow-up ticket/commit

Optional but likely useful:

- add a new `docs/references/linear-api.md` if the implementation needs Linear-specific notes on
  rate limiting that are not currently captured anywhere in the repo.

---

## Risks and edge cases

1. **Header shape drift**
   - Different request adapters may expose headers differently.
   - Mitigation: parse both map and tuple-list shapes defensively.

2. **Coverage regression from retry branches**
   - Every new fallback/invalid-header branch can reduce total coverage.
   - Mitigation: add direct unit tests for each branch.

3. **Unexpected caller slowdown**
   - Retrying inside client calls increases synchronous latency.
   - Mitigation: bound attempts and delay cap tightly; document defaults.

4. **Recursive pagination + retry interaction**
   - Retry should happen at the individual request layer, not via repolling the full pagination tree.
   - Mitigation: wrap each request call, not the entire fetch operation.

---

## Recommended implementation order

1. Add retry helper + its direct unit tests if needed.
2. Add ClickUp red tests.
3. Wire ClickUp client.
4. Add Linear red tests.
5. Wire Linear client.
6. Run `make all`.
7. Update docs and tech-debt tracker.

---

## Deliverables

- production code implementing bounded 429 retry/backoff in both tracker clients
- deterministic tests covering success, fallback, and exhaustion paths
- updated reference docs
- updated tech-debt tracker entry
- green `make all`
