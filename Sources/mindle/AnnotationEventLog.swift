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
