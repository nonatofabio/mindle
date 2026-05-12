# Ambient Mindle Collaboration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a long-poll MCP tool `wait_for_annotation_event` that lets an agent watch a user's Mindle annotations across all open files and react to user events (annotation created, thread reply, annotation deleted) in an ambient collaboration loop.

**Architecture:** A new `AnnotationEventLog` (MainActor singleton, in-memory ring buffer of 256 events) sits next to `MCPServer`. `DocumentStore` mutations append events to the log, tagged with the originating `clientID` (UUID per MCP helper instance, nil for user UI actions). `MCPServer` adds a `wait_for_annotation_event` op that awaits the log with a timeout and filters out events whose `clientID` matches the calling client — so the agent never wakes on its own mutations.

**Tech Stack:** Swift, MainActor isolation, `withCheckedContinuation` for waiter primitives, length-prefixed JSON over a Unix-domain socket. No new external dependencies. Verification is build + stdio smoke tests + manual UI eyeballing.

**Spec reference:** `docs/superpowers/specs/2026-05-11-ambient-mindle-collaboration-design.md`

---

## File Structure

**Create:**
- `Sources/mindle/AnnotationEventLog.swift` — `AnnotationEvent` struct, `AnnotationEventLog` singleton with append/wait API.

**Modify:**
- `Sources/mindle/DocumentStore.swift` — append events on every annotation mutation (user UI path and MCP path), accept `clientID` through MCP-side mutations so events get tagged.
- `Sources/mindle/MindleApp.swift` — `AppDelegate` aggregator helpers thread `clientID` through to `DocumentStore`.
- `Sources/mindle/MCPServer.swift` — extract `client_id` from every request; pass through to mutations; new `wait_for_annotation_event` op.
- `Sources/MindleMCP/main.swift` — generate one `clientID` at helper startup; include `client_id` in every JSON body; declare and dispatch the new `wait_for_annotation_event` tool.

---

## Task 1: Create AnnotationEventLog skeleton (no waiters yet)

**Files:**
- Create: `Sources/mindle/AnnotationEventLog.swift`

- [ ] **Step 1: Create the file**

Write `Sources/mindle/AnnotationEventLog.swift`:

```swift
import Foundation

/// One entry in the cross-window event log. Mutations of any annotation
/// (created, reply added to thread, deleted) become events. The agent
/// pulls them through `MCPServer.wait_for_annotation_event` to drive
/// an ambient collaboration loop.
struct AnnotationEvent {
    enum Kind: String {
        case created
        case threadReply = "thread_reply"
        case deleted
    }

    let id: Int
    let kind: Kind
    let path: String
    let annotationID: UUID
    /// Full annotation payload for created/threadReply. nil for deleted —
    /// the annotation no longer exists by the time consumers see it.
    let annotation: Annotation?
    /// For threadReply: the id of the new message. nil otherwise.
    let messageID: UUID?
    let occurredAt: Date
    /// UUID of the MCP client whose mutation produced this event, or nil
    /// for user UI actions. `wait_for_annotation_event` filters out
    /// events whose clientID equals the caller's clientID — the agent
    /// must not wake on its own writes.
    let clientID: String?
}

/// MainActor-isolated event log. Ring-buffered to the last 256 events;
/// older events drop and consumers that fall further behind receive a
/// gap signal so they can rebaseline via get_annotations.
@MainActor
final class AnnotationEventLog {
    static let shared = AnnotationEventLog()

    private var events: [AnnotationEvent] = []
    private var nextID: Int = 1
    private let capacity: Int = 256

    private init() {}

    /// Append a new event. Caller supplies the payload (kind, path, etc.);
    /// the log assigns the monotonic id and timestamp.
    func append(
        kind: AnnotationEvent.Kind,
        path: String,
        annotationID: UUID,
        annotation: Annotation?,
        messageID: UUID? = nil,
        clientID: String?
    ) {
        let event = AnnotationEvent(
            id: nextID,
            kind: kind,
            path: path,
            annotationID: annotationID,
            annotation: annotation,
            messageID: messageID,
            occurredAt: Date(),
            clientID: clientID
        )
        nextID += 1
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    /// Read-only snapshot. Returns events with id > sinceID whose
    /// clientID is not equal to `excludingClientID`. The caller uses
    /// the result's `gap` to decide whether to rebaseline.
    func snapshot(
        sinceID: Int?,
        excludingClientID: String?
    ) -> (events: [AnnotationEvent], lastEventID: Int, gap: Bool) {
        let lastID = (nextID - 1)
        let oldestID = events.first?.id ?? 1
        let effectiveSince = sinceID ?? lastID

        let gap: Bool = {
            if let since = sinceID, since < oldestID - 1 { return true }
            return false
        }()

        let filtered = events.filter { ev in
            ev.id > effectiveSince &&
            ev.clientID != excludingClientID
        }
        return (filtered, lastID, gap)
    }
}
```

- [ ] **Step 2: Verify build**

Run: `./build.sh 2>&1 | tail -5`
Expected: `✓ Built build/Mindle.app`

- [ ] **Step 3: Commit**

```bash
git add Sources/mindle/AnnotationEventLog.swift
git commit -m "Add AnnotationEventLog skeleton (append + snapshot, no waiters yet)"
```

---

## Task 2: Append events on user-driven UI mutations

**Files:**
- Modify: `Sources/mindle/DocumentStore.swift`

User UI paths emit events with `clientID: nil`. The four user mutation sites:
- `highlightSelection()` — both add and remove branches
- `addNoteToSelection()` — add-new-annotation branch only (focus-existing is not a mutation)
- `delete(id:)` — single deletion
- `updateNote(id:note:)` — explicitly **not** an event per spec; do nothing

User thread replies come through `appendThreadMessage(forPath:annotationID:author:text:)`. That method is called from both UI (`AnnotationCard.commitReply` with `author: "user"`) and MCP (`comment_on_annotation` with `author: "agent"`). The agent path will pass a non-nil clientID in Task 3; for now we add the parameter and default it to nil.

- [ ] **Step 1: Add clientID parameter to MCP-relevant mutation methods**

In `Sources/mindle/DocumentStore.swift`, change the following method signatures to accept an optional `clientID` argument (default `nil` so existing UI call sites keep working unchanged):

```swift
func appendThreadMessage(
    forPath path: String,
    annotationID: UUID,
    author: String,
    text: String,
    clientID: String? = nil
) -> Bool {
    // existing body
}

func createAgentAnnotation(
    forPath path: String,
    text: String,
    prefix: String,
    suffix: String,
    note: String,
    clientID: String? = nil
) -> UUID? {
    // existing body
}

@discardableResult
func removeAnnotation(
    forPath path: String,
    id: UUID,
    summary: String,
    clientID: String? = nil
) -> Bool {
    // existing body
}
```

- [ ] **Step 2: Append events inside each user mutation site**

In `highlightSelection()`, the existing body has an add path and a toggle-off path. Append events on each:

```swift
func highlightSelection() {
    guard hasSelection else { NSSound.beep(); return }
    if let i = annotations.firstIndex(where: {
        $0.text == selectionText && $0.prefix == selectionPrefix && $0.suffix == selectionSuffix
    }) {
        let removed = annotations[i]
        annotations.remove(at: i)
        if let url = fileURL {
            AnnotationEventLog.shared.append(
                kind: .deleted,
                path: url.path,
                annotationID: removed.id,
                annotation: nil,
                clientID: nil
            )
        }
    } else {
        let ann = Annotation(
            text: selectionText,
            prefix: selectionPrefix,
            suffix: selectionSuffix,
            note: ""
        )
        annotations.append(ann)
        if let url = fileURL {
            AnnotationEventLog.shared.append(
                kind: .created,
                path: url.path,
                annotationID: ann.id,
                annotation: ann,
                clientID: nil
            )
        }
    }
    saveSidecar()
}
```

In `addNoteToSelection()`, only the new-annotation branch emits:

```swift
func addNoteToSelection() {
    guard hasSelection else { NSSound.beep(); return }
    showAnnotations = true
    if let existing = annotations.first(where: {
        $0.text == selectionText && $0.prefix == selectionPrefix && $0.suffix == selectionSuffix
    }) {
        editingAnnotationID = existing.id
        focusedAnnotation = existing.id
    } else {
        let ann = Annotation(
            text: selectionText,
            prefix: selectionPrefix,
            suffix: selectionSuffix,
            note: ""
        )
        annotations.append(ann)
        editingAnnotationID = ann.id
        focusedAnnotation = ann.id
        if let url = fileURL {
            AnnotationEventLog.shared.append(
                kind: .created,
                path: url.path,
                annotationID: ann.id,
                annotation: ann,
                clientID: nil
            )
        }
        saveSidecar()
    }
}
```

In `delete(id:)`:

```swift
func delete(id: UUID) {
    guard let url = fileURL else {
        annotations.removeAll { $0.id == id }
        saveSidecar()
        return
    }
    let removed = annotations.first(where: { $0.id == id })
    annotations.removeAll { $0.id == id }
    if removed != nil {
        AnnotationEventLog.shared.append(
            kind: .deleted,
            path: url.path,
            annotationID: id,
            annotation: nil,
            clientID: nil
        )
    }
    saveSidecar()
}
```

- [ ] **Step 3: Append thread-reply events inside `appendThreadMessage`**

Update both branches (active-tab and inactive-tab) to append a `threadReply` event before returning true. After the existing mutation, before the `return true`:

```swift
let updatedAnnotation = /* the annotation after mutation — fetch via firstIndex */
AnnotationEventLog.shared.append(
    kind: .threadReply,
    path: path,
    annotationID: annotationID,
    annotation: updatedAnnotation,
    messageID: message.id,
    clientID: clientID
)
```

Full updated method body:

```swift
@discardableResult
func appendThreadMessage(
    forPath path: String,
    annotationID: UUID,
    author: String,
    text: String,
    clientID: String? = nil
) -> Bool {
    let message = AnnotationMessage(author: author, text: text)
    if let active = activeTabID,
       let i = tabs.firstIndex(where: { $0.id == active }),
       tabs[i].fileURL.path == path {
        guard let j = annotations.firstIndex(where: { $0.id == annotationID }) else {
            return false
        }
        var thread = annotations[j].thread ?? []
        thread.append(message)
        annotations[j].thread = thread
        saveSidecar()
        AnnotationEventLog.shared.append(
            kind: .threadReply,
            path: path,
            annotationID: annotationID,
            annotation: annotations[j],
            messageID: message.id,
            clientID: clientID
        )
        return true
    }
    if let i = tabs.firstIndex(where: { $0.fileURL.path == path }) {
        guard let j = tabs[i].annotations.firstIndex(where: { $0.id == annotationID }) else {
            return false
        }
        var thread = tabs[i].annotations[j].thread ?? []
        thread.append(message)
        tabs[i].annotations[j].thread = thread
        saveSidecar(forTab: tabs[i])
        AnnotationEventLog.shared.append(
            kind: .threadReply,
            path: path,
            annotationID: annotationID,
            annotation: tabs[i].annotations[j],
            messageID: message.id,
            clientID: clientID
        )
        return true
    }
    return false
}
```

- [ ] **Step 4: Append events inside `createAgentAnnotation` and `removeAnnotation`**

For `createAgentAnnotation`, both branches append a `created` event before returning the id:

```swift
func createAgentAnnotation(
    forPath path: String,
    text: String,
    prefix: String,
    suffix: String,
    note: String,
    clientID: String? = nil
) -> UUID? {
    let ann = Annotation(
        text: text,
        prefix: prefix,
        suffix: suffix,
        note: note,
        author: "agent",
        thread: nil
    )
    if let active = activeTabID,
       let i = tabs.firstIndex(where: { $0.id == active }),
       tabs[i].fileURL.path == path {
        annotations.append(ann)
        showAnnotations = true
        saveSidecar()
        AnnotationEventLog.shared.append(
            kind: .created,
            path: path,
            annotationID: ann.id,
            annotation: ann,
            clientID: clientID
        )
        return ann.id
    }
    if let i = tabs.firstIndex(where: { $0.fileURL.path == path }) {
        tabs[i].annotations.append(ann)
        saveSidecar(forTab: tabs[i])
        AnnotationEventLog.shared.append(
            kind: .created,
            path: path,
            annotationID: ann.id,
            annotation: ann,
            clientID: clientID
        )
        return ann.id
    }
    return nil
}
```

For `removeAnnotation` (MCP `clear_annotation` path), both branches append a `deleted` event:

```swift
@discardableResult
func removeAnnotation(
    forPath path: String,
    id: UUID,
    summary: String,
    clientID: String? = nil
) -> Bool {
    NSLog("[mindle.mcp] clear_annotation path=%@ id=%@ summary=%@", path, id.uuidString, summary)
    if let active = activeTabID,
       let i = tabs.firstIndex(where: { $0.id == active }),
       tabs[i].fileURL.path == path {
        guard annotations.contains(where: { $0.id == id }) else { return false }
        annotations.removeAll { $0.id == id }
        saveSidecar()
        AnnotationEventLog.shared.append(
            kind: .deleted,
            path: path,
            annotationID: id,
            annotation: nil,
            clientID: clientID
        )
        return true
    }
    if let i = tabs.firstIndex(where: { $0.fileURL.path == path }) {
        guard tabs[i].annotations.contains(where: { $0.id == id }) else { return false }
        tabs[i].annotations.removeAll { $0.id == id }
        saveSidecar(forTab: tabs[i])
        AnnotationEventLog.shared.append(
            kind: .deleted,
            path: path,
            annotationID: id,
            annotation: nil,
            clientID: clientID
        )
        return true
    }
    return false
}
```

- [ ] **Step 5: Verify build**

Run: `./build.sh 2>&1 | tail -5`
Expected: `✓ Built build/Mindle.app`

- [ ] **Step 6: Manual sanity check via NSLog**

Add a temporary NSLog at the top of `AnnotationEventLog.append`:

```swift
NSLog("[mindle.log] event kind=%@ path=%@ clientID=%@", kind.rawValue, path, clientID ?? "nil")
```

Install build:

```bash
osascript -e 'quit app "Mindle"'
sleep 1
rm -rf /Applications/Mindle.app
cp -R /Users/neptune/workdir/mindle/build/Mindle.app /Applications/
open /Applications/Mindle.app
log stream --process Mindle --predicate 'composedMessage CONTAINS "mindle.log"' --info
```

In another terminal/shell session, open a file in Mindle, highlight a passage (⌘⇧H), then add a note (⌘⇧N). Expect to see two log lines with `kind=created path=...md clientID=nil`.

Once verified, remove the temporary NSLog.

- [ ] **Step 7: Commit**

```bash
git add Sources/mindle/DocumentStore.swift
git commit -m "Append events to AnnotationEventLog on user annotation mutations"
```

---

## Task 3: Thread clientID through AppDelegate aggregators and MCPServer mutations

**Files:**
- Modify: `Sources/mindle/MindleApp.swift`
- Modify: `Sources/mindle/MCPServer.swift`

- [ ] **Step 1: Update AppDelegate aggregator method signatures**

In `Sources/mindle/MindleApp.swift`, every aggregator that mutates annotations on behalf of an agent grows a `clientID: String?` parameter and passes it to `DocumentStore`:

```swift
func clearAnnotation(forPath path: String, id: UUID, summary: String, clientID: String?) -> Bool {
    registeredStores.removeAll { $0.store == nil }
    for ref in registeredStores {
        guard let store = ref.store else { continue }
        if store.removeAnnotation(forPath: path, id: id, summary: summary, clientID: clientID) {
            return true
        }
    }
    return false
}

func appendThreadMessage(
    forPath path: String,
    annotationID: UUID,
    author: String,
    text: String,
    clientID: String?
) -> Bool {
    registeredStores.removeAll { $0.store == nil }
    for ref in registeredStores {
        if ref.store?.appendThreadMessage(
            forPath: path,
            annotationID: annotationID,
            author: author,
            text: text,
            clientID: clientID
        ) == true {
            return true
        }
    }
    return false
}

func createAgentAnnotation(
    forPath path: String,
    text: String,
    prefix: String,
    suffix: String,
    note: String,
    clientID: String?
) -> UUID? {
    registeredStores.removeAll { $0.store == nil }
    for ref in registeredStores {
        if let id = ref.store?.createAgentAnnotation(
            forPath: path,
            text: text,
            prefix: prefix,
            suffix: suffix,
            note: note,
            clientID: clientID
        ) {
            return id
        }
    }
    return nil
}
```

- [ ] **Step 2: Extract client_id in MCPServer dispatch and pass it through**

In `Sources/mindle/MCPServer.swift`, the `dispatch` function gains a top-of-body extraction:

```swift
private static func dispatch(op: String, request: [String: Any]) async -> [String: Any] {
    let clientID = request["client_id"] as? String
    switch op {
    // ... cases below now use `clientID` where they call AppDelegate.shared aggregators
    }
}
```

Update the three mutating cases to pass `clientID`:

```swift
case "clear_annotation":
    // ... existing validation ...
    let removed = await MainActor.run {
        AppDelegate.shared?.clearAnnotation(
            forPath: normalized, id: id, summary: summary, clientID: clientID
        ) ?? false
    }
    // ... rest unchanged ...

case "comment_on_annotation":
    // ... existing validation ...
    let appended = await MainActor.run {
        AppDelegate.shared?.appendThreadMessage(
            forPath: normalized,
            annotationID: id,
            author: "agent",
            text: text,
            clientID: clientID
        ) ?? false
    }
    // ... rest unchanged ...

case "create_annotation":
    // ... existing validation ...
    let newID = await MainActor.run {
        AppDelegate.shared?.createAgentAnnotation(
            forPath: normalized,
            text: text,
            prefix: prefix,
            suffix: suffix,
            note: note,
            clientID: clientID
        )
    }
    // ... rest unchanged ...
```

- [ ] **Step 3: Verify build**

Run: `./build.sh 2>&1 | tail -5`
Expected: `✓ Built build/Mindle.app`

- [ ] **Step 4: Commit**

```bash
git add Sources/mindle/MindleApp.swift Sources/mindle/MCPServer.swift
git commit -m "Thread clientID through MCP mutation dispatch"
```

---

## Task 4: Helper generates clientID and stamps every request

**Files:**
- Modify: `Sources/MindleMCP/main.swift`

- [ ] **Step 1: Generate clientID at helper startup**

In `Sources/MindleMCP/main.swift`, add a static property on the `MindleMCP` struct:

```swift
/// Stable UUID for the lifetime of this helper process. Threaded into
/// every Mindle request so Mindle can tag mutations and filter them
/// back out of wait_for_annotation_event responses for the same client.
private static let clientID: String = UUID().uuidString
```

- [ ] **Step 2: Add client_id to every callMindle body**

Modify `callMindle` so it stamps the client_id into the request before serialization:

```swift
private static func callMindle(
    op: String,
    body: [String: Any],
    format: ([String: Any]) -> [String: Any]
) -> [String: Any] {
    // ... existing socket setup ...

    var request = body
    request["op"] = op
    request["client_id"] = clientID
    guard let data = try? JSONSerialization.data(withJSONObject: request) else {
        return errorContent("could not encode request")
    }
    // ... rest unchanged ...
}
```

- [ ] **Step 3: Verify build**

Run: `./build.sh 2>&1 | tail -5`
Expected: `✓ Built build/Mindle.app`

- [ ] **Step 4: Smoke test that existing tools still work**

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_open_files","arguments":{}}}' \
  | /Users/neptune/workdir/mindle/build/Mindle.app/Contents/MacOS/mindle-mcp \
  | head -3
```

Expected: a JSON-RPC response with `content` containing either the open file list or "No files are currently open" — anything that's not an `error`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MindleMCP/main.swift
git commit -m "mindle-mcp: generate clientID per helper, stamp every request"
```

---

## Task 5: Add wait() to AnnotationEventLog with timeout

**Files:**
- Modify: `Sources/mindle/AnnotationEventLog.swift`

- [ ] **Step 1: Add a Waiter type and a wait() method**

Append to `AnnotationEventLog`:

```swift
/// One pending wait_for_annotation_event call. The continuation is
/// resumed exactly once — either by `signalWaiters()` when an event
/// arrives that the waiter cares about, or by the timeout task when
/// `timeoutSeconds` elapses.
private final class Waiter {
    let sinceID: Int?
    let excludingClientID: String?
    let continuation: CheckedContinuation<(events: [AnnotationEvent], lastEventID: Int, gap: Bool), Never>
    var resumed: Bool = false

    init(
        sinceID: Int?,
        excludingClientID: String?,
        continuation: CheckedContinuation<(events: [AnnotationEvent], lastEventID: Int, gap: Bool), Never>
    ) {
        self.sinceID = sinceID
        self.excludingClientID = excludingClientID
        self.continuation = continuation
    }
}

private var waiters: [Waiter] = []
```

Add the wait method:

```swift
/// Long-poll for the next event matching the filter. Returns the
/// current snapshot immediately if it already contains events the
/// caller hasn't seen; otherwise blocks for up to timeoutSeconds.
///
/// Note: `sinceID == nil` means "from now" — only events appended
/// AFTER this call returns. This matches the spec's "agent calls
/// get_annotations to baseline, then watches for new events."
func wait(
    sinceID: Int?,
    timeoutSeconds: Double,
    excludingClientID: String?
) async -> (events: [AnnotationEvent], lastEventID: Int, gap: Bool) {
    // Pending events already in the log?
    let snap = snapshot(sinceID: sinceID, excludingClientID: excludingClientID)
    if !snap.events.isEmpty || snap.gap {
        return snap
    }

    // Otherwise, register a waiter and race against the timeout.
    return await withCheckedContinuation { continuation in
        let waiter = Waiter(
            sinceID: sinceID,
            excludingClientID: excludingClientID,
            continuation: continuation
        )
        waiters.append(waiter)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            self.resume(waiter, withEmpty: true)
        }
    }
}

/// Resolve a single waiter exactly once. Removes it from the queue.
private func resume(
    _ waiter: Waiter,
    withEmpty: Bool
) {
    guard !waiter.resumed else { return }
    waiter.resumed = true
    if let idx = waiters.firstIndex(where: { $0 === waiter }) {
        waiters.remove(at: idx)
    }
    if withEmpty {
        waiter.continuation.resume(
            returning: ([], nextID - 1, false)
        )
    } else {
        let snap = snapshot(
            sinceID: waiter.sinceID,
            excludingClientID: waiter.excludingClientID
        )
        waiter.continuation.resume(returning: snap)
    }
}
```

Modify `append` to signal waiters after the event lands:

```swift
func append(
    kind: AnnotationEvent.Kind,
    path: String,
    annotationID: UUID,
    annotation: Annotation?,
    messageID: UUID? = nil,
    clientID: String?
) {
    // ... existing body that appends the event and trims to capacity ...

    signalWaiters()
}

private func signalWaiters() {
    // Iterate a snapshot of waiters so resume() can mutate the array.
    let pending = waiters
    for waiter in pending {
        let snap = snapshot(
            sinceID: waiter.sinceID,
            excludingClientID: waiter.excludingClientID
        )
        if !snap.events.isEmpty || snap.gap {
            resume(waiter, withEmpty: false)
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `./build.sh 2>&1 | tail -5`
Expected: `✓ Built build/Mindle.app`

- [ ] **Step 3: Commit**

```bash
git add Sources/mindle/AnnotationEventLog.swift
git commit -m "AnnotationEventLog: long-poll wait() with timeout + waiter signaling"
```

---

## Task 6: MCPServer wait_for_annotation_event op

**Files:**
- Modify: `Sources/mindle/MCPServer.swift`

- [ ] **Step 1: Add the new op to dispatch**

In `Sources/mindle/MCPServer.swift`, add a new case before `default`:

```swift
case "wait_for_annotation_event":
    let rawTimeout = (request["timeout_seconds"] as? Double) ?? 60.0
    let timeoutSeconds = max(5.0, min(300.0, rawTimeout))
    let sinceID = request["since_event_id"] as? Int
    let result = await AnnotationEventLog.shared.wait(
        sinceID: sinceID,
        timeoutSeconds: timeoutSeconds,
        excludingClientID: clientID
    )
    let iso = ISO8601DateFormatter()
    let payload: [[String: Any]] = result.events.map { ev in
        var entry: [String: Any] = [
            "event_id": ev.id,
            "type": ev.kind.rawValue,
            "path": ev.path,
            "annotation_id": ev.annotationID.uuidString,
            "occurred_at": iso.string(from: ev.occurredAt)
        ]
        if let ann = ev.annotation {
            entry["annotation"] = encodeAnnotation(ann, iso: iso)
        }
        if let mid = ev.messageID {
            entry["message_id"] = mid.uuidString
        }
        return entry
    }
    return [
        "ok": true,
        "events": payload,
        "last_event_id": result.lastEventID,
        "gap": result.gap
    ]
```

Add a helper at the bottom of `MCPServer` (next to `dispatch`):

```swift
private static func encodeAnnotation(
    _ ann: Annotation,
    iso: ISO8601DateFormatter
) -> [String: Any] {
    var payload: [String: Any] = [
        "id": ann.id.uuidString,
        "text": ann.text,
        "prefix": ann.prefix,
        "suffix": ann.suffix,
        "note": ann.note,
        "author": ann.author ?? "user",
        "createdAt": iso.string(from: ann.createdAt)
    ]
    if let thread = ann.thread, !thread.isEmpty {
        payload["thread"] = thread.map { msg -> [String: Any] in
            [
                "id": msg.id.uuidString,
                "author": msg.author,
                "text": msg.text,
                "createdAt": iso.string(from: msg.createdAt)
            ]
        }
    }
    return payload
}
```

Refactor the existing `get_annotations` case to use `encodeAnnotation` so the wire format stays consistent between snapshots and events. Replace the inline annotation-to-dict block in `get_annotations` with:

```swift
return anns.map { ann -> [String: Any] in
    encodeAnnotation(ann, iso: iso)
}
```

- [ ] **Step 2: Verify build**

Run: `./build.sh 2>&1 | tail -5`
Expected: `✓ Built build/Mindle.app`

- [ ] **Step 3: Commit**

```bash
git add Sources/mindle/MCPServer.swift
git commit -m "MCPServer: wait_for_annotation_event op + shared annotation encoder"
```

---

## Task 7: Helper exposes wait_for_annotation_event as MCP tool

**Files:**
- Modify: `Sources/MindleMCP/main.swift`

- [ ] **Step 1: Add the tool definition**

In `Sources/MindleMCP/main.swift`, inside `toolDefinitions()`, append a new entry to the array:

```swift
[
    "name": "wait_for_annotation_event",
    "description": "Long-poll for the next user annotation event in Mindle. Use this to run an ambient collaboration loop: the user annotates a file in Mindle, you wake up here with the event payload, address it (read context, edit the file, comment_on_annotation or clear_annotation as appropriate), then call wait_for_annotation_event again. Wakeup events are: a new annotation, a user reply in an existing thread, an annotation deletion. Your own mutations (clear_annotation, comment_on_annotation, create_annotation) never wake you. Before starting the loop, call list_open_files and get_annotations on each open file so you have baseline context. The result includes 'events' (possibly empty if the timeout elapsed — call again), 'last_event_id' (pass back as since_event_id), and 'gap' (true if events were dropped between calls — rebaseline with get_annotations).",
    "inputSchema": [
        "type": "object",
        "properties": [
            "timeout_seconds": [
                "type": "number",
                "description": "How long to wait for an event before returning empty. Server clamps to [5, 300]. Default 60.",
                "default": 60
            ],
            "since_event_id": [
                "type": "integer",
                "description": "The last_event_id from your previous wait_for_annotation_event call. Pass null on the first call to wait for events from now forward."
            ]
        ],
        "additionalProperties": false
    ]
]
```

- [ ] **Step 2: Add dispatch in handleToolCall**

In `Sources/MindleMCP/main.swift`, `handleToolCall`, add a new case before `default`:

```swift
case "wait_for_annotation_event":
    var body: [String: Any] = [:]
    if let t = arguments["timeout_seconds"] {
        body["timeout_seconds"] = t
    }
    if let s = arguments["since_event_id"] {
        body["since_event_id"] = s
    }
    return callMindle(op: "wait_for_annotation_event", body: body) { resp in
        guard let events = resp["events"] as? [[String: Any]] else {
            return errorContent("malformed response from Mindle")
        }
        let lastEventID = (resp["last_event_id"] as? Int) ?? 0
        let gap = (resp["gap"] as? Bool) ?? false
        if events.isEmpty {
            // Empty timeout return — give the agent something to scan
            // so it knows the call returned cleanly and can loop.
            let gapNote = gap ? " (gap=true; rebaseline via get_annotations)" : ""
            return textContent("No new events. last_event_id=\(lastEventID)\(gapNote)")
        }
        var lines: [String] = ["Events (last_event_id=\(lastEventID), gap=\(gap)):"]
        for ev in events {
            let id = (ev["event_id"] as? Int) ?? 0
            let kind = (ev["type"] as? String) ?? "?"
            let path = (ev["path"] as? String) ?? "?"
            let annID = (ev["annotation_id"] as? String) ?? "?"
            lines.append("- [event \(id)] \(kind) on \(path) (annotation \(annID))")
            if let ann = ev["annotation"] as? [String: Any] {
                let note = (ann["note"] as? String) ?? ""
                if !note.isEmpty {
                    lines.append("    Note: \(note)")
                }
                if let thread = ann["thread"] as? [[String: Any]], !thread.isEmpty {
                    if let last = thread.last,
                       let mAuthor = last["author"] as? String,
                       let mText = last["text"] as? String {
                        lines.append("    Latest message (\(mAuthor)): \(mText)")
                    }
                }
            }
        }
        return textContent(lines.joined(separator: "\n"))
    }
```

Pass `clientID` through `callMindle` automatically — Task 4 already added it to every request body.

- [ ] **Step 3: Verify build**

Run: `./build.sh 2>&1 | tail -5`
Expected: `✓ Built build/Mindle.app`

- [ ] **Step 4: Smoke test tools/list**

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  | /Users/neptune/workdir/mindle/build/Mindle.app/Contents/MacOS/mindle-mcp \
  | python3 -c 'import sys,json
for line in sys.stdin:
  obj = json.loads(line)
  for t in obj.get("result",{}).get("tools",[]):
    print(t["name"])'
```

Expected: six lines — `list_open_files`, `get_annotations`, `clear_annotation`, `comment_on_annotation`, `create_annotation`, `wait_for_annotation_event`.

- [ ] **Step 5: Commit**

```bash
git add Sources/MindleMCP/main.swift
git commit -m "mindle-mcp: expose wait_for_annotation_event tool"
```

---

## Task 8: End-to-end smoke test against running Mindle

**Files:**
- No code changes; manual verification only.

- [ ] **Step 1: Install the new build**

```bash
osascript -e 'quit app "Mindle"'
sleep 1
rm -rf /Applications/Mindle.app
cp -R /Users/neptune/workdir/mindle/build/Mindle.app /Applications/
open /Applications/Mindle.app
```

Open a Markdown file in Mindle.

- [ ] **Step 2: Confirm baseline tools still work after client_id changes**

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_open_files","arguments":{}}}' \
  | /Applications/Mindle.app/Contents/MacOS/mindle-mcp
```

Expected: response listing the file you opened, no error.

- [ ] **Step 3: Timeout path — wait_for_annotation_event with nothing pending**

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"wait_for_annotation_event","arguments":{"timeout_seconds":5}}}' \
  | /Applications/Mindle.app/Contents/MacOS/mindle-mcp
```

Expected: blocks for ~5s, then returns `content` with text "No new events. last_event_id=0" (or whatever the current id is).

- [ ] **Step 4: Event path — wait then annotate**

Open two terminals. In terminal A:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"wait_for_annotation_event","arguments":{"timeout_seconds":60}}}' \
  | /Applications/Mindle.app/Contents/MacOS/mindle-mcp
```

In Mindle, highlight a passage and add a note (⌘⇧N), type "test", press Return.

Terminal A should return within a few seconds with one `created` event. Inspect the JSON for `events: [{event_id: 1, type: "created", path: "...", annotation: {...}}]`.

- [ ] **Step 5: Self-filter path — agent's own mutation doesn't wake itself**

In one shell, start a wait then pipe a comment to the same helper instance via JSON-RPC. The simplest way is to send two requests through the same helper invocation:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"comment_on_annotation","arguments":{"path":"<your path>","id":"<your annotation id>","text":"self-filter test"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"wait_for_annotation_event","arguments":{"timeout_seconds":5}}}' \
  | /Applications/Mindle.app/Contents/MacOS/mindle-mcp
```

Expected: the first response confirms the comment posted; the second response — using the same helper-process clientID — returns "No new events" (the agent's own comment was filtered).

Open Mindle and verify the agent's comment IS visible in the annotation's thread (gray stripe). So the comment landed; only the wait was filtered.

- [ ] **Step 6: Multi-client visibility — second helper instance sees the first's mutations**

In terminal A, start a wait:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"wait_for_annotation_event","arguments":{"timeout_seconds":30}}}' \
  | /Applications/Mindle.app/Contents/MacOS/mindle-mcp
```

In terminal B (a different helper invocation = different clientID), post a comment to an existing annotation:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"comment_on_annotation","arguments":{"path":"<your path>","id":"<your annotation id>","text":"from other client"}}}' \
  | /Applications/Mindle.app/Contents/MacOS/mindle-mcp
```

Terminal A should return immediately with a `thread_reply` event (different clientID = not filtered).

- [ ] **Step 7: UI integration — agent's MCP wait loop receives a user event**

In Claude Code, with the running session:
- Ask "watch my Mindle annotations and answer them" — the agent should call `wait_for_annotation_event` in a loop.
- Add an annotation in Mindle (⌘⇧N, "say hi").
- The agent should pick it up and respond via `comment_on_annotation`.
- Click Reply on the thread, type a follow-up, Return — the agent should pick THAT up too.

If any step fails, file a TODO note on which step and what was observed. The plan does not require fixing in this PR — the watch primitive is delivered; behavior polish can iterate.

- [ ] **Step 8: Push branch and open PR**

```bash
git push -u origin feat/mcp-watch
gh pr create --base main \
  --title "MCP Phase 3: wait_for_annotation_event for ambient collaboration" \
  --body "$(cat <<'EOF'
## Summary
- New MCP tool wait_for_annotation_event letting an agent run an ambient loop: the user annotates in Mindle, the agent picks it up automatically and addresses it.
- AnnotationEventLog backs the long-poll with a 256-event ring buffer + waiter primitives, MainActor-isolated.
- Self-filtering via per-helper clientID: the agent's own mutations never wake the agent.
- Works in any MCP client (Claude Code, Codex, Cursor) — pure MCP, no client-specific hooks.

Builds on #11 (Phase 2). Spec: docs/superpowers/specs/2026-05-11-ambient-mindle-collaboration-design.md.

## Test plan
- [ ] list_open_files / get_annotations / clear_annotation / comment_on_annotation / create_annotation all still return clean responses.
- [ ] wait_for_annotation_event with timeout=5 and nothing pending returns "No new events".
- [ ] User adds annotation in Mindle while a wait is pending → wait returns within a few seconds with one `created` event.
- [ ] Agent's own comment_on_annotation does NOT wake its own wait (filtered via clientID).
- [ ] Second helper instance's mutation DOES wake the first's wait.
- [ ] Full Claude Code session: "watch my Mindle annotations" → agent loops → user annotates → agent responds.

🤖 Generated with Claude Code
EOF
)"
```

---

## Self-Review

Reviewed the plan against the spec:

**Spec coverage:**
- `wait_for_annotation_event` tool with timeout + since_event_id + gap → Tasks 5, 6, 7.
- Self-filter via client_id → Tasks 3, 4 (threading) + Task 5 (filter in snapshot/wait) + Task 6 (excludingClientID in dispatch).
- 256-event ring buffer → Task 1 (capacity constant) + Task 1's `events.removeFirst` trim.
- Gap detection → Task 1's `snapshot` returns `gap: true` when `sinceID < oldestID - 1`.
- Event payload includes path, annotation, message_id where applicable → Task 6's encoding.
- Cross-agent portability → Tool description in Task 7 carries the protocol guidance; no Claude Code dependency.
- Optional Claude Code skill (`docs/skills/mindle-collaboration.md`) — **Spec marks this as "optional but bundled"; not in this plan.** Following YAGNI: ship the tool, see how it feels, write the skill as a Phase 3b once the protocol is proven. If the user wants the skill in this PR, it's a small append.
- Reconnection / gap handling → Task 1's snapshot handles `since_event_id < oldest`. Tasks 6/7 surface the gap flag to the agent.
- Acceptance criteria 1–6 are all covered by Task 8's manual smoke steps.

**Placeholder scan:** No TBD/TODO. All code blocks are complete. Manual verification steps have concrete commands and expected outputs.

**Type consistency:**
- `AnnotationEvent.Kind` enum (`.created`, `.threadReply`, `.deleted`) is used consistently — Task 1 defines, Task 2 calls with `.created`/`.deleted`/`.threadReply`, Task 6 reads `.rawValue` to render to JSON.
- `clientID: String?` is consistent across DocumentStore, AppDelegate, MCPServer, AnnotationEventLog.
- `snapshot` returns the same tuple shape `(events, lastEventID, gap)` used by `wait`.

**Scope check:** Single subsystem (one new tool + supporting plumbing). Reasonable for a single PR.

No issues to fix; proceeding to handoff.
