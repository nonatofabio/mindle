# SSH remote files — v3.1.0-rc5 design

**Status:** approved (brainstorm) — pending spec review
**Date:** 2026-06-12
**Issue:** unfiled feature request (over text; not in git). File a GitHub issue when work starts.

## Problem

Colleagues work on remote developer desktops reached over SSH. Their Markdown
lives on those boxes, not on a network mount, so Mindle can't open it today —
every read/write path funnels through a local `URL` (`String(contentsOf:)`,
`write(to:)`). They want to open a remote path and have Mindle read **and**
write it over their existing SSH access.

## Decisions (locked during brainstorm)

1. **Invocation:** an *Open Remote…* dialog is the primary UX; a `mindle://ssh`
   URL scheme is the power-user shortcut. **MCP `open_file`** also accepts remote
   targets (in rc5).
2. **Transport:** shell out to the system `ssh`/`scp`/`sftp` binaries. Reuses the
   user's `~/.ssh/config`, agent keys, `known_hosts`, ProxyJump — Mindle owns no
   credentials. No embedded SSH library.
3. **Sidecar:** stored **locally**, keyed by the remote target (mirrors the
   existing `http(s)` sidecar pattern). Shared/remote sidecars are a follow-up.
4. **External changes:** **manual refresh** only — no polling. A remote tab gets a
   ↻ Reload affordance; drift detection still runs on reload/save. No background
   SSH connections.
5. **Architecture:** **fetch-to-local-proxy.** On open, fetch the remote file to a
   local cache file and run the *existing* pipeline on it. SSH only ever touches
   the transport edges (open / save / reload). The interior never knows it's
   remote.

## Architecture

### Identity model — the deterministic proxy

A remote target:

```swift
struct SSHTarget: Equatable {
    var userHost: String   // "fabio@cortana.local" or a ~/.ssh/config alias like "devbox"
    var remotePath: String // "/home/fabio/notes/spec.md"
    var canonical: String { "\(userHost):\(remotePath)" }
    var hash: String       // sha256(canonical), truncated (stable, filesystem-safe)
    var basename: String   // (remotePath as NSString).lastPathComponent
}
```

Each `DocumentTab` and the `DocumentStore` gain an optional `remoteTarget:
SSHTarget?`. When set, the tab's `fileURL` points at a **deterministic local
proxy**:

```
~/Library/Application Support/Mindle/ssh-cache/<hash>/<basename>
```

Because the proxy is a real local file, the **entire interior is unchanged** —
markdown-it, PDFKit, the editor, diff-review, and the image scheme handler all
operate on the proxy exactly as on any local file. Two consequences fall out for
free from keying by `<hash>`:

- **Dedupe:** same target → same proxy path → the existing
  `tabs.first(where: { $0.fileURL == url })` check in `open(url:)` activates the
  already-open tab.
- **Sidecar:** `DocumentStore.sidecarURL(for:)` drops `.<basename>.mindle.json`
  as a sibling *inside* the per-target cache dir — local, keyed by the remote
  target, durable across sessions. **No change to `sidecarURL` is required.**

### Watcher behaviour

- The body `FileWatcher` is **suppressed** for remote tabs (`updateWatcher` /
  `syncInactiveWatchers` gain a `remoteTarget == nil` guard alongside the
  existing `url.isFileURL` guards). An FSEvents watch on the proxy would only
  fire on Mindle's own writes — pointless under manual-refresh.
- The **sidecar watcher stays on** (the proxy's sidecar is a local file), so a
  local MCP agent writing annotations to that sidecar is still picked up live.

## Transport module — `SSHTransport`

A new file, `Sources/mindle/SSHTransport.swift` — the **only** place SSH exists.

```swift
protocol ProcessRunner {                 // injectable for tests
    func run(_ launchPath: String, _ args: [String]) async throws -> (status: Int32, stdout: Data, stderr: Data)
}

enum SSHTransport {
    static func fetch(_ target: SSHTarget, to proxyURL: URL, runner: ProcessRunner) async throws
    static func push(_ proxyURL: URL, to target: SSHTarget, runner: ProcessRunner) async throws
}
```

- **`fetch`:** `scp <flags> <userHost>:<remotePath> <tmp>` (or `sftp` batch),
  then atomic `FileManager.moveItem` of `<tmp>` onto the proxy path. A failed or
  partial transfer never clobbers a previously-good proxy.
- **`push`:** upload the proxy to a remote temp path, then `ssh <userHost> mv
  <tmp> <remotePath>` so the remote write is atomic — a dropped connection never
  truncates the real file.
- **Flags (always):** `-o BatchMode=yes -o ConnectTimeout=10`. BatchMode forces
  non-interactive **key/agent auth** (matches the colleagues' setup) and makes a
  password-only host *fail fast* with a clear error instead of hanging on a
  hidden prompt.
- **No shell injection:** every invocation uses `Process` with an **argument
  array**, never a constructed shell string. User-supplied host and path flow as
  literal argv entries, so spaces and metacharacters are inert.

## The three SSH touch-points in `DocumentStore`

1. **Open** — new `func openRemote(_ target: SSHTarget) async`:
   - Dedupe-check by proxy path; if open, activate and return.
   - Publish "Fetching…" status; `try await SSHTransport.fetch`.
   - On success, hand the proxy URL into a refactored
     `finishOpen(url:remoteTarget:)` — the existing tab-construction body of
     `open(url:)` factored out, now parameterised by `remoteTarget`. `open(url:)`
     becomes `finishOpen(url:, remoteTarget: nil)` after reading the local text.
   - On failure: alert summarising stderr; no tab created.
2. **Save** — after the existing local proxy write, if `remoteTarget != nil`,
   `try await SSHTransport.push`. On failure: keep the local edit, mark the tab
   dirty, surface a retry-able error. **The edit is never lost** — it is safe in
   the proxy.
3. **Reload (↻)** — a remote tab exposes a manual Reload affordance:
   re-`fetch` to the proxy, then run the **existing** reload+diff path
   (`reloadFromDisk`-equivalent), so the diff-on-reload banner appears when the
   remote file changed. Drift detection lands on demand.

`open(url:)`, `reloadFromDisk`, and save are synchronous today; the remote
variants are `async` and dispatch their UI mutations back on the main actor.

## UI surface

- **Open Remote… dialog** (`File ▸ Open Remote…`, primary): a text field for
  `[user@]host:/path`, validated on submit (well-formed `host:/path`), with a
  recents list. Remote recents persist the canonical target string (separate
  from `NSDocumentController` local recents).
- **`mindle://ssh` URL scheme** (power users): registered via `CFBundleURLTypes`
  (added in `build.sh`'s Info.plist generation). Shape:
  `mindle://ssh/<user@host>/<path>` — e.g.
  `mindle://ssh/fabio@cortana.local/home/fabio/notes/spec.md`. Routed through the
  existing `pendingURLs` handling in `MindleApp`, parsed to an `SSHTarget`, handed
  to `openRemote`. `open 'mindle://ssh/...'` from a remote-dev terminal works.
- **Remote affordances:** a small host badge on the tab/title so a remote tab is
  visibly remote, plus transient "Fetching… / Saving… / Save failed (retry)"
  status.

## MCP `open_file` — remote targets (rc5)

`open_file` currently takes a local `path`. Extend it to also accept a remote
target — either a `host:/path` string detected by shape, or an explicit
`mindle://ssh/...` URL. The MCP handler parses it to an `SSHTarget` and calls
`AppDelegate.shared?.openFileRemote(target:focusApp:)`, which awaits
`openRemote`. An agent running *on the remote box* (bridged through
`mindle-mcp`) can ask Mindle to open a file it can see locally. The
`MindleMCP/main.swift` tool definition documents the remote form; `agent_tag`
threading is unchanged.

## Error handling & edge cases

- **Unreachable / timeout / auth failure / remote file-not-found:** specific
  alerts. Open failures create no tab; save failures keep the edit and mark
  dirty for retry.
- **Concurrent fetch of the same target:** guarded — a second open while a fetch
  is in flight joins/activates rather than racing a second `scp`.
- **Binary / PDF remote files:** read-only — fetched and rendered via the
  existing PDF path; save/push is gated to text documents (PDFs aren't edited).
- **Path safety:** literal `Process` argv (see Transport). No shell string is
  ever constructed.

## Out of scope (follow-ups)

- **Shared remote sidecars** (co-located `.mindle.json` over SSH, multi-user) —
  its own project: conflict model, remote sidecar polling, agent coordination.
- **Polling / automatic drift** on remote tabs.

## Testing

- **Unit:** target parsing — `user@host:/path`, bare alias `devbox:/path`,
  `mindle://ssh/...`, and malformed inputs; proxy-path / hash determinism;
  sidecar-path derivation from the proxy; save-failure-keeps-dirty.
- **Transport:** a fake `ProcessRunner` asserts exact argv (BatchMode +
  ConnectTimeout present, atomic temp→move ordering on fetch, temp→`mv` on push)
  and maps non-zero exit + stderr to the right thrown error.
- **Manual / integration:** against a real host (`cortana.local` is available).
  Open a remote `.md` → annotate → edit + save → externally change the remote
  file → ↻ Reload shows the diff banner → reopen dedupes → exercise each failure
  path (down host, bad path, auth refusal).

## Release

Ships as **v3.1.0-rc5** on the beta channel: bump `SHORT_VERSION_FALLBACK` in
`build.sh`, write `docs/releases/v3.1.0-rc5.md`, then the standard tag/merge
ritual. rc5 is intended as the last RC before the v3.1.0 stable bundle.
