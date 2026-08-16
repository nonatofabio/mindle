import AppKit
import Foundation
import WebKit

final class HarnessNavigationDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        self.error = error
        finished = true
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        self.error = error
        finished = true
    }
}

@discardableResult
func spinRunLoop(until deadline: Date, condition: () -> Bool) -> Bool {
    while !condition() && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return condition()
}

func loadWebView(htmlURL: URL) throws -> WKWebView {
    let config = WKWebViewConfiguration()
    config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: ImageSchemeHandler.scheme)
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
    let navigation = HarnessNavigationDelegate()
    webView.navigationDelegate = navigation
    webView.loadFileURL(
        htmlURL,
        allowingReadAccessTo: URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    )
    guard spinRunLoop(
        until: Date().addingTimeInterval(15),
        condition: { navigation.finished }
    ) else {
        throw NSError(domain: "ReaderImageHarness", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Timed out loading \(htmlURL.path)"
        ])
    }
    if let error = navigation.error { throw error }
    return webView
}

func waitForJavaScriptResult(
    in webView: WKWebView,
    expression: String,
    timeout: TimeInterval = 15
) throws -> Any {
    var result: Any?
    var evaluationError: Error?
    var evaluationInFlight = false
    let deadline = Date().addingTimeInterval(timeout)

    let completed = spinRunLoop(until: deadline) {
        if result != nil || evaluationError != nil { return true }
        if !evaluationInFlight {
            evaluationInFlight = true
            webView.evaluateJavaScript(expression) { value, error in
                evaluationInFlight = false
                if let error {
                    evaluationError = error
                } else if let value, !(value is NSNull) {
                    result = value
                }
            }
        }
        return false
    }
    if let evaluationError { throw evaluationError }
    guard completed, let result else {
        throw NSError(domain: "ReaderImageHarness", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for JavaScript result."
        ])
    }
    return result
}

func runPipelineHarness(htmlPath: String = "Tests/web/reader-image-harness.html") throws {
    let htmlURL = URL(
        fileURLWithPath: htmlPath,
        relativeTo: URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ).standardizedFileURL
    let webView = try loadWebView(htmlURL: htmlURL)
    guard let result = try waitForJavaScriptResult(
        in: webView,
        expression: "window.__mindleHarnessResult || null"
    ) as? [String: Any] else {
        throw NSError(domain: "ReaderImageHarness", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Harness returned an unexpected result."
        ])
    }
    guard result["passed"] as? Bool == true else {
        throw NSError(domain: "ReaderImageHarness", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Reader pipeline checks failed: \(result)"
        ])
    }
    print("✓ Reader image pipeline: path encoding and post-image passes verified")
}

func runManualLocalFixture() throws {
    let root = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    )
    let fixtureDirectory = root
        .appendingPathComponent("Tests/fixtures/image-rendering", isDirectory: true)
    let markdown = try String(
        contentsOf: fixtureDirectory.appendingPathComponent("README.md"),
        encoding: .utf8
    )
    let readerURL = root.appendingPathComponent("Resources/web/reader.html")
    let webView = try loadWebView(htmlURL: readerURL)
    let script = """
    window.__mindleManualResult = null;
    window.mindleSetBaseDir(\(javascriptString(fixtureDirectory.path)));
    window.mindleLoad(\(javascriptString(markdown)), false, null).then(() => {
      setTimeout(() => {
        const image = document.querySelector("img");
        window.__mindleManualResult = {
          src: image ? image.getAttribute("src") : null,
          complete: image ? image.complete : false,
          width: image ? image.naturalWidth : 0,
          height: image ? image.naturalHeight : 0,
          heading: document.querySelector("h1")?.textContent || ""
        };
      }, 250);
    }).catch(error => {
      window.__mindleManualResult = { fatal: String(error) };
    });
    """
    webView.evaluateJavaScript(script)
    guard let result = try waitForJavaScriptResult(
        in: webView,
        expression: "window.__mindleManualResult || null"
    ) as? [String: Any] else {
        throw NSError(domain: "ReaderImageHarness", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "Manual fixture returned an unexpected result."
        ])
    }
    let complete = result["complete"] as? Bool == true
    let width = result["width"] as? Int ?? 0
    let height = result["height"] as? Int ?? 0
    let heading = result["heading"] as? String
    guard complete, width == 120, height == 80, heading == "Local image fixture" else {
        throw NSError(domain: "ReaderImageHarness", code: 6, userInfo: [
            NSLocalizedDescriptionKey: "Manual local rendering failed: \(result)"
        ])
    }
    print("✓ Manual local image fixture: sample.svg rendered at \(width)×\(height)")
}

func javascriptString(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value])
    let array = String(data: data, encoding: .utf8)!
    return String(array.dropFirst().dropLast())
}

@main
struct ReaderImageHarnessMain {
    static func main() {
        _ = NSApplication.shared
        do {
            let arguments = CommandLine.arguments
            if !arguments.contains("--manual-only") {
                let htmlPath: String
                if let index = arguments.firstIndex(of: "--html"),
                   arguments.indices.contains(index + 1) {
                    htmlPath = arguments[index + 1]
                } else {
                    htmlPath = "Tests/web/reader-image-harness.html"
                }
                try runPipelineHarness(htmlPath: htmlPath)
            }
            if !arguments.contains("--skip-manual") {
                try runManualLocalFixture()
            }
        } catch {
            fputs("Reader image harness failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
