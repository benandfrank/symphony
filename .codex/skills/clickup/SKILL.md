---
name: clickup
description: |
  Use Symphony's `clickup_api` client tool for ClickUp REST operations
  such as task status updates, comments, and task lookups.
---

# ClickUp API

Use this skill for ClickUp REST work during Symphony app-server sessions.

## Primary tool

Use the `clickup_api` client tool exposed by Symphony's app-server session.
It reuses Symphony's configured ClickUp auth for the session.

Tool input:

```json
{
  "method": "GET | POST | PUT",
  "path": "/task/{task_id} | /list/{list_id}/... | /team/{team_id}/...",
  "body": { "optional": "JSON object for POST/PUT" }
}
```

Tool behavior:

- One REST call per tool invocation.
- Methods restricted to `GET`, `POST`, `PUT`. `DELETE` is not allowed.
- Paths must start with `/task/`, `/list/`, or `/team/`.
- Request body is not allowed for `GET` requests.
- Request body and response payload are size-limited.
- Transport and auth errors are redacted in tool output.

## Common workflows

### Fetch a task by ID

```json
{
  "method": "GET",
  "path": "/task/{task_id}"
}
```

Response includes: `id`, `custom_id`, `name`, `description`, `status`,
`priority`, `assignees`, `tags`, `url`, `dependencies`.

### Update task status

```json
{
  "method": "PUT",
  "path": "/task/{task_id}",
  "body": { "status": "in progress" }
}
```

Status names are case-insensitive in the ClickUp API.

### Create a comment on a task

```json
{
  "method": "POST",
  "path": "/task/{task_id}/comment",
  "body": { "comment_text": "## Workpad\n\nProgress notes here." }
}
```

### List tasks in a list (filtered by status)

```json
{
  "method": "GET",
  "path": "/list/{list_id}/task?statuses[]=in%20progress&page=0&include_closed=false"
}
```

Pagination: increment `page` (0, 1, 2, …) until `tasks` array is empty.

### Fetch task comments

```json
{
  "method": "GET",
  "path": "/task/{task_id}/comment"
}
```

### Update a comment

```json
{
  "method": "PUT",
  "path": "/task/{task_id}/comment/{comment_id}",
  "body": { "comment_text": "Updated workpad content." }
}
```

Note: ClickUp comment update path includes both `task_id` and `comment_id`.

### Fetch team information

```json
{
  "method": "GET",
  "path": "/team/{team_id}"
}
```

## Key differences from Linear

| Concern | Linear (`linear_graphql`) | ClickUp (`clickup_api`) |
|---------|--------------------------|------------------------|
| Transport | GraphQL | REST |
| State update | Resolve `stateId` first, then `issueUpdate` mutation | `PUT /task/{id}` with `{"status": "name"}` directly |
| Comments | `commentCreate` / `commentUpdate` mutations | `POST` / `PUT` on `/task/{id}/comment` |
| Assignees | Single `assignee` | Array of `assignees` |
| Branch name | Native `branchName` field | Not available |
| Labels | `labels.nodes[].name` | `tags[].name` |

## Usage rules

- Use `clickup_api` for all ClickUp interactions during agent sessions.
- Do not introduce shell-based `curl` helpers for ClickUp API access.
- Keep requests narrowly scoped; fetch only the fields/tasks you need.
- For status transitions, use the status name string directly — no ID
  resolution step is needed (unlike Linear).
- Prefer the workpad comment pattern: one persistent comment per task for
  progress tracking, updated via `PUT`.
