# Symphony Elixir

This directory contains the Elixir agent orchestration service that polls the configured tracker, creates per-issue workspaces, and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).


## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `SymphonyElixir.Workflow` and `SymphonyElixir.Config`.
- Keep the implementation aligned with [`../SPEC.md`](../SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same
    change where practical so the spec stays current.
- Prefer adding config access through `SymphonyElixir.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run Codex turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Development Cycle

Every ticket follows this loop. Each phase has a clear exit criterion — do not advance until it
is met.

```
Think → Spec → 🔴 Red → Implement → 🟢 Green → 🔵 Refactor → Deliver
```

| Phase | What happens | Exit criterion |
|-------|-------------|----------------|
| **Think** | Read ticket, reproduce the issue, write the workpad plan | Concrete reproduction signal recorded in workpad |
| **Spec** | Define acceptance criteria and validation steps in the workpad | Acceptance criteria and `Validation` checklist are complete before any code changes |
| **🔴 Red** | Write failing tests that capture the expected behavior | `make all` fails specifically on the new tests; all pre-existing tests still pass |
| **Implement** | Write the minimum production code to satisfy the failing tests | Code compiles, logic is complete |
| **🟢 Green** | Run the full gate | `make all` passes — format, lint, coverage, dialyzer, specs |
| **🔵 Refactor** | Clean up without changing behavior; log out-of-scope findings | `make all` still passes; findings logged in `docs/exec-plans/tech-debt-tracker.md` |
| **Deliver** | Push, open PR, run sweep, move to Human Review | PR checks green, no actionable review comments outstanding |

**🔴 Red phase is mandatory.** Do not write production code before a failing test exists for the
behavior being changed. If the scope does not lend itself to automated tests (e.g., pure config
or doc changes), note this explicitly in the workpad `Validation` section.

**🔵 Refactor phase output.** Out-of-scope improvements found during any phase must be logged in
`../docs/exec-plans/tech-debt-tracker.md` with a tracker issue ID. Do not silently drop findings
and do not expand scope to fix them in the current ticket.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

```bash
make all
```

### AAA Pattern (Required)

All unit tests must follow the **Arrange–Act–Assert** pattern. Each test block should have three
visually distinct sections:

```elixir
test "description of the expected behavior" do
  # Arrange — set up inputs, dependencies, and expected state
  issue = %Issue{id: "abc", identifier: "MT-1", title: "Fix bug", state: "Todo"}

  # Act — execute the single operation under test
  result = Tracker.fetch_candidate_issues()

  # Assert — verify the outcome
  assert {:ok, [^issue]} = result
end
```

**Rules:**
- One logical action per test. If a test needs multiple acts, split it into separate tests.
- Name tests after the behavior, not the function: `"rejects blank query strings"` not
  `"test normalize_linear_graphql_arguments"`.
- Use comments (`# Arrange`, `# Act`, `# Assert`) when the sections are non-trivial or when the
  test is longer than ~10 lines. For very short tests (3–5 lines), the structure should be
  self-evident without comments.
- Setup shared across multiple tests belongs in `setup` blocks (Arrange), not duplicated in each
  test body.

### Test Doubles: Prefer Nullables Over Mocks

We favor [Nullables](https://www.jamesshore.com/v2/projects/nullables/how-are-nullables-different-from-mocks)
over mocks for test doubles. The key distinctions:

| Concern | Mocks (avoid) | Nullables (prefer) |
|---------|--------------|-------------------|
| Where they live | Test code only | Production code with a test-friendly mode |
| What tests verify | Interaction ("you called X with Y") | Behavior ("given input, output is correct") |
| Coupling | Tests break when internal call structure changes | Tests break only when behavior changes |
| Confidence | Tests pass even if real wiring is broken | Tests exercise real code paths by default |

**What this means in practice:**

- `SymphonyElixir.Tracker.Memory` is the canonical example — it is a real production adapter that
  returns configured data via `Application.get_env`. Tests configure it and assert on behavior,
  not on which functions were called internally.
- When adding a new integration (e.g., ClickUp), build the nullable into the production module
  (configurable responses, injectable transport) rather than creating a separate `FakeClickUp`
  test module.
- For HTTP clients, prefer injecting a `request_fun` in production code (as `Linear.Client`
  already does) over replacing the entire module with a test double.
- Avoid `Mox`, `mock/2`, or any library that defines expectations on call counts or argument
  patterns. Assert on outputs and side effects, not on internal collaboration.

**Existing patterns to follow:**
- `Tracker.Memory` — nullable adapter configured via application env
- `Linear.Client.graphql/3` `request_fun:` opt — injectable transport for HTTP
- `DynamicTool.execute/3` `linear_client:` opt — injectable function for tool execution

**Existing patterns to migrate away from (tech debt):**
- Coverage-ignore entries on newly added integration modules should remain temporary. Prefer adding
  direct tests and removing ignore entries once practical.

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `../.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Repository Knowledge Store Layout

The repo uses a minimal in-repo knowledge store. Follow this structure when adding documentation:

```
symphony/
├── README.md                  # Project concept and goals
├── SPEC.md                    # Language-agnostic service specification
├── ARCHITECTURE.md            # Layered architecture overview (Elixir implementation)
│
├── docs/
│   ├── design-docs/           # ADR-style records for significant architectural decisions
│   │   └── index.md
│   ├── exec-plans/            # Active execution plans and tech debt log
│   │   └── tech-debt-tracker.md
│   └── references/            # LLM-friendly external API/tool references
│       └── index.md
│
└── elixir/
    ├── AGENTS.md              # This file — agent/contributor guidelines
    ├── README.md              # Elixir setup and run instructions
    ├── WORKFLOW.md            # Runtime config + agent prompt template
    └── docs/
        ├── logging.md         # Logging conventions and required context fields
        └── token_accounting.md
```

**When to use each location:**

- `ARCHITECTURE.md` — update when a new layer, subsystem, or major component is added or removed.
- `docs/design-docs/` — write a lightweight ADR when making a significant architectural trade-off
  (e.g., adding a tracker backend, changing the adapter boundary). See `docs/design-docs/index.md`
  for the format and when to write one.
- `docs/exec-plans/tech-debt-tracker.md` — log every out-of-scope finding discovered during a
  ticket. Include a tracker issue ID. This is the 🔵 Refactor phase output.
- `docs/references/` — add an LLM-friendly reference file when integrating a new external API or
  tool (e.g., a new tracker's REST API). One file per external system.
- `elixir/docs/` — Elixir implementation-specific reference docs (logging conventions, token
  accounting rules, etc.).

Do not create top-level docs outside this structure without updating this layout.

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `../README.md` for project concept and goals.
- `../ARCHITECTURE.md` for layer, subsystem, or component changes.
- `../SPEC.md` if the change meaningfully alters intended service behavior.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
- `docs/design-docs/` for significant architectural decisions (new file + update index).
- `docs/exec-plans/tech-debt-tracker.md` for out-of-scope findings during any ticket (append entry, do not create a new file).
- `docs/references/` for new or changed external API integrations (new/updated file + update index).
