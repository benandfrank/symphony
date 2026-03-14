---
name: experiment
description: |
  Run a benchmark-driven optimization loop for tickets with a fixed evaluation
  command, an objective success metric, and permission for autonomous iteration.
---

# Experiment

Use this skill for optimization or research tickets where success is empirically measurable.

This skill is **opt-in**. Do not use it for ordinary delivery tickets.

## Entry criteria

Only use this skill when all of the following are true:

- The ticket explicitly calls for optimization, tuning, or empirical comparison.
- There is a fixed evaluation command or harness.
- The metric has a clear direction (`lower is better` or `higher is better`).
- You can establish a baseline before editing code.

If any of those are missing, stop using this skill and return to the normal workflow.

## Core rules

1. **Baseline first**
   - The first run is always the baseline.
   - Do not change code before recording the baseline result.
2. **One experiment at a time**
   - Change one hypothesis at a time unless the workflow explicitly calls for a combined change.
3. **Log every attempt**
   - Append each run to a workspace ledger.
4. **Keep the workpad concise**
   - The workpad should summarize the current best result, latest attempt, and next hypothesis.
   - Do not dump full experiment logs into the tracker comment.
5. **Stay objective**
   - Keep/discard decisions should follow the declared metric and any workflow-defined simplicity tradeoffs.
6. **Respect repo quality bars**
   - If the ticket still requires tests, docs, or `make all`, those requirements still apply.

## Recommended workspace ledger

Prefer one of:

- `results.tsv`
- `experiments/results.tsv`

Recommended header:

```tsv
commit	metric	status	description
```

If memory or runtime matters, use:

```tsv
commit	metric	memory_gb	status	description
```

Status values:

- `baseline`
- `keep`
- `discard`
- `crash`

## Loop

### Step 1: Confirm the experiment contract

Before running anything, write these into the workpad:

- evaluation command,
- metric name,
- success direction,
- ledger path,
- any edit-scope constraints,
- stop conditions or hard blockers.

If the contract is ambiguous, do not improvise a research loop.

### Step 2: Run the baseline

1. Ensure the workspace is in a known state.
2. Run the evaluation command with no experiment edits.
3. Record the result in the ledger as `baseline`.
4. Summarize the baseline in the workpad.

### Step 3: Plan a single hypothesis

Write a short hypothesis before editing:

- what will change,
- why it might improve the metric,
- what downside to watch for.

Prefer simple changes with clear reasoning.

### Step 4: Execute the experiment

1. Make the smallest useful code change.
2. Commit if the repo workflow needs commit-level experiment logging.
3. Run the evaluation command.
4. Record the result in the ledger.
5. Compare with the current best result.

### Step 5: Keep or discard

- Mark `keep` when the result improves meaningfully, or when the workflow explicitly values equal-or-better simplification.
- Mark `discard` when the result is worse or the complexity cost is not justified.
- Mark `crash` when the run fails in a way that invalidates the attempt.

If discarding, revert cleanly using normal git hygiene. Do not leave failed experiment debris in the branch.

### Step 6: Update the workpad

After each attempt, update the workpad with:

- current best result,
- latest attempt result,
- whether it was kept or discarded,
- next hypothesis.

Keep this short and reviewer-friendly.

### Step 7: Continue autonomously

If the issue remains active and the experiment contract still holds, continue with the next hypothesis.
Do not stop just to ask whether to keep going.

## Guardrails

- Do not use this skill when success depends mainly on product judgment or open-ended code quality.
- Do not run broad, multi-file thrash when the ticket defines a narrow optimization surface.
- Do not treat tiny metric movement as automatically valuable if it adds substantial complexity.
- Do not bypass required tests or repo validation just because the metric improved.
- Do not post a new tracker comment per experiment; keep one persistent workpad comment updated.

## Workpad summary template

Use a compact structure like:

```md
### Experiment Status
- Best metric: 0.9974 (commit abc1234)
- Latest attempt: 0.9981 (`discard`)
- Evaluation: `uv run train.py > run.log 2>&1`
- Ledger: `results.tsv`
- Next hypothesis: reduce warmdown ratio
```

## Exit conditions

Exit experiment mode when any of these become true:

- the objective metric or evaluation command is no longer reliable,
- the issue requires normal delivery work instead of empirical search,
- the environment or required secrets are missing,
- the ticket reaches a workflow state that requires handoff or merge flow,
- diminishing returns suggest the next work should be human-directed.
