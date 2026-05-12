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

    /// One pending wait() call. The continuation is resumed exactly once —
    /// either by `signalWaiters()` when an event arrives that the waiter
    /// cares about, or by the timeout task when `timeoutSeconds` elapses.
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
        signalWaiters()
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
            guard let since = sinceID else { return false }
            // Agent fell off the back of the ring buffer — events were dropped.
            if since < oldestID - 1 { return true }
            // Agent is holding an id newer than anything we know about — this
            // happens after a Mindle restart resets nextID. Force rebaseline.
            if since > lastID { return true }
            return false
        }()

        let filtered = events.filter { ev in
            ev.id > effectiveSince &&
            ev.clientID != excludingClientID
        }
        return (filtered, lastID, gap)
    }

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
        let snap = snapshot(sinceID: sinceID, excludingClientID: excludingClientID)
        if !snap.events.isEmpty || snap.gap {
            return snap
        }

        // Pin the waiter's threshold at call time. With sinceID == nil
        // we want "events appended AFTER this call returns" — but
        // signalWaiters re-evaluates `snapshot(sinceID: nil)` on every
        // append, and snapshot resolves nil to the current lastID
        // (nextID - 1), which advances with each append. The result:
        // every new event has id == new lastID and is filtered out by
        // `ev.id > effectiveSince`, so the waiter never wakes. Resolve
        // nil to the current lastID exactly once at registration so the
        // threshold is fixed for the lifetime of this waiter.
        let pinnedSinceID = sinceID ?? (nextID - 1)

        return await withCheckedContinuation { continuation in
            let waiter = Waiter(
                sinceID: pinnedSinceID,
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

    private func signalWaiters() {
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
}
