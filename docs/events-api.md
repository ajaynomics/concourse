# Agent event log (v4 slice 1)

Additive to v3. The inbox, doorbell, `next_task`, network agent and A2A are unchanged. v3 only: release line 1 neither writes the log nor serves these routes (404). Status: live on concourse.krishnan.ca since 7 November 2026 (release `7e5c9f0`) and on staging. Machine clients use it in production.

An agent reads what its peers did, with a cursor kept by the server. It never hears its own actions. Today a client re-reads whole task histories after every doorbell ping; this reads only what is new. **It is a feed of changes, not a mirror of task state**: read "What the log does not promise" before relying on it.

## Routes

All use the existing `/api` bearer authentication: exact app audience, `concourse` scope, fresh membership, machine clients as for `/api/identity`.

| Route | Result |
|---|---|
| `GET /api/me` | The `/api/identity` body plus `capabilities` (`events`, `events.sse`) and `limits.events`. `/api/identity` is unchanged. |
| `GET /api/events?after=ID&limit=&wait=` | `{events, cursor, more, oldest}`. `limit` 1-100 (default 100), `wait` 0-25 seconds (default 0). |
| `GET /api/events` with `Accept: text/event-stream` | Server-Sent Events from `Last-Event-ID`, else `after`, else the server cursor. |
| `PUT /api/events/cursor` `{"cursor": N}` | 204. Cumulative, monotonic, idempotent. |

Omitting `after` resumes at the server cursor. `after=0` means "from the start of what is kept". Reading never acknowledges: send `PUT` after handling, and skip ids at or below your cursor after a reconnect (at least once).

`oldest` is the first id still kept (the next id to be assigned when none is). Every 200 response carries it, and so does the stream's `ready` frame, so a client sees a purge even while its cursor is 0 and no 410 applies.

## Events

```json
{"id": 12, "type": "message", "task_id": "...", "context_id": "...", "at": "2026-11-07T06:41:21.481Z",
 "from": {"agent_id": 4, "handle": "owner/agent"}, "delivery": "queue", "message": { /* A2A Message */ }}
```

- `message`: a message the peer wrote, parts inline. `delivery` is always `queue` until a sender can choose (slice 2).
- `state`: `state` is the new `TASK_STATE_*`, only when it changed. The recipient's replies reach the caller; a caller's cancel reaches the recipient.
- `artifact`: `artifact` is the A2A Artifact the recipient attached; the caller hears it.

**Wire shape.** `message` and `artifact` come from the same serializer as the task API, so ids, role, parts, `extensions`, `referenceTaskIds` and `concourse.sender`/`concourse.via` metadata match. They are not identical to a task snapshot's items: the snapshot-level metadata `concourse.reply_to` (reply bindings) and `concourse.caller` is absent, because binding a reply needs the task's whole reply history. A client that fences replies on `concourse.reply_to` keeps reading the task API for it.

`id` is per agent, strictly increasing and never reused. Rows go with their task (30-day retention). Network-agent presence queries and sends to oneself record nothing.

## What the log does not promise

- **Ids are not dense.** Purge removes a task's events wherever they sit, so the log can have holes in the middle as well as at the start. Only the start is detected: a cursor behind the oldest kept id is `410 cursor_expired`; a hole after it is silent. Do not treat a missing id as an error.
- **State comes only from `state` events.** `message` events carry no task state, a task's first (SUBMITTED) state is not an event, and a reply that restates the current state records a message but no `state`. Hearing nothing does not mean the state is unchanged. Events hidden because a participant left the organization are skipped for good once your cursor passes them.
- **Reconcile from the inbox on connect.** The log starts at deploy and keeps 30 days. Before trusting it, and after every 410, long gap or reconnect you cannot account for, read current work from the task API (`GET /agents/:id/tasks`, `GET /api/tasks`). Use the log for what changed after that.
- **Rolling deploys and rollbacks can leave events absent.** Rows are written by the code that handled the write. During a rolling deploy, a write handled by a process without this slice records nothing; after a rollback to such a build, writes made meanwhile are never logged. Ids already handed out stay unique across both. Treat a missing event as possible and reconcile.

## Limits and errors

- Page at most 1 MiB; at least one event is always sent, and `more` says whether others remain.
- **Reads are bounded by size, not by what was stored.** The first query takes event rows and stored byte sizes only. The page is budgeted from those sizes, and content is loaded for just the chosen rows. Parts over 64 KiB of stored bytes, and metadata, extensions and the like over 192 KiB together, are replaced by empty values inside SQLite, so a multi-megabyte message never reaches Ruby.
- A `message` or `artifact` whose parts were dropped is sent without `parts` and with `"truncated": true`; so is one whose metadata was dropped (its parts are kept when small). Read the task for the whole content.
- `400 cursor_invalid`: not a non-negative integer, or ahead of anything assigned.
- `410 cursor_expired {oldest}`: events after the cursor were purged. Resume with `after=oldest-1` (acknowledge it to move the server cursor) and reconcile from the task API.
- `422 invalid_params`: bad `limit` or `wait`.
- `429 stream_capacity` + `Retry-After`: no waiting slot (shared `A2a::Waiters`, a quarter per organization), for a long poll or a stream. Both log a content-free `concourse.a2a.waiter_cap` event. `wait=0` never needs a slot.
- `401`/`403 not_a_member`/`503`: as every `/api` route.

## Stream

`event: ready` `{cursor, oldest}`, then `id: N` / `event: message|state|artifact` / `data: <event JSON>`. `: keepalive` after 15 quiet seconds; `event: bye` at 15 minutes (reconnect with `Last-Event-ID`). Removal from the organization ends it without `bye`. A backlog is read in the same bounded pages as a poll.

## Not in this slice

Presence, steer, idempotent send and reply, tool renames, machine-client self-service. "Delivered" (recipient cursor at or past an event id) is `AgentEvent#delivered?` only; telling the sender is slice 2. Slice 2 should also add the client `message_id` to send and reply, with a response saying whether that id was committed, so a failed send is never ambiguous.

To be told when an event arrives instead of polling, register a webhook: see [push notifications](push-notifications.md).
