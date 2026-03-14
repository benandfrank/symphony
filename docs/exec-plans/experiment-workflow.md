# Execution Plan: Experiment Workflow Pattern

**Design doc:** [`docs/design-docs/experiment-workflow.md`](../design-docs/experiment-workflow.md)  
**Status:** Proposed  
**Cycle:** Think → Spec → 🔴 Red → Implement → 🟢 Green → 🔵 Refactor → Deliver

---

## Problem

Symphony can already orchestrate long-running autonomous ticket work, but it does not yet provide a
blessed pattern for tickets whose goal is empirical optimization rather than ordinary delivery.

Examples:

- benchmark reduction,
- runtime performance tuning,
- prompt/eval tuning,
- model or compiler configuration search,
- throughput/latency improvements with fixed measurement commands.

Today, teams can approximate this with custom prompt rules, but there is no standard for:

- baseline-first execution,
- experiment logging,
- constrained edit scope,
- keep/discard discipline,
- tracker-visible reporting for experiment loops.

The goal of this plan is to add a documented, reusable **experiment workflow pattern** while
keeping Symphony's core orchestration model unchanged.

---

## Scope

### In scope

1. Document the experiment workflow pattern for benchmark-driven tickets.
2. Add a dedicated skill, e.g. `.codex/skills/experiment/SKILL.md`, that encodes the loop.
3. Update workflow guidance so repos can opt into experiment-style tickets explicitly.
4. Define a standard workspace artifact format for experiment history.
5. Define tracker/workpad reporting expectations for experiment summaries.
6. Validate the pattern against Symphony's current continuation-turn model.

### Out of scope

- Changing the `SPEC.md` orchestration model.
- Adding a new `experiment:` config schema to `WORKFLOW.md`.
- Adding orchestrator-native metric parsing or keep/discard decisions.
- Adding automatic workspace reset/revert support.
- Making experiment loops the default for normal tickets.
- Multi-agent research coordination.

---

## Proposed shape

The first version is a **policy-layer pattern** made of three parts:

1. **Workflow guidance**
   - A repo may define which ticket classes count as optimization/experiment tickets.
2. **Skill protocol**
   - The experiment skill tells the agent how to run:
     - baseline,
     - mutation,
     - evaluation,
     - log append,
     - keep/discard reasoning,
     - continuation.
3. **Workspace artifact**
   - A file such as `results.tsv` or `experiments/results.tsv` stores experiment history.

### Standard expectations for the first version

For an issue using the experiment pattern:

- the first run is always baseline-only,
- the workflow declares the evaluation command and success metric,
- the agent appends every attempt to the experiment ledger,
- the workpad comment contains the current best result and latest attempt summary,
- continuation turns continue autonomously while the issue remains active,
- the agent stops only for workflow-defined blockers (missing secrets, missing environment,
  ambiguous objective, hard failures).

---

## Proposed experiment ledger

Use a TSV file in the workspace so the agent can append safely and diffs remain readable.

Suggested header:

```tsv
commit	metric	status	description
```

Optional richer header when memory/runtime matter:

```tsv
commit	metric	memory_gb	status	description
```

### Status vocabulary

Use one of:

- `baseline`
- `keep`
- `discard`
- `crash`

This is intentionally small and easy for the agent to maintain.

### Location

Preferred locations:

- `results.tsv`
- `experiments/results.tsv`

Choose one convention per repo and document it in the workflow/skill.

---

## Acceptance criteria

### Functional

- [ ] A documented experiment workflow exists in repo docs.
- [ ] A dedicated experiment skill exists and is usable by the agent.
- [ ] The skill requires a baseline-first run.
- [ ] The skill defines a standard experiment ledger format.
- [ ] The skill defines tracker/workpad summary expectations.
- [ ] The workflow pattern works with existing continuation-turn behavior and does not require core
      orchestration changes.

### Safety / product-shape

- [ ] Experiment behavior is opt-in and does not affect ordinary tickets.
- [ ] No spec changes are required for the MVP.
- [ ] No core workspace reset/revert behavior is introduced.
- [ ] The pattern clearly requires an objective evaluation command before use.

---

## Validation checklist

- [ ] Review the skill and workflow text against `WORKFLOW.md` conventions.
- [ ] Confirm the proposed loop is achievable with current `agent.max_turns` and continuation
      semantics.
- [ ] Confirm no `SPEC.md` changes are needed for the MVP.
- [ ] Validate the ledger format is agent-friendly and diff-friendly.
- [ ] Validate workpad summaries stay concise while the detailed ledger remains in the workspace.

---

## Implementation phases

### Phase 1 — Document the pattern

Add the design doc and execution plan. Capture:

- when the pattern should be used,
- when it should not be used,
- baseline/evaluation/logging expectations,
- guardrails against using it for normal delivery tickets.

**Exit criteria:** docs merged and referenced from the design-doc index.

### Phase 2 — Add the experiment skill

Create `.codex/skills/experiment/SKILL.md` with:

- goals,
- prerequisites,
- baseline-first rule,
- loop structure,
- logging rules,
- stop conditions,
- workpad reporting requirements.

**🔴 Red:** add or update documentation/tests that assert the skill is discoverable where skills are
indexed or referenced.

**Exit criteria:** skill exists and can be referenced from `WORKFLOW.md`.

### Phase 3 — Add workflow guidance

Update `elixir/WORKFLOW.md` or related prompt docs so repos can opt into the experiment pattern.

Suggested guidance:

- only use for tickets with objective measurement,
- define the evaluation command explicitly,
- define success direction (`lower is better` / `higher is better`),
- define any edit-scope constraints,
- require experiment ledger updates after each run.

**Exit criteria:** workflow guidance is clear enough for a repo to enable the pattern without extra
orchestrator features.

### Phase 4 — Pilot on a real optimization ticket

Use the pattern on one issue in a benchmark-driven repo.

Capture:

- whether continuation turns are sufficient,
- whether the ledger format is usable,
- whether workpad summaries stay readable,
- whether a future orchestrator seam is genuinely needed.

**Exit criteria:** one real ticket validates or falsifies the pattern.

---

## Future follow-up candidates

These are intentionally deferred until after a pilot.

### 1. Structured post-turn evaluation hook

Potential future addition:

- a hook that runs after a turn,
- returns structured output such as metric value and recommendation,
- allows the orchestrator to make stronger continuation or release decisions.

This is the most promising infrastructure enhancement if the policy-layer MVP proves useful.

### 2. Workflow schema support

Possible future `WORKFLOW.md` config support for:

- evaluation command,
- objective direction,
- iteration cap,
- editable path allowlist,
- ledger path.

Do not add until multiple repos need the same shape.

### 3. Workspace revert primitive

If repeated keep/discard experimentation becomes common, a safe workspace reset primitive may be
worth designing. This should come after real usage proves the need.

---

## Risks and mitigations

1. **Pattern creep into normal delivery tickets**
   - Mitigation: document clear entry criteria and make the skill explicitly opt-in.

2. **Weak enforcement in the MVP**
   - Mitigation: keep the protocol simple and explicit; validate through a real pilot.

3. **Ambiguous or low-quality metrics**
   - Mitigation: require a fixed evaluation command and success direction before using the pattern.

4. **Runaway autonomy**
   - Mitigation: rely on existing `max_turns`, timeouts, and workflow-defined blockers.

5. **Noisy tracker comments**
   - Mitigation: store detailed history in the workspace ledger and keep tracker summaries compact.

---

## Deliverables

- `docs/design-docs/experiment-workflow.md`
- `docs/exec-plans/experiment-workflow.md`
- `.codex/skills/experiment/SKILL.md`
- `elixir/WORKFLOW.md` guidance for opt-in experiment tickets
- `docs/examples/README.md`
- `docs/examples/experiment-results.tsv`
- `docs/examples/experiment-workpad-summary.md`
- one pilot report from a benchmark-driven ticket (future validation phase)
