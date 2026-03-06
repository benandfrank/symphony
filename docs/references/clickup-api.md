# ClickUp REST API Reference

LLM-friendly reference for the ClickUp API v2 as used by Symphony's ClickUp adapter.

**Base URL:** `https://api.clickup.com/api/v2`  
**Auth:** `Authorization: <api_token>` header (personal API token or OAuth token)  
**Content-Type:** `application/json`  
**Rate limits:** 100 requests per minute per token (429 response when exceeded)

---

## Task Fields (GET /task/{task_id})

```json
{
  "id": "abc123",
  "custom_id": "PROJ-42",
  "name": "Fix the login bug",
  "description": "Users can't log in on Safari",
  "status": { "status": "in progress", "type": "custom" },
  "priority": { "id": "2", "priority": "high" },
  "assignees": [{ "id": 12345, "username": "jdoe" }],
  "tags": [{ "name": "bug" }, { "name": "frontend" }],
  "url": "https://app.clickup.com/t/abc123",
  "date_created": "1677000000000",
  "date_updated": "1677100000000",
  "dependencies": []
}
```

Key differences from Linear:
- `status.status` is the status name string (lowercase). Compare case-insensitively.
- `priority.id` is a string `"1"`–`"4"` (1=urgent, 4=low). May be `null`.
- `assignees` is an array (Linear has a single `assignee`). Use first assignee.
- `assignees[].id` is an integer, not a string UUID.
- `tags[].name` maps to labels. Normalize to lowercase.
- `date_created` and `date_updated` are Unix millisecond timestamps (strings).
- No native `branchName` field — always `nil` in the Issue struct.
- `custom_id` is optional (workspace setting). When present, use it as `identifier`.
  When absent, use `id`.

---

## Fetch Tasks by List (Candidate Issues)

```
GET /list/{list_id}/task?statuses[]={state1}&statuses[]={state2}&page=0&include_closed=false
```

- Pagination: page-based. Up to 100 tasks per page.
- Increment `page` (0, 1, 2, …) until response `tasks` array is empty.
- `statuses[]` param filters by status name (case-insensitive match).
- `include_closed=false` excludes closed/archived tasks.

---

## Fetch Single Task

```
GET /task/{task_id}?include_subtasks=false
```

- No batch task-by-ID endpoint exists.
- For reconciliation (`fetch_issue_states_by_ids`), call this per task ID.
- Use bounded parallelism (max 5 concurrent) to stay within rate limits.

---

## Update Task Status

```
PUT /task/{task_id}
Content-Type: application/json

{ "status": "done" }
```

- Status name is a string. ClickUp matches case-insensitively.
- No state ID resolution needed (unlike Linear).

---

## Create Comment

```
POST /task/{task_id}/comment
Content-Type: application/json

{ "comment_text": "## Codex Workpad\n\nProgress notes here." }
```

- `comment_text` is plain text or markdown.
- Returns `{ "id": "comment-id", "hist_id": "...", ... }`.

---

## Dependencies (Blocker Mapping)

**Spike findings (corrected 2026-03-05):** ClickUp represents task dependencies in two ways.
Initial implementation had type 0/1 semantics inverted; corrected per ClickUp API docs.

### Option A: Task payload `dependencies` field

When fetching a task with `?include_subtasks=true` or via list endpoint, the response may
include a `dependencies` array:

```json
{
  "dependencies": [
    {
      "task_id": "blocked_task_id",
      "depends_on": "blocker_task_id",
      "type": 1,
      "userid": "user123"
    }
  ]
}
```

- `type: 0` means "waiting on" (current task depends on `depends_on` task).
- `type: 1` means "blocking" (current task blocks `task_id` task).
- To extract `blocked_by`: filter where `task_id == current_task.id` and `type == 0`.
  The `depends_on` value is the blocker task ID.

### Option B: Dedicated dependency endpoint

```
GET /task/{task_id}/dependency
```

Returns the same dependency objects. Use this when the task payload doesn't include
dependencies inline.

**Recommendation for Symphony adapter:**
- First try to read `dependencies` from the task payload (Option A).
- If the field is absent or empty, and blocker detection is needed, fall back to the
  dedicated endpoint (Option B).
- For candidate issue polling (list endpoint), dependencies may not be included inline.
  Evaluate whether the extra API calls per task are worth the rate-limit cost.

**Current implementation note:**
- The current Elixir ClickUp adapter reads inline task `dependencies` when they are present.
- When a task payload omits `dependencies`, it falls back to `GET /task/{task_id}/dependency`
  during candidate polling and reconciliation.
- As a result, ClickUp `blocked_by` normalization now uses the dedicated dependency endpoint as a
  completeness fallback rather than remaining inline-only best-effort behavior.

---

## Error Responses

```json
{ "err": "Token invalid", "ECODE": "OAUTH_025" }
```

- HTTP 401: invalid or expired token
- HTTP 429: rate limit exceeded (retry after `Retry-After` header seconds)
- HTTP 404: task/list not found
- HTTP 500+: server error (retry with backoff)

---

## Known Gotchas

- Status names are **case-insensitive** in the API but stored in mixed case. Normalize both
  sides when comparing.
- `custom_id` requires a workspace-level setting to be enabled. Not all workspaces have it.
- Archived tasks may appear in results unless `include_closed=false` is set.
- Rate limits are per-token, not per-IP. Multiple Symphony instances sharing a token will
  share the rate limit budget.
- `assignees[].id` is an **integer** in ClickUp (Linear uses string UUIDs). Cast to string
  when normalizing to `Issue.assignee_id`.
