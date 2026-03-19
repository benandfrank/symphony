# Experiment Workflow — Design Decision

**Status:** Accepted  
**Proposed:** 2026-03-11  
**Accepted:** 2026-03-14

---

## Context

A review of Karpathy's `autoresearch` project raised the question of whether Symphony should adopt a
similar autonomous experimentation loop.

`autoresearch` is intentionally narrow:

- one agent,
- one editable file,
- one fixed evaluation harness,
- one scalar objective metric,
- repeated keep/discard iterations on a dedicated branch.

Symphony has a different center of gravity:

- tracker-driven software delivery,
- multi-file repository work,
- long-running orchestration across many issues,
- PR/review/merge workflows,
- correctness and reviewability over pure metric optimization.

The useful question is therefore not "should Symphony become autoresearch?" but:

> should Symphony support an optional benchmark-driven experiment workflow for the subset of tickets
> that are optimization or research tasks?

This decision matters because the repo already has the core primitives needed for long-running
autonomous work:

- `WORKFLOW.md` as a repository-owned runtime policy layer,
- `.codex/skills/*` as markdown-programmed task protocols,
- continuation turns and retry scheduling in the orchestrator,
- persistent per-issue workspaces,
- tracker comments for session-visible progress reporting.

At the same time, Symphony does **not** currently model:

- metric-aware orchestration decisions,
- workspace revert/reset mechanics,
- a first-class experiment ledger,
- a dedicated experiment config schema.

---

## Decision

**Adopt experiment workflows as an optional policy/skill pattern, not as a new core Symphony
operating model.**

### What we will support

For optimization-style tickets, Symphony should support an **experiment workflow** with these
characteristics:

1. **Baseline-first discipline**
   - The first run establishes the baseline before any code changes.
2. **Objective evaluation**
   - A fixed command or harness determines success.
3. **Constrained scope**
   - The workflow may restrict editable files or directories.
4. **Append-only experiment logging**
   - The agent records each attempt, result, and rationale in a workspace artifact.
5. **Autonomous continuation**
   - The agent may keep iterating across continuation turns without human intervention while the
     ticket remains active.
6. **Tracker-visible summaries**
   - The workpad comment summarizes the current best result and recent experiments.

### Where this should live

The initial implementation should live in the **policy layer**, not the core orchestrator:

- `WORKFLOW.md` for repo-specific experiment rules,
- a dedicated skill such as `.codex/skills/experiment/SKILL.md`,
- normal continuation turns and existing workspace behavior.

This means the first version should be expressible **without changing the spec or orchestration
model**.

### Explicit non-decision

We are **not** making Symphony itself responsible for:

- choosing winners based on parsed metrics,
- automatically reverting failed experiments at the workspace layer,
- introducing a new `experiment:` config contract in the workflow schema,
- turning ordinary delivery tickets into endless experiment loops.

Those may become future enhancements, but they are not part of the initial direction.

---

## Why this decision

### 1. It fits Symphony's existing abstraction boundaries

Symphony already treats `WORKFLOW.md` and skills as the place where task-specific operating
protocols live. An experiment loop is a task protocol.

Putting the MVP in the policy layer preserves the current architecture:

- orchestrator stays tracker/scheduling focused,
- execution layer stays workspace/process focused,
- integration layer stays tracker focused,
- repo-specific experimentation rules remain versioned with the codebase.

### 2. It captures the best part of autoresearch

The most reusable idea in `autoresearch` is not the "never stop" rhetoric. It is the discipline
of:

- fixed evaluation,
- fixed budget,
- narrow edit surface,
- baseline-first comparison,
- explicit keep/discard logging.

Those are valuable for optimization tickets in normal software repos too.

### 3. It avoids distorting the main product

Most Symphony tickets are not benchmark search problems. They need:

- semantic correctness,
- tests and documentation,
- human review,
- integration safety,
- stable PR history.

Making metric-driven experimentation a default orchestration mode would weaken the product's core
software-delivery workflow.

### 4. It leaves room for a future orchestrator enhancement if needed

If teams later want stronger support, the natural next step is not a full new subsystem. It is a
small orchestration seam that lets a post-turn evaluation hook feed structured results back into
issue handling.

That enhancement should be justified by real usage, not introduced up front.

---

## Alternatives considered

### Make autoresearch a first-class Symphony subsystem

Add experiment-specific config, orchestrator logic, metric parsing, keep/discard state, and
workspace rollback behavior.

**Rejected.** Too much product weight for a narrow class of tickets. It would add core complexity
before proving demand.

### Do nothing; treat experiments as ad hoc prompt engineering

Leave experimentation entirely undocumented and repo-local.

**Rejected.** The pattern is useful enough to deserve a documented, reusable approach.
Without guidance, teams will reinvent inconsistent loops and logging formats.

### Add an `experiment:` section to `WORKFLOW.md` immediately

Define schema-level support for evaluation commands, objective direction, iteration caps, and path
constraints.

**Deferred.** This may become useful later, but the repo already has policy-layer tools that can
express the MVP. We should prove the workflow before hardening it into config.

### Add workspace-level automatic revert/reset support first

Teach Symphony to reset a workspace to a prior commit after a failed experiment.

**Deferred.** Useful for aggressive search loops, but not required for the first version. The skill
can initially handle commit/revert discipline itself, or use append-only experimentation on a
single issue branch.

---

## Consequences

**Makes easier:**
- Supporting benchmark-driven optimization tickets without changing Symphony's default operating
  model.
- Reusing a documented experiment protocol across repos.
- Capturing experiment history in a predictable format.
- Running long unattended optimization loops on GPU or specialized hosts through existing worker
  routing and workspace mechanics.

**Makes harder / watch out for:**
- The MVP relies on prompt/skill discipline instead of orchestrator enforcement.
- Without a structured post-turn evaluation API, keep/discard decisions remain agent-managed.
- Ordinary tickets must not accidentally inherit experiment-style autonomy.
- Teams may overuse this pattern for tasks that are not objectively measurable.

---

## Follow-on guidance

The rollout order followed so far has been:

1. document the workflow pattern,
2. add an experiment skill and template guidance.

The remaining preferred order is:

3. validate it on one benchmark-driven repo,
4. only then consider any spec or orchestrator extensions.

The first infrastructure enhancement worth revisiting later is a **post-turn evaluation hook with
structured output**. That would let Symphony consume experiment results without making the whole
system experiment-native.
