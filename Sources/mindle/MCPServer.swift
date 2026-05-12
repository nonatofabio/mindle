import Foundation
import Darwin

/// Unix-socket server that lets the bundled `mindle-mcp` helper proxy
/// MCP tool calls into the running Mindle app.
///
/// The wire protocol on the socket is *not* MCP — it's a tiny internal
/// JSON dialect (length-prefixed, request/response). The helper does
/// the MCP framing on stdio; this server just answers questions about
/// what's open and what the user has annotated. Read-only by design:
/// the agent has its own filesystem tools for writes.
///
/// ```
/// 4-byte big-endian length || UTF-8 JSON body
/// request:  {"op": "list_open_files"}
/// response: {"ok": true, "files": ["/abs/path.md", ...]}
/// ```
final class MCPServer {

    static let shared = MCPServer()

    private var listenFD: Int32 = -1
    private(set) var socketPath: String = ""

    private init() {}

    // MARK: - Public lifecycle

    /// Bind, listen, and start the accept loop on a background task.
    /// Idempotent — calling twice is a no-op after the first success.
    func start() {
        guard listenFD < 0 else { return }

        // ~/Library/Caches/local.fnp.mindle/mcp.sock — under the
        // 104-byte sun_path limit on macOS for any normal username.
        let fm = FileManager.default
        guard let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let dir = cache.appendingPathComponent("local.fnp.mindle", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("mcp.sock").path
        socketPath = path

        // Stale socket from a previous launch — bind() would fail otherwise.
        unlink(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[mindle.mcp] socket() errno=%d", errno)
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= cap else {
            close(fd)
            NSLog("[mindle.mcp] socket path too long (%d > %d)", pathBytes.count, cap)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                _ = memcpy(dst.baseAddress, src.baseAddress, src.count)
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, len)
            }
        }
        guard bindResult == 0 else {
            NSLog("[mindle.mcp] bind() errno=%d", errno)
            close(fd)
            return
        }

        // 0700 — only the user can connect.
        chmod(path, 0o700)

        guard Darwin.listen(fd, 8) == 0 else {
            NSLog("[mindle.mcp] listen() errno=%d", errno)
            close(fd)
            unlink(path)
            return
        }

        listenFD = fd

        Task.detached(priority: .utility) { [path] in
            await Self.acceptLoop(listenFD: fd, socketPath: path)
        }
    }

    /// Called from applicationWillTerminate. Unlinks the socket so the
    /// next launch starts clean even if accept() has stale state.
    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        if !socketPath.isEmpty {
            unlink(socketPath)
        }
    }

    // MARK: - Accept loop (background)

    private static func acceptLoop(listenFD: Int32, socketPath: String) async {
        while true {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
                    Darwin.accept(listenFD, p, &clientLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                // listen socket closed — exit the loop.
                return
            }
            // SO_NOSIGPIPE: when the helper disconnects mid-wait, the
            // next write() to this fd would otherwise raise SIGPIPE and
            // kill Mindle. With SO_NOSIGPIPE the write() returns -1 with
            // errno=EPIPE instead, and writeAll handles it cleanly.
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            Task.detached(priority: .utility) {
                await Self.handleClient(fd: clientFD)
            }
        }
    }

    private static func handleClient(fd: Int32) async {
        defer { close(fd) }
        guard let req = readMessage(fd: fd) else {
            sendResponse(fd: fd, response: ["ok": false, "error": "bad request"])
            return
        }
        guard let op = req["op"] as? String else {
            sendResponse(fd: fd, response: ["ok": false, "error": "missing 'op'"])
            return
        }
        let response = await dispatch(op: op, request: req)
        sendResponse(fd: fd, response: response)
    }

    // MARK: - Op dispatch (hops to MainActor for app state)

    private static func dispatch(op: String, request: [String: Any]) async -> [String: Any] {
        let clientID = request["client_id"] as? String
        switch op {
        case "list_open_files":
            let files = await MainActor.run { AppDelegate.shared?.allOpenFilePaths() ?? [] }
            return ["ok": true, "files": files]

        case "get_annotations":
            guard let path = request["path"] as? String else {
                return ["ok": false, "error": "missing 'path'"]
            }
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            let result: [[String: Any]]? = await MainActor.run {
                guard let anns = AppDelegate.shared?.annotations(forPath: normalized) else {
                    return nil
                }
                let iso = ISO8601DateFormatter()
                return anns.map { ann -> [String: Any] in
                    encodeAnnotation(ann, iso: iso)
                }
            }
            guard let annotations = result else {
                return ["ok": false, "error": "file not open in Mindle: \(path)"]
            }
            return ["ok": true, "annotations": annotations]

        case "comment_on_annotation":
            guard let path = request["path"] as? String else {
                return ["ok": false, "error": "missing 'path'"]
            }
            guard let idStr = request["id"] as? String, let id = UUID(uuidString: idStr) else {
                return ["ok": false, "error": "missing or malformed 'id' (expected UUID string)"]
            }
            guard let text = request["text"] as? String, !text.isEmpty else {
                return ["ok": false, "error": "missing or empty 'text'"]
            }
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            let appended = await MainActor.run {
                AppDelegate.shared?.appendThreadMessage(
                    forPath: normalized,
                    annotationID: id,
                    author: "agent",
                    text: text,
                    clientID: clientID
                ) ?? false
            }
            if appended {
                return ["ok": true]
            }
            return ["ok": false, "error": "annotation not found (file may not be open or id is stale)"]

        case "create_annotation":
            guard let path = request["path"] as? String else {
                return ["ok": false, "error": "missing 'path'"]
            }
            guard let text = request["text"] as? String, !text.isEmpty else {
                return ["ok": false, "error": "missing or empty 'text'"]
            }
            guard let note = request["note"] as? String else {
                return ["ok": false, "error": "missing 'note'"]
            }
            let prefix = (request["prefix"] as? String) ?? ""
            let suffix = (request["suffix"] as? String) ?? ""
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
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
            if let id = newID {
                return ["ok": true, "id": id.uuidString]
            }
            return ["ok": false, "error": "file not open in Mindle: \(path)"]

        case "clear_annotation":
            guard let path = request["path"] as? String else {
                return ["ok": false, "error": "missing 'path'"]
            }
            guard let idStr = request["id"] as? String, let id = UUID(uuidString: idStr) else {
                return ["ok": false, "error": "missing or malformed 'id' (expected UUID string)"]
            }
            let summary = (request["summary"] as? String) ?? ""
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            let removed = await MainActor.run {
                AppDelegate.shared?.clearAnnotation(
                    forPath: normalized, id: id, summary: summary, clientID: clientID
                ) ?? false
            }
            if removed {
                return ["ok": true]
            }
            return ["ok": false, "error": "annotation not found (file may not be open or id is stale)"]

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

        default:
            return ["ok": false, "error": "unknown op: \(op)"]
        }
    }

    // MARK: - Wire helpers (length-prefixed JSON)

    private static func readMessage(fd: Int32) -> [String: Any]? {
        var lenBytes = [UInt8](repeating: 0, count: 4)
        guard readExact(fd: fd, into: &lenBytes, count: 4) else { return nil }
        let payloadLen =
            (UInt32(lenBytes[0]) << 24) |
            (UInt32(lenBytes[1]) << 16) |
            (UInt32(lenBytes[2]) <<  8) |
             UInt32(lenBytes[3])
        guard payloadLen > 0, payloadLen < 1_000_000 else { return nil }
        var payload = [UInt8](repeating: 0, count: Int(payloadLen))
        guard readExact(fd: fd, into: &payload, count: Int(payloadLen)) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any]
    }

    private static func sendResponse(fd: Int32, response: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
        let bytes = [UInt8](data)
        let len = UInt32(bytes.count)
        let header: [UInt8] = [
            UInt8((len >> 24) & 0xff),
            UInt8((len >> 16) & 0xff),
            UInt8((len >>  8) & 0xff),
            UInt8( len        & 0xff)
        ]
        _ = writeAll(fd: fd, bytes: header)
        _ = writeAll(fd: fd, bytes: bytes)
    }

    private static func readExact(fd: Int32, into buf: inout [UInt8], count: Int) -> Bool {
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                read(fd, ptr.baseAddress!.advanced(by: got), count - got)
            }
            if n <= 0 { return false }
            got += n
        }
        return true
    }

    @discardableResult
    private static func writeAll(fd: Int32, bytes: [UInt8]) -> Bool {
        var sent = 0
        return bytes.withUnsafeBufferPointer { ptr -> Bool in
            while sent < bytes.count {
                let n = write(fd, ptr.baseAddress!.advanced(by: sent), bytes.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

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
}
