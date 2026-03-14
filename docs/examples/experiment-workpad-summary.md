### Experiment Status
- Direction: lower is better
- Best metric: 0.996800 (commit `bcd2345`)
- Latest attempt: 1.002100 (`discard`)
- Evaluation: `uv run train.py > run.log 2>&1`
- Ledger: `results.tsv`
- Next hypothesis: reduce warmdown ratio

### Notes
- Baseline established before any code edits.
- Discarded the activation-function change because it regressed the metric.
- Continuing with small, single-hypothesis iterations.
