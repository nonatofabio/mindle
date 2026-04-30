import Foundation
import Darwin

// `mindle-mcp`: stdio MCP helper. Reads newline-delimited JSON-RPC from
// stdin, translates each tools/call into a length-prefixed JSON request
// over the running Mindle's Unix socket, and emits the JSON-RPC response
// on stdout.
//
// Read-only by design: Mindle exposes only what no other tool can —
// open-files state and the annotation feedback channel. Filesystem reads
// belong in the agent's normal Read tool, not here.

@main
struct MindleMCP {

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

    // MARK: - Tool surface (Phase 1: list_open_files only)

    private static func toolDefinitions() -> [[String: Any]] {
        return [
            [
                "name": "list_open_files",
                "description": "List the absolute paths of every Markdown file currently open in Mindle (across all windows and tabs). Use this to see what the user is reading right now.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false
                ]
            ]
        ]
    }

    private static func handleToolCall(params: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return errorContent("missing tool name")
        }
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
