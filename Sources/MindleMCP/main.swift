import Foundation
import Darwin

// `mindle-mcp`: stdio MCP helper. Reads newline-delimited JSON-RPC from
// stdin, translates each tools/call into a length-prefixed JSON request
// over the running Mindle's Unix socket, and emits the JSON-RPC response
// on stdout.
//
// Mindle exposes only the annotation feedback channel — what's open,
// what the user has annotated, and a way for the agent to mark an
// annotation as addressed. File IO (reads, writes) belongs in the
// agent's normal filesystem tools, not here.

@main
struct MindleMCP {

    /// Stable UUID for the lifetime of this helper process. Threaded into
    /// every Mindle request so Mindle can tag mutations and filter them
    /// back out of wait_for_annotation_event responses for the same client.
    private static let clientID: String = UUID().uuidString

    static func main() {
        // Synchronous read loop — async/Task on stdin proved flaky in
        // this CLI context. POSIX read on fd 0 is bulletproof.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                read(0, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { break }   // EOF or error
            buffer.append(contentsOf: chunk[0..<n])
            while let nlOffset = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: nlOffset)
                buffer.removeSubrange(buffer.startIndex...nlOffset)
                guard !line.isEmpty else { continue }
                if let response = handle(line: Data(line)) {
                    emit(response: response)
                }
            }
        }
    }

    /// Renamed from `write(response:)` to avoid shadowing Darwin's
    /// `write(_:_:_)` syscall used by the socket bridge below.
    private static func emit(response: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    // MARK: - JSON-RPC dispatch

    private static func handle(line: Data) -> [String: Any]? {
        guard let req = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let method = req["method"] as? String else {
            return nil
        }
        let id = req["id"]
        let params = (req["params"] as? [String: Any]) ?? [:]

        // Notifications carry no `id` and don't expect a response.
        if id == nil {
            // We accept and ignore notifications/initialized, etc.
            return nil
        }

        switch method {
        case "initialize":
            return success(id: id!, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": [
                    "name": "mindle",
                    "version": "0.1.0"
                ]
            ])

        case "tools/list":
            return success(id: id!, result: ["tools": toolDefinitions()])

        case "tools/call":
            let result = handleToolCall(params: params)
            return success(id: id!, result: result)

        default:
            return error(id: id!, code: -32601, message: "Method not found: \(method)")
        }
    }

    private static func success(id: Any, result: [String: Any]) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message]
        ]
    }

    // MARK: - Tool surface

    private static func toolDefinitions() -> [[String: Any]] {
        return [
            [
                "name": "list_open_files",
                "description": "List the absolute paths of every file currently open in Mindle (across all windows and tabs). Use this to see what the user is reading right now.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false
                ]
            ],
            [
                "name": "get_annotations",
                "description": "Return every annotation (highlight or note) the user has placed on a file currently open in Mindle. Each annotation includes its id, the highlighted text verbatim, surrounding context, the user's note (often empty for plain highlights), and a creation timestamp. Use the annotation as the user's instruction to you: read it, address it with your normal file-editing tools, then call clear_annotation to mark it done.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Absolute path to the file. Must be a file currently open in Mindle — call list_open_files first if unsure."
                        ]
                    ],
                    "required": ["path"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "clear_annotation",
                "description": "Mark an annotation as addressed and remove it from the file's sidebar. Provide a short summary of what you did so the user can see in their review pass. Call this after you've actually edited the file to address what the annotation asked for — clearing without addressing leaves the user confused.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Absolute path to the file the annotation lives on."
                        ],
                        "id": [
                            "type": "string",
                            "description": "The annotation's UUID, as returned by get_annotations."
                        ],
                        "summary": [
                            "type": "string",
                            "description": "One short sentence describing what you changed. Example: 'Rephrased the intro paragraph to be more concise.'"
                        ]
                    ],
                    "required": ["path", "id", "summary"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "comment_on_annotation",
                "description": "Add a message to an annotation's thread without dismissing the annotation. Use this to reply to the user's note, ask a clarifying question before editing, or report progress on a multi-step change. The user sees your message inline under their annotation, with the same back-and-forth feel as a code review comment thread.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Absolute path to the file the annotation lives on."
                        ],
                        "id": [
                            "type": "string",
                            "description": "The annotation's UUID, as returned by get_annotations."
                        ],
                        "text": [
                            "type": "string",
                            "description": "Your message. Plain text. Keep it focused — one or two sentences usually."
                        ]
                    ],
                    "required": ["path", "id", "text"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "create_annotation",
                "description": "Open a new annotation on a span of text in a file currently open in Mindle. Use this to ask the user a question about something you've written or about a passage you want their input on. The annotation appears in the user's sidebar marked as agent-authored with your note as the prompt; the user can reply in its thread.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Absolute path to the file. Must be currently open in Mindle."
                        ],
                        "text": [
                            "type": "string",
                            "description": "The exact substring of the file the annotation anchors to. Must appear verbatim in the current file content."
                        ],
                        "prefix": [
                            "type": "string",
                            "description": "Up to ~32 characters from the file immediately preceding 'text' — used to disambiguate when 'text' appears multiple times. Pass an empty string if the file is small and disambiguation isn't needed."
                        ],
                        "suffix": [
                            "type": "string",
                            "description": "Up to ~32 characters from the file immediately following 'text'."
                        ],
                        "note": [
                            "type": "string",
                            "description": "The question or comment you want the user to see. Will appear as the annotation's primary note above the thread."
                        ]
                    ],
                    "required": ["path", "text", "prefix", "suffix", "note"],
                    "additionalProperties": false
                ]
            ],
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
        ]
    }

    private static func handleToolCall(params: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return errorContent("missing tool name")
        }
        let arguments = (params["arguments"] as? [String: Any]) ?? [:]
        switch name {
        case "list_open_files":
            return callMindle(op: "list_open_files", body: [:]) { resp in
                guard let files = resp["files"] as? [String] else {
                    return errorContent("malformed response from Mindle")
                }
                if files.isEmpty {
                    return textContent("No files are currently open in Mindle.")
                }
                let listing = files.map { "- \($0)" }.joined(separator: "\n")
                return textContent("Files currently open in Mindle:\n\n\(listing)")
            }

        case "get_annotations":
            guard let path = arguments["path"] as? String else {
                return errorContent("missing required argument: path")
            }
            return callMindle(op: "get_annotations", body: ["path": path]) { resp in
                guard let anns = resp["annotations"] as? [[String: Any]] else {
                    return errorContent("malformed response from Mindle")
                }
                if anns.isEmpty {
                    return textContent("No annotations on \(path).")
                }
                var lines: [String] = ["Annotations on \(path):", ""]
                for (i, ann) in anns.enumerated() {
                    let id = (ann["id"] as? String) ?? "?"
                    let text = (ann["text"] as? String) ?? ""
                    let note = (ann["note"] as? String) ?? ""
                    let author = (ann["author"] as? String) ?? "user"
                    let authorTag = author == "agent" ? " (agent-authored)" : ""
                    lines.append("\(i + 1). [id: \(id)]\(authorTag)")
                    lines.append("   Selected: \(text.replacingOccurrences(of: "\n", with: " "))")
                    if !note.isEmpty {
                        lines.append("   Note: \(note)")
                    }
                    if let thread = ann["thread"] as? [[String: Any]], !thread.isEmpty {
                        lines.append("   Thread:")
                        for msg in thread {
                            let mAuthor = (msg["author"] as? String) ?? "?"
                            let mText = (msg["text"] as? String) ?? ""
                            // Indent multi-line messages under the bullet so
                            // the agent can scan a long thread without losing
                            // the author column.
                            let firstLine: String
                            let restLines: [String]
                            let parts = mText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                            firstLine = parts.first ?? ""
                            restLines = Array(parts.dropFirst())
                            lines.append("     - \(mAuthor): \(firstLine)")
                            for r in restLines {
                                lines.append("       \(r)")
                            }
                        }
                    }
                    lines.append("")
                }
                return textContent(lines.joined(separator: "\n"))
            }

        case "clear_annotation":
            guard let path = arguments["path"] as? String,
                  let id = arguments["id"] as? String,
                  let summary = arguments["summary"] as? String else {
                return errorContent("missing required arguments: path, id, summary")
            }
            return callMindle(
                op: "clear_annotation",
                body: ["path": path, "id": id, "summary": summary]
            ) { _ in
                return textContent("Cleared annotation \(id) on \(path).")
            }

        case "comment_on_annotation":
            guard let path = arguments["path"] as? String,
                  let id = arguments["id"] as? String,
                  let text = arguments["text"] as? String else {
                return errorContent("missing required arguments: path, id, text")
            }
            return callMindle(
                op: "comment_on_annotation",
                body: ["path": path, "id": id, "text": text]
            ) { _ in
                return textContent("Posted reply to annotation \(id) on \(path).")
            }

        case "create_annotation":
            guard let path = arguments["path"] as? String,
                  let text = arguments["text"] as? String,
                  let note = arguments["note"] as? String else {
                return errorContent("missing required arguments: path, text, note")
            }
            let prefix = (arguments["prefix"] as? String) ?? ""
            let suffix = (arguments["suffix"] as? String) ?? ""
            return callMindle(
                op: "create_annotation",
                body: ["path": path, "text": text, "prefix": prefix, "suffix": suffix, "note": note]
            ) { resp in
                let newID = (resp["id"] as? String) ?? "?"
                return textContent("Opened annotation \(newID) on \(path).")
            }

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

        default:
            return errorContent("unknown tool: \(name)")
        }
    }

    private static func textContent(_ text: String) -> [String: Any] {
        return [
            "content": [["type": "text", "text": text]]
        ]
    }

    private static func errorContent(_ text: String) -> [String: Any] {
        return [
            "content": [["type": "text", "text": text]],
            "isError": true
        ]
    }

    // MARK: - Socket bridge to running Mindle

    /// Connect to ~/Library/Caches/local.fnp.mindle/mcp.sock, send a
    /// length-prefixed JSON request, parse the length-prefixed response,
    /// and pass it to `format`. Surface a clear error if Mindle isn't
    /// running rather than crashing or hanging.
    private static func callMindle(
        op: String,
        body: [String: Any],
        format: ([String: Any]) -> [String: Any]
    ) -> [String: Any] {
        let cache = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let path = cache?
            .appendingPathComponent("local.fnp.mindle", isDirectory: true)
            .appendingPathComponent("mcp.sock").path else {
            return errorContent("Could not resolve Mindle's socket path.")
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return errorContent("socket() failed: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        // SO_NOSIGPIPE: never let a write to a closed socket terminate
        // this helper process. write() will return -1 with errno=EPIPE
        // and writeAll surfaces that as a clean error.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= cap else {
            return errorContent("Mindle socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                _ = memcpy(dst.baseAddress, src.baseAddress, src.count)
            }
        }

        let sockLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, sockLen)
            }
        }
        guard connectResult == 0 else {
            return errorContent("Mindle isn't running. Open Mindle and try again.")
        }

        var request = body
        request["op"] = op
        request["client_id"] = clientID
        guard let data = try? JSONSerialization.data(withJSONObject: request) else {
            return errorContent("could not encode request")
        }
        let bytes = [UInt8](data)
        let len = UInt32(bytes.count)
        let header: [UInt8] = [
            UInt8((len >> 24) & 0xff),
            UInt8((len >> 16) & 0xff),
            UInt8((len >>  8) & 0xff),
            UInt8( len        & 0xff)
        ]
        guard writeAll(fd: fd, bytes: header), writeAll(fd: fd, bytes: bytes) else {
            return errorContent("write to Mindle failed")
        }

        var lenBuf = [UInt8](repeating: 0, count: 4)
        guard readExact(fd: fd, into: &lenBuf, count: 4) else {
            return errorContent("Mindle closed the connection")
        }
        let payloadLen =
            (UInt32(lenBuf[0]) << 24) |
            (UInt32(lenBuf[1]) << 16) |
            (UInt32(lenBuf[2]) <<  8) |
             UInt32(lenBuf[3])
        guard payloadLen > 0, payloadLen < 1_000_000 else {
            return errorContent("Mindle sent a malformed response length")
        }
        var payload = [UInt8](repeating: 0, count: Int(payloadLen))
        guard readExact(fd: fd, into: &payload, count: Int(payloadLen)) else {
            return errorContent("Mindle response truncated")
        }

        guard let resp = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else {
            return errorContent("Mindle sent malformed JSON")
        }
        if let ok = resp["ok"] as? Bool, !ok {
            let msg = (resp["error"] as? String) ?? "unknown error"
            return errorContent("Mindle: \(msg)")
        }
        return format(resp)
    }

    // MARK: - Wire helpers

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
}
