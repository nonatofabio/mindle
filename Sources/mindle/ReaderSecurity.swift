import Foundation
import WebKit

enum ReaderSecurity {
    static func isReaderURL(_ url: URL?, readerURL: URL?) -> Bool {
        guard let url, let readerURL, url.isFileURL, url.query == nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        components.fragment = nil
        return components.url?.standardizedFileURL == readerURL.standardizedFileURL
    }

    static func accepts(_ message: WKScriptMessage, readerURL: URL?) -> Bool {
        message.frameInfo.isMainFrame
            && isReaderURL(message.frameInfo.request.url, readerURL: readerURL)
    }

    static func navigationPolicy(
        for action: WKNavigationAction,
        readerURL: URL?,
        openExternalURL: (URL) -> Void
    ) -> WKNavigationActionPolicy {
        if action.targetFrame?.isMainFrame == true,
           isReaderURL(action.request.url, readerURL: readerURL) {
            return .allow
        }
        // Documents cannot navigate to a page that inherits the native bridge.
        // Only a link the user activates may leave the reader, in another app.
        if action.navigationType == .linkActivated,
           action.sourceFrame.isMainFrame,
           let url = action.request.url,
           ["http", "https", "mailto", "file"].contains(url.scheme?.lowercased() ?? "") {
            openExternalURL(url)
        }
        return .cancel
    }
}
