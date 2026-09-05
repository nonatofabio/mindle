import AppKit
import Foundation
import WebKit

private final class ReaderHarness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let readerURL: URL
    var finished = false
    var navigationError: Error?
    var received: [String] = []
    var accepted: [String] = []
    var externalLinks: [URL] = []

    init(readerURL: URL) { self.readerURL = readerURL }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationError = error
        finished = true
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(ReaderSecurity.navigationPolicy(for: action, readerURL: readerURL) {
            self.externalLinks.append($0)
        })
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        received.append(message.name)
        if ReaderSecurity.accepts(message, readerURL: readerURL) {
            accepted.append(message.name)
        }
    }
}

private enum HarnessError: Error {
    case failed(String)
}

@main
struct ReaderSecurityChecks {
    static func main() {
        do {
            try run()
        } catch {
            fputs("Reader security checks failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        let fixtures = root.appendingPathComponent(".build", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let pixel = fixtures.appendingPathComponent("reader-security-pixel.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!.write(to: pixel)
        let readerURL = root.appendingPathComponent("Resources/web/reader.html")
        let recorder = ReaderHarness(readerURL: readerURL)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        for name in ["diffSetCurrent", "diffSetLastSynced", "diffAcceptAll", "diffRejectAll", "searchResult", "headings"] {
            config.userContentController.add(recorder, name: name)
        }
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: ImageSchemeHandler.scheme)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        web.navigationDelegate = recorder
        web.loadFileURL(readerURL, allowingReadAccessTo: root)
        try wait("reader load") { recorder.finished }
        if let error = recorder.navigationError { throw error }
        let baseDir = String(data: try JSONSerialization.data(withJSONObject: [fixtures.path]), encoding: .utf8)!
        try evaluate(web, "window.mindleSetBaseDir(\(baseDir)[0]);")

        let attack = """
        # Safe heading

        <strong>Safe HTML</strong>
        <details><summary>Details</summary>Still readable</details>
        <img alt="local-file" src="\(pixel.absoluteString)">
        <img alt="local-absolute" src="\(pixel.path)">

        ![local-relative](reader-security-pixel.png)

        <img src="data:image/png;base64,invalid" onerror="window.webkit.messageHandlers.diffSetCurrent.postMessage({text:'injected'})">
        <svg onload="window.webkit.messageHandlers.diffRejectAll.postMessage({})"><script>window.__injected = true</script></svg>
        <iframe srcdoc="<script>parent.webkit.messageHandlers.diffAcceptAll.postMessage({})</script>"></iframe>
        <object data="http://127.0.0.1:18765/object"></object>
        <form action="http://127.0.0.1:18765/form"><input autofocus onfocus="window.__injected = true"></form>
        <style>@import url(http://127.0.0.1:18765/style);</style>
        <meta http-equiv="refresh" content="0;url=http://127.0.0.1:18765/navigation">
        <a href="javascript:window.__injected=true">Unsafe link</a>
        <img src="http://127.0.0.1:18765/image" srcset="http://127.0.0.1:18765/retina 2x">

        - [x] Task

        | A | B |
        |---|---|
        | one | two |

        Math: $\\frac{a}{b}$

        ```javascript
        const answer = 42;
        ```

        ```mermaid
        graph TD
          A[Start] --> B[End]
        ```
        """
        try load(attack, in: web)
        try expect(!recorder.accepted.contains(where: { $0.hasPrefix("diff") }), "document HTML sent a write message")
        try waitForJS(web, expression: "['local-file', 'local-absolute', 'local-relative'].every(alt => document.querySelector('img[alt=' + alt + ']')?.naturalWidth === 1)")
        try evaluate(web, """
        if (window.__injected) throw Error('document script executed');
        if (document.querySelector('#doc script, #doc iframe, #doc object, #doc form, #doc meta')) throw Error('active element survived');
        if ([...document.querySelectorAll('#doc style')].some(el => !el.closest('.mindle-mermaid'))) throw Error('document stylesheet survived');
        for (const el of document.querySelectorAll('#doc *')) {
          for (const attr of el.attributes) {
            if (/^on/i.test(attr.name) || attr.name === 'srcset' || /^javascript:/i.test(attr.value)) throw Error('unsafe attribute survived');
          }
        }
        for (const selector of ['h1', 'strong', 'details summary', 'table', 'input[type=checkbox]', '.katex', 'code.language-javascript', '.mindle-mermaid svg']) {
          if (!document.querySelector('#doc ' + selector)) throw Error('safe feature missing: ' + selector);
        }
        """)
        // Re-render paths must keep using the same sanitizer.
        try evaluate(web, "window.mindleSetAnnotations([{id:'test-note', text:'Safe heading', prefix:'', suffix:'', note:''}]); void window.mindleSearch('Safe');")
        try waitForJS(web, expression: "!!document.querySelector('mark.mindle-hl') && !!document.querySelector('mark.mindle-search')")
        try expect(!recorder.accepted.contains(where: { $0.hasPrefix("diff") }), "overlay re-render sent a write message")

        // Exercise the policy independently of sanitization, using trusted test code.
        try evaluate(web, """
        window.__policyViolations = [];
        document.addEventListener('securitypolicyviolation', event => window.__policyViolations.push(event.effectiveDirective));
        const probe = document.createElement('img');
        probe.setAttribute('onerror', 'window.__inlineExecuted = true');
        probe.src = 'data:image/png;base64,invalid';
        document.body.appendChild(probe);
        const remote = new Image();
        remote.src = 'http://127.0.0.1:18765/csp-image';
        document.body.appendChild(remote);
        void fetch('http://127.0.0.1:18765/csp-fetch').catch(() => {});
        """)
        try waitForJS(web, expression: "window.__policyViolations.includes('script-src-attr') && window.__policyViolations.includes('connect-src') && window.__policyViolations.includes('img-src')")
        try evaluate(web, "if (window.__inlineExecuted) throw Error('CSP allowed inline script');")

        let current = "# Changes\n\nNew paragraph.\n"
        let baseline = "# Changes\n\nOld paragraph.\n\n" + attack
        try load(current, baseline: baseline, in: web)
        try evaluate(web, "if (document.querySelector('#doc [onerror], #doc iframe')) throw Error('unsafe diff baseline');")
        recorder.accepted.removeAll()
        try evaluate(web, "document.querySelector('[data-mindle-diff-action=reject]').click();")
        try wait("legitimate per-chunk revert") { recorder.accepted.contains("diffSetCurrent") }
        try evaluate(web, "document.querySelector('[data-mindle-diff-action=accept-all]').click();")
        try wait("legitimate keep all") { recorder.accepted.contains("diffAcceptAll") }

        try evaluate(web, "window.location.href = 'http://127.0.0.1:18765/navigate';")
        pump()
        try expect(ReaderSecurity.isReaderURL(web.url, readerURL: readerURL), "script navigation left the reader")
        try expect(recorder.externalLinks.isEmpty, "script navigation opened another app")
        try evaluate(web, "const link = document.createElement('a'); link.href = 'https://example.invalid/docs'; document.body.appendChild(link); link.click();")
        try wait("external link routing") { recorder.externalLinks.count == 1 }

        try evaluate(web, "window.DOMPurify = undefined;")
        try load("<img src=x onerror='window.__injected=true'>", in: web, expectFailure: true)

        try checkForeignFrames(root: root)
        print("Reader security: sanitization, CSP, bridge isolation, navigation, and reading/diff regressions passed")
    }

    private static func checkForeignFrames(root: URL) throws {
        let fixture = root.appendingPathComponent(".build/reader-security-frames.html")
        let other = root.appendingPathComponent(".build/reader-security-other.html")
        let script = "webkit.messageHandlers.diffSetCurrent.postMessage({text:'probe'})"
        try "<script>\(script)</script><iframe srcdoc=\"<script>\(script)</script>\"></iframe>".write(to: fixture, atomically: true, encoding: .utf8)
        try "<script>\(script)</script>".write(to: other, atomically: true, encoding: .utf8)
        let recorder = ReaderHarness(readerURL: fixture)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(recorder, name: "diffSetCurrent")
        let web = WKWebView(frame: .zero, configuration: config)
        // Navigation is deliberately unrestricted here to test the message guard alone.
        web.loadFileURL(fixture, allowingReadAccessTo: root)
        try wait("frame messages") { recorder.received.count == 2 }
        try expect(recorder.accepted.count == 1, "a subframe reached the trusted bridge")
        web.loadFileURL(other, allowingReadAccessTo: root)
        try wait("foreign page message") { recorder.received.count == 3 }
        try expect(recorder.accepted.count == 1, "another page reached the trusted bridge")
    }

    private static func load(_ markdown: String, baseline: String? = nil, in web: WKWebView, expectFailure: Bool = false) throws {
        let args = try JSONSerialization.data(withJSONObject: [markdown, false, baseline as Any? ?? NSNull()])
        let json = String(data: args, encoding: .utf8)!
        try evaluate(web, "window.__loadResult = null; void window.mindleLoad(...\(json)).then(() => { window.__loadResult = 'ok'; }).catch(error => { window.__loadResult = String(error); });")
        try waitForJS(web, expression: "window.__loadResult !== null")
        let result = try evaluate(web, "window.__loadResult") as? String
        try expect(expectFailure ? result != "ok" : result == "ok", "reader load: \(result ?? "missing result")")
        pump()
    }

    @discardableResult
    private static func evaluate(_ web: WKWebView, _ script: String) throws -> Any? {
        var done = false
        var value: Any?
        var failure: Error?
        web.evaluateJavaScript(script) { result, error in
            value = result
            failure = error
            done = true
        }
        try wait("JavaScript evaluation") { done }
        if let failure { throw failure }
        return value
    }

    private static func waitForJS(_ web: WKWebView, expression: String) throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if try evaluate(web, expression) as? Bool == true { return }
            pump()
        }
        throw HarnessError.failed("Timed out: \(expression)")
    }

    private static func wait(_ label: String, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { pump() }
        try expect(condition(), "Timed out: \(label)")
    }

    private static func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw HarnessError.failed(message) }
    }
}
