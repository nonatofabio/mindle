# Ambient Mindle Collaboration — Design

**Date:** 2026-05-11
**Status:** Approved for implementation
**Branch target:** new `feat/mcp-watch` off `feat/mcp-phase2`

## Problem

Phase 2 shipped a working collaboration loop, but it's strictly request-driven: the user has to *ask* the agent to look at the file ("check my annotations"). The desired experience is the opposite — the user annotates in Mindle and the agent picks them up on its own and answers, without being prompted each time. Mindle becomes a parallel conversation surface: the user adds notes in the document, the agent responds inline in the threads, and continuity lives in the file + threads rather than in chat history.

## Goals

- The agent picks up new annotations and thread replies on its own while a watch session is active.
- Works in **any MCP client** (Claude Code, Codex, Cursor, custom agents) — no client-specific glue required.
- The agent's behavior is described well enough by the MCP tool surface that a vanilla agent (no skill) can run the loop just by being told "watch my Mindle annotations."
- Optional Claude Code skill makes invocation frictionless but is not required for correctness.

## Non-Goals (v1)

- **Cold wake from annotation.** The agent must already be running with a watch session active. We do not spawn agents from OS-level hooks. (Considered and rejected; revisit as Phase 4.)
- **Mid-edit reactivity.** Watch fires on annotation lifecycle events (create / thread-reply / delete), not while the user is typing the note. The reply Return-to-commit gesture is the commit point.
- **Cross-window event ordering guarantees.** If the user has two windows on the same file and annotates in both at once, the agent sees both events in close succession but no strict ordering guarantee beyond per-window monotonicity.

## Architecture

```
┌──────────────────┐         ┌──────────────────────┐         ┌──────────────────┐
│  Mindle (server) │         │   mindle-mcp helper  │         │      Agent       │
│                  │         │                      │         │                  │
│ DocumentStore    │         │ stdio JSON-RPC ←─────┼─────────┼─ tools/call     │
│ mutation         │         │                      │         │   wait_for_…    │
│   │              │         │ socket request ──────┼─→ Mindle│                  │
│   ▼              │  pushes │   {op:"wait_for_…",  │         │                  │
│ event buffer ────┼────────►│    since_event_id,   │         │                  │
│ (per-session)    │  events │    timeout_seconds}  │         │                  │
│                  │  ◄──────│                      │         │                  │
│                  │ response│ socket response ◄────┤         │ result with     │
│                  │         │   {events:[…]}       ├────────►│ event payload  │
└──────────────────┘         └──────────────────────┘         └──────────────────┘
```

The socket protocol stays length-prefixed JSON. A new op `wait_for_annotation_event` carries the long-poll semantics. The helper blocks on the socket read until Mindle responds. Mindle responds either when an event arrives or when its own timeout elapses.

### Why long-poll vs MCP server notifications

MCP servers *can* send notifications, but in practice MCP clients route only a fixed set (`notifications/tools/list_changed`, `notifications/resources/updated`, etc.) to internal handlers; arbitrary application-level notifications don't reliably become agent-visible context. A request/response tool call with a timeout is the most portable contract and works in every MCP client today.

## Event Model

### Wakeup-worthy events

Three types wake the agent:

1. `annotation_created` — user added a new annotation (highlight or note)
2. `thread_reply` — user added a message to an existing annotation's thread
3. `annotation_deleted` — user deleted an annotation

Events authored by the agent (agent-created annotations, agent thread comments, agent clears) are filtered server-side and **never** wake the agent. This prevents self-driven loops.

Annotation note edits do not wake the agent (rare; user can re-annotate if they truly need a fresh take).

### Event payload

```json
{
  "event_id": 42,
  "type": "thread_reply",
  "path": "/abs/path/to/file.md",
  "annotation_id": "UUID",
  "annotation": { /* same shape as get_annotations entry, includes thread */ },
  "message_id": "UUID",      // only for thread_reply
  "occurred_at": "ISO-8601"
}
```

Every event carries the file path so the agent always knows where the event occurred without needing a separate lookup. The full annotation (including its thread) is embedded so the agent can act on a single payload without an extra `get_annotations` round-trip.

### Per-session event log

Mindle maintains a monotonic `event_id` counter per app launch. The event log is in-memory (no persistence across Mindle restarts — that's a re-list-and-resync on the agent side, see Reconnection). When a wakeup-worthy event happens, Mindle appends it to the log and signals any waiting `wait_for_annotation_event` consumer.

The log retains the last **256 events** in memory. Older events are dropped — agents that fall further behind get a `gap` signal (see Reconnection).

## MCP Tool Surface

One new tool:

```
wait_for_annotation_event(
  timeout_seconds: int = 60,         // server clamps to [5, 300]
  since_event_id: int | null = null  // returned by previous call
) → {
  events: [Event, …],   // possibly empty if timeout elapsed
  last_event_id: int,   // pass this as since_event_id in the next call
  gap: bool             // true if events were dropped between since_event_id and now
}
```

The agent's loop:

```
baseline:
  files = list_open_files()
  for path in files: get_annotations(path)
  last = null

watch:
  while running:
    resp = wait_for_annotation_event(timeout_seconds=60, since_event_id=last)
    if resp.gap:
      // we fell behind; rebaseline
      for path in list_open_files(): get_annotations(path)
    for event in resp.events:
      handle(event)
    last = resp.last_event_id
```

`handle(event)` is the agent's policy: for `created` and `thread_reply` it reads the surrounding file context and either edits the file then clears, or posts a `comment_on_annotation` reply. For `deleted` it acknowledges silently (no action; the agent might briefly note the deletion in its own chain of thought).

## Reconnection and Gap Handling

The helper can be restarted (e.g., user quits and reopens Claude Code), or Mindle can be restarted. Three cases:

1. **Helper restart, Mindle alive.** Agent's first `wait_for_annotation_event` after restart passes the last known `event_id` (if it persisted state) or `null` (cold start). If `since_event_id < oldest_in_log`, Mindle returns `gap: true` and the agent re-baselines. If `null`, Mindle returns events from now forward — the agent re-baselines anyway as part of session start.
2. **Mindle restart.** Mindle's event_id counter resets to 0 on launch. The agent's old `since_event_id` is now ahead of Mindle's; Mindle treats this as `since_event_id=null` and the agent rebaselines.
3. **Long idle.** If the agent's loop sleeps in `wait_for_annotation_event` for the full timeout with no events, it gets an empty array and a refreshed `last_event_id` (== input `since_event_id`) — no rebaseline needed. The loop continues.

Cold-start state is not persisted across helper restarts. Agents that care about not missing events while the helper was down can persist `last_event_id` themselves (e.g., in a project state file); without that, restart = rebaseline.

## Filtering Self-Authored Events

The agent's own MCP calls — `clear_annotation`, `comment_on_annotation`, `create_annotation` — must not wake the agent. Because the current helper opens a fresh Unix-socket connection per request (see `callMindle` in `Sources/MindleMCP/main.swift`), socket identity alone can't link a mutation to a wait call — they ride on different connections.

Instead, the helper generates a `client_id` (UUID) once at startup and includes it in every JSON request body it sends to Mindle. Mindle's `MCPServer.dispatch` reads `request["client_id"]` and, for mutating ops, tags the event it appends to the log with that id. When `wait_for_annotation_event` returns events for a given `client_id`, events whose tag matches that client_id are filtered out.

Result: the agent never sees its own mutations as wakeup events, regardless of how many separate socket calls the helper makes. Other clients (a second agent, user actions through the Mindle UI, untagged sources like the file watcher) still see those events normally.

## Cross-Agent Portability

The tool description on `wait_for_annotation_event` carries the protocol guidance verbatim — what to call before entering the loop, how to handle events, what `gap` means, when to stop. Any MCP client can run this loop by being told "watch my Mindle annotations and answer them as they come in." No client-specific glue.

The Claude Code skill (next section) is a convenience for invocation, not a requirement for correctness.

## Optional Claude Code Skill

`docs/skills/mindle-collaboration.md` (bundled with the app and instructable via setup menu): a Claude Code skill that codifies the watch loop with project-tuned heuristics — e.g., when to comment-and-wait vs edit-and-clear, how to handle conflicting annotations, what counts as "user said stop." Users invoke it as `/mindle-collaboration` or by natural prompt. Skill body has the full protocol; tool descriptions have the same protocol in abbreviated form so non-skill agents work too.

## Edge Cases

| Case | Behavior |
|------|----------|
| Two windows on the same file, user annotates in one | Agent gets one event, addresses it, both windows reflect the result via shared sidecar |
| User adds annotation A, agent starts addressing, user adds annotation B | Both events queued; agent finishes A's thread, then sees B on next wait call |
| Agent posts a comment; user replies in same second | Agent's mutation event is filtered (self); user's reply wakes agent on next wait |
| User closes the file while agent is mid-edit | File still exists on disk; agent's edit succeeds; on reopen, user sees the diff banner |
| User quits Mindle mid-watch | Helper's next socket call fails; helper returns an error; agent's wait returns an error; agent exits loop |
| Mindle restarts while agent is mid-wait | Helper's socket read returns EOF; helper returns error; agent reconnects on next call and rebaselines |

## Phase 4 Future Work (out of scope here)

- **Cold-wake hook.** Mindle-side configurable shell command on annotation events, for users who want a fresh `claude` session spawned automatically. Different security model (what can the hook do?), different UX (one-shot session). Layer on top of, not instead of, the watch loop.
- **Diff-chunk chip surfacing.** When the agent clears an annotation with a summary, show the summary as a hoverable chip on the corresponding diff chunk in the reader. Closes the user-side review loop visually.
- **Multi-agent sessions.** Currently each MCP socket connection is one agent. If multiple agents are watching the same Mindle, they each get full events (other-agent mutations are NOT filtered). Future work: a `consume` flag so an agent can claim an annotation, preventing others from acting on it.

## Acceptance Criteria

1. User adds an annotation in Mindle; agent's running watch loop receives `annotation_created` event with full payload, including file path.
2. User replies in a thread; agent receives `thread_reply` event including the full thread.
3. Agent's own `comment_on_annotation` call does NOT trigger a wakeup event on the wait call sharing the same `client_id`.
4. Agent stops by killing the wait loop with a user prompt; Mindle has no zombie state.
5. After Mindle restart, agent's next `wait_for_annotation_event` returns `gap: true` and the agent rebaselines.
6. Default timeout (60s) elapses with no events → agent receives `{events: [], gap: false}` and continues.

## Open Questions

None at this time — all scope questions resolved during brainstorming.
