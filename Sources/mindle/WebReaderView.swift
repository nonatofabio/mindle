import SwiftUI
import WebKit
import AppKit

struct WebReaderView: NSViewRepresentable {
    @EnvironmentObject var store: DocumentStore

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "selectionChanged")
        userContent.add(context.coordinator, name: "annotationClicked")
        config.userContentController = userContent
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = false

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.allowsLinkPreview = false
        context.coordinator.web = web

        if let html = readerHTMLURL() {
            let baseDir = html.deletingLastPathComponent()
            web.loadFileURL(html, allowingReadAccessTo: baseDir)
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let coord = context.coordinator
        guard coord.loaded else { return }

        // Only push values that actually changed to avoid resetting DOM/selection
        if store.rawText != coord.lastSource {
            coord.lastSource = store.rawText
            web.evaluateJavaScript("window.mindleLoad(\(jsString(store.rawText)));")
        }

        if store.theme.rawValue != coord.lastTheme {
            coord.lastTheme = store.theme.rawValue
            web.evaluateJavaScript("window.mindleSetTheme(\(jsString(store.theme.rawValue)));")
        }

        if store.fontScale != coord.lastFontScale {
            coord.lastFontScale = store.fontScale
            web.evaluateJavaScript("window.mindleSetFontScale(\(store.fontScale));")
        }

        if store.annotations != coord.lastAnnotations {
            coord.lastAnnotations = store.annotations
            let payload = store.annotations.map { a -> [String: Any] in
                [
                    "id": a.id.uuidString,
                    "text": a.text,
                    "prefix": a.prefix,
                    "suffix": a.suffix,
                    "note": a.note
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                web.evaluateJavaScript("window.mindleSetAnnotations(\(json));")
            }
        }

        if let id = store.focusedAnnotation, id != coord.lastFocusID {
            coord.lastFocusID = id
            web.evaluateJavaScript("window.mindleFocusAnnotation(\(jsString(id.uuidString)));")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: WebReaderView
        weak var web: WKWebView?
        var loaded = false

        // Track last-sent values to avoid redundant pushes
        var lastSource: String = ""
        var lastTheme: String = ""
        var lastFontScale: Double = 0
        var lastAnnotations: [Annotation] = []
        var lastFocusID: UUID?

        init(_ p: WebReaderView) { parent = p }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            // Force initial flush by clearing tracked state
            lastSource = ""
            lastTheme = ""
            lastFontScale = 0
            lastAnnotations = []
            lastFocusID = nil
            // Trigger SwiftUI to call updateNSView
            DispatchQueue.main.async {
                self.parent.store.objectWillChange.send()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, action.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            switch message.name {
            case "selectionChanged":
                guard let body = message.body as? [String: Any] else { return }
                let text = (body["text"] as? String) ?? ""
                let prefix = (body["prefix"] as? String) ?? ""
                let suffix = (body["suffix"] as? String) ?? ""
                Task { @MainActor in
                    self.parent.store.updateSelection(text: text, prefix: prefix, suffix: suffix)
                }

            case "annotationClicked":
                guard let body = message.body as? [String: Any],
                      let idStr = body["id"] as? String,
                      let id = UUID(uuidString: idStr) else { return }
                Task { @MainActor in
                    self.parent.store.focusedAnnotation = id
                    self.parent.store.editingAnnotationID = id
                    self.parent.store.showAnnotations = true
                }

            default: break
            }
        }
    }

    private func readerHTMLURL() -> URL? {
        if let resURL = Bundle.main.url(forResource: "reader", withExtension: "html", subdirectory: "web") {
            return resURL
        }
        if let resDir = Bundle.main.resourceURL {
            let alt = resDir.appendingPathComponent("web/reader.html")
            if FileManager.default.fileExists(atPath: alt.path) { return alt }
        }
        return nil
    }
}

private func jsString(_ s: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
    if let data = data, let str = String(data: data, encoding: .utf8) {
        if str.hasPrefix("["), str.hasSuffix("]") {
            return String(str.dropFirst().dropLast())
        }
    }
    return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
}
