import Cocoa
import Quartz
import WebKit

/// Quick Look preview for `.md` files. Hosts a WKWebView that loads the
/// same `reader.html` template Mindle uses in-app, then evaluates
/// `mindleLoad(markdown, false)` with the file's contents. The web
/// pipeline (markdown-it + highlight.js + frontmatter unwrapping) is
/// shared verbatim — Quick Look previews look identical to the main
/// reader, just without theme/font UI.
final class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {

    private var webView: WKWebView!
    private var pendingMarkdown: String?
    private var pendingHandler: ((Error?) -> Void)?

    override func loadView() {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let container = NSView(frame: frame)

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = false

        webView = WKWebView(frame: container.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsLinkPreview = false
        container.addSubview(webView)

        self.view = container
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        // Bow out of non-markdown plain-text (we register for
        // public.plain-text as a fallback — see Info.plist comment).
        // Anything else gets a "no preview available" so the system
        // falls back to its own previewer.
        let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
        guard markdownExtensions.contains(url.pathExtension.lowercased()) else {
            handler(NSError(domain: "MindleQuickLook", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Not a markdown file"]))
            return
        }
        do {
            let markdown = try String(contentsOf: url, encoding: .utf8)
            guard let htmlURL = Bundle(for: type(of: self))
                .url(forResource: "reader", withExtension: "html", subdirectory: "web")
            else {
                handler(NSError(domain: "MindleQuickLook", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Reader template missing"]))
                return
            }
            pendingMarkdown = markdown
            pendingHandler = handler
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } catch {
            handler(error)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let md = pendingMarkdown else { return }
        let escaped = jsString(md)
        webView.evaluateJavaScript("window.mindleLoad(\(escaped), false);") { [weak self] _, _ in
            self?.pendingHandler?(nil)
            self?.pendingHandler = nil
            self?.pendingMarkdown = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pendingHandler?(error)
        pendingHandler = nil
        pendingMarkdown = nil
    }

    // MARK: - JS string escaping

    /// Escapes a Swift string for safe interpolation into a `evaluateJavaScript`
    /// argument position. JSONSerialization handles Unicode + control chars
    /// for us; the surrounding quotes come back as part of the JSON string.
    private func jsString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let json = String(data: data, encoding: .utf8) {
            // Strip the wrapping array brackets to get just the quoted string.
            return String(json.dropFirst().dropLast())
        }
        // Fallback — manually escape minimal characters.
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}
