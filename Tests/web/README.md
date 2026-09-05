# Reader security checks

Run `bash ./run-reader-security-tests.sh`, or `bash ./run-tests.sh` for all checks.
The harness uses the bundled reader in a real WKWebView and the same native
message/navigation policy as the app. It needs a macOS login session with
WebKit helper processes available; it opens no visible windows.

Checks cover document event handlers, SVG scripts, embedded pages, unsafe
links, content security policy enforcement, and messages from subframes or
another page. Native write messages are recorded rather than applied to files.
Network probes use loopback addresses. Disposable image and frame fixtures
are written under `.build`.

Compatibility checks cover safe HTML, tables, task lists, KaTeX, Mermaid,
syntax highlighting, relative/absolute/file-URL images, annotations, search,
and diff actions. Malicious markup is tested in both normal content and a
diff baseline. A missing sanitizer must cause rendering to fail closed.

The executable accepts an optional repository-root argument for testing a
separate copy of the web resources. Against the pre-fix reader, this suite
fails because document scripts execute; against the fixed reader it passes.
