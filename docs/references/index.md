# References

LLM-friendly reference documents for external APIs and tools that Symphony integrates with.

These files are intended to be attached as context when an agent is working on the integration
layer, reducing hallucination on third-party API details.

## Conventions

- One file per external system.
- Plain Markdown or `.txt` (`llms.txt`-style) — no heavy formatting.
- Include: auth model, base URL, key endpoints/fields, pagination scheme, error shapes, and
  any known gotchas.
- Keep in sync with the integration code; update when the API version or behavior changes.

## Index

| File | Covers |
|------|--------|
| [clickup-api.md](clickup-api.md) | ClickUp REST API: auth, task fields, pagination, status update, comments, dependencies |
