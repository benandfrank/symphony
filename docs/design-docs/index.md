# Design Docs

Lightweight ADR-style records for significant architectural decisions made in Symphony.

## When to write a design doc

Write a design doc when a change:
- Introduces a new subsystem or adapter (e.g., adding a tracker backend).
- Alters a core abstraction boundary (e.g., renaming the issue struct, changing the tracker
  behaviour contract).
- Makes a deliberate trade-off worth preserving for future contributors.
- Is non-obvious and would otherwise prompt "why did we do it this way?" questions.

Bug fixes, routine feature additions, and config changes do not need design docs.

## Format

Keep them short. A useful design doc answers:

1. **Context** — what problem or constraint prompted this?
2. **Decision** — what was chosen and why?
3. **Alternatives considered** — what was ruled out and why?
4. **Consequences** — what does this make easier or harder going forward?

## Index

| Doc | Summary |
|-----|---------|
| [tracker-abstraction.md](tracker-abstraction.md) | Close Linear leaks from the abstraction layer; add ClickUp as a first-class tracker backend |
