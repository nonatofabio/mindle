import Foundation
import WebKit
import UniformTypeIdentifiers

final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mindle-file"

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let fileURL = URL(fileURLWithPath: url.path)
        guard let data = try? Data(contentsOf: fileURL) else {
            let resp = HTTPURLResponse(
                url: url,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "0"]
            )!
            urlSchemeTask.didReceive(resp)
            urlSchemeTask.didFinish()
            return
        }

        let mime = Self.mimeType(forExtension: fileURL.pathExtension)
        let resp = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": "\(data.count)"
            ]
        )!
        urlSchemeTask.didReceive(resp)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Synchronous handler — nothing to cancel.
    }

    private static func mimeType(forExtension ext: String) -> String {
        let e = ext.lowercased()
        if let t = UTType(filenameExtension: e), let mime = t.preferredMIMEType {
            return mime
        }
        switch e {
        case "svg":  return "image/svg+xml"
        case "webp": return "image/webp"
        default:     return "application/octet-stream"
        }
    }
}
