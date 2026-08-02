# AGENTS.md

> Orientation for AI agents and human contributors. The goal of this file is to convey *how Mindle is built* in addition to *what it does*, so a fresh contributor — human or agent — can act with the same priorities the maintainers have been operating with.

If your tool reads `CLAUDE.md` instead, treat this file the same way. Most modern coding agents (Claude Code, OpenAI Codex, Cursor) pick up `AGENTS.md` automatically.

## What Mindle is — and isn't

Mindle is a native macOS Markdown reader. It's a personal e-reader for `.md` files: serif typography, warm themes, distraction-free reading. Since v2.0 it also speaks MCP so AI agents can read the user's annotations and reply inline.

**It is not:**
- A Markdown *editor*. The agent is the editor. Mindle is the review surface.
- A cloud service. Local-only by default; the one network call (Sparkle auto-update) is opt-in.
- An Electron app. Native SwiftUI, single binary, no runtime dependencies.
- A growth product. No telemetry, no subscriptions, no signup.

If a feature feels like it's pulling Mindle toward "more chrome, more screens, more network," push back. The product's surface area is small on purpose.

## Tenets

Hold these when making non-trivial decisions:

1. **Reading first.** Every feature should make focused reading better or stay out of the way during it. If a new feature pulls visual attention, it earns its place by being load-bearing.
2. **The file is the source of truth.** Annotations live in a sidecar JSON, but they re-anchor against the file via text + context. The file remains a normal `.md` you can edit anywhere — no proprietary formats.
3. **Local-only by default.** Reading, annotating, exporting, and the MCP collaboration loop must all work with zero network. Auto-update is the only network feature and it's opt-in.
4. **Native everything.** SwiftUI + WKWebView + AppKit panels. Don't introduce Electron, JavaFX, or "cross-platform" frameworks — that's an architectural reversal, not a feature.
5. **The agent reads, the agent edits.** Mindle exposes the annotation channel via MCP. File IO stays in the agent's own tools. Don't build a code editor into Mindle — your terminal already has one.
6. **No telemetry. No surprise network calls.** If your change needs the network, it must be (a) user-initiated and (b) clearly disclosed.

## Architecture in 60 seconds

```
SwiftUI shell (window, tabs, toolbar, theme + font + diff state)
  ├── DocumentStore (per window) ── FSEvents file watcher
  ├── MCPServer (one per app, Unix-domain socket)
  ├── UpdaterDelegate ── Sparkle (semver-aware, beta channel opt-in)
  └── WKWebView (reader pane)
        ├── markdown-it     → Markdown → HTML
        ├── highlight.js    → syntax coloring
        ├── KaTeX           → inline + display math
        ├── mermaid         → diagrams (click to expand)
        ├── jsdiff          → diff-on-reload chunks + word-level diff
        └── reader.js       → unified applyAll() pipeline
```

**Per-window state** lives on `DocumentStore` (a `@StateObject` in `RootView`). Each window has its own store; `AppDelegate` keeps weak refs to every store so the MCP server can answer cross-window queries.

**Annotations** anchor via *text + 48 chars of prefix + 48 chars of suffix* (Hypothes.is style). Highlights survive small edits to the file, and the same anchoring makes diff-on-reload re-anchoring coherent.

**The reader pane** is a `WKWebView` running a single `applyAll()` pipeline in `reader.js`. Every state change (annotations, search, diff, file content) rebuilds the same HTML and applies overlays on top — there is no parallel render path.

**MCP** runs in-process. `MCPServer` listens on a Unix-domain socket per app launch; the bundled `mindle-mcp` helper Mach-O proxies stdio MCP from clients to that socket. Each helper launch stamps its events with a per-launch UUID so an agent never wakes on its own writes.

## Coding style

### Swift
- **Comments explain WHY, not WHAT.** If the code is obvious, leave it alone. Reserve comments for hidden constraints, race conditions found in real use, and "this looked redundant but here's why it isn't." Drop comments that say `// MARK: Variables` or `// the controller`.
- **Concrete names.** `pendingCommitAnnotations`, `applyGeneration`, `lastSyncedText`, `mindleCaptureSelectionNow` — not `helper`, `data`, `state`, `manager`.
- **`@MainActor` where the bridge crosses.** AppKit and SwiftUI hops are explicit. The MCP server hops in via `Task { @MainActor in ... }`.
- **Reference types stay weak in caches.** `WeakStoreRef` for the AppDelegate's per-window store registry; cleaned up lazily on each access.
- **No backwards-compat shims.** Mindle is one binary, distributed by us. If you rename a function, change the callers — don't leave a rename + re-export pair.
- **Trust internal code.** Validate at boundaries (user input, MCP messages, file IO). Don't `guard let` your way through internal invariants you control.
- **Don't add features the task didn't ask for.** Mindle's small. Three similar lines are better than a premature abstraction.

### JavaScript (`reader.js`)
- **One pipeline.** All renders go through `applyAll()`. New features hook into it; don't introduce parallel render paths.
- **Generation-guard async passes.** When you `await` something inside `applyAll()`, check `if (gen !== applyGeneration) return` after, so a stale pass doesn't stomp the latest.
- **DOM mutations walk in reverse.** When you modify text nodes inside a range (annotations, diff word marks), iterate the affected segments back-to-front so the remaining offsets stay valid.
- **Don't trust markdown-it inside code fences.** If your feature interpolates HTML, detect open fences (`fenceContextAt`) and break out before injecting — see the diff render pipeline for the pattern.

### CSS
- **Theme tokens, not literals.** All colors derive from CSS custom properties (`--accent`, `--code-bg`, `--rule`) defined per theme on `:root` / `[data-theme]`. New colors get new tokens.
- **Print-mode stripping.** Anything that's editorial chrome (diff banners, word-level marks, search highlights) must hide behind `html.mindle-print-mode` so PDF export reads clean.

## Working with the subsystems

### Annotations
- The selection bridge is debounced 150ms in JS to avoid spamming Swift during drag-selects. For hotkey paths (⌘⇧H, ⌘⇧N), always probe the live selection via `window.mindleCaptureSelectionNow()` and call back through `requestHighlight` / `requestNote` — never read `store.selectionText` directly from the hotkey, it can be stale.
- Threads on annotations are append-only. The `appendThreadMessage` path is used by both the user's reply box and the agent's `comment_on_annotation` MCP tool. Don't fork the path.
- Agent-authored annotations get `author: "agent"`. Self-filtering for the watch loop relies on the per-launch `clientID` UUID stamped into events, not on the author field — both exist for different reasons.
- The reply box is a custom `NSViewRepresentable` (`FocusStableTextEditor`) because SwiftUI's `TextEditor` loses first responder whenever the parent re-renders. If you touch annotation UI, don't replace it.

### Diff-on-reload
- Chunks are line-level (`Diff.diffLines`) at the outer pass and word-level (`Diff.diffWordsWithSpace`) at the inner pass for highlighting.
- Code fences need explicit handling — see `fenceContextAt` plus the `<pre><code>` direct render in `renderChunkBlock`. Don't pass code chunks through `md.render()`; it smart-quotes the text and strips the monospace styling.
- "Keep all / Revert all" applies to the in-flight diff against the user's last accepted baseline. There is no "diff against a commit" feature and there shouldn't be — diff is live, against `lastSyncedText`.

### MCP server
- All MCP tool handlers run on `@MainActor` because they touch `DocumentStore`. Don't relax that.
- Every accepted socket on both ends sets `SO_NOSIGPIPE`. A dead peer must never bring Mindle down via a stray `write()`. If you add a new socket, set this option.
- Messages are length-prefixed JSON over the Unix socket. JSON-RPC framing lives in `MindleMCP/main.swift` (the helper) — keep the in-app protocol simple.
- The watch loop uses `withCheckedContinuation` to suspend the connection until an event arrives. Pin the `sinceID` at registration time, not at signal time — see `AnnotationEventLog`.

### Sparkle / auto-update
- Tags drive everything. A `vX.Y.Z` tag triggers CI → signed/notarized DMG → GitHub release → appcast entry.
- Pre-release tags use a hyphen (`v2.1.0-rc3`). CI auto-flips the `prerelease` flag on the GitHub release and stamps `<sparkle:channel>beta</sparkle:channel>` on the appcast entry.
- `UpdaterDelegate.allowedChannels(for:)` returns `["beta"]` only when the user has toggled "Include Pre-release Updates" in the App menu. Stable items remain visible to everyone.
- The custom `SemverComparator` handles `2.1.0-rc1 < 2.1.0`. Sparkle's default would invert this — don't drop the custom comparator if you touch the updater.
- The About panel reads `CFBundleShortVersionString` via `Bundle.main.infoDictionary` and passes it to `orderFrontStandardAboutPanel` via `.applicationVersion`. AppKit's default code path strips pre-release suffixes — keep the explicit hand-off.

## Release workflow

```
fix/foo            ──┐
feat/bar           ──┼── rebase + ff-merge → main → tag vX.Y.Z[-rcN] → CI publishes
chore/baz          ──┘
```

1. **One commit per branch** is the norm. Squash before merging if you have many.
2. **Rebase onto main, then `merge --ff-only`.** Never merge commits on main — keep history linear.
3. **Release notes live at `docs/releases/vX.Y.Z.md`.** CI prefers these over auto-generated notes when present.
4. **The build number is derived from commit count** (`git rev-list --count`). Don't try to set it manually.
5. **Bump `SHORT_VERSION_FALLBACK` in `build.sh`** when you cut a new release tag, so local builds still report the right version when HEAD isn't exactly on a tag.

For pre-release fixes during an RC cycle: cut a fresh `vX.Y.Z-rc(N+1)`. **Don't retag in place** — Sparkle won't deliver an update if the version string is unchanged, so anyone already on the bad RC stays stuck.

## Things that are easy to get wrong

- **Touching `applyAll()` without bumping the generation guard.** You will create an intermittent race that drops annotations or search marks. Hard to reproduce, easy to ship.
- **Reading `store.selectionText` from a hotkey path.** It's debounced — go through `requestHighlight` / `requestNote` or the live JS probe.
- **Adding a network call.** Local-only is a tenet, not a default. If you genuinely need one, gate it behind explicit user action and document it.
- **Writing comments that explain WHAT.** The code says what it does. Comments say why it does it that way.
- **Committing with `Co-Authored-By` trailers.** The repo's author is `nonatofabio`. AI attribution trailers don't go in commits.
- **Retagging a release in place to ship a "small" fix.** Same-version Sparkle updates aren't delivered. Always bump.

## Recommended skills

If you're using Claude Code with the `superpowers` plugin (or another agent runner with a skill system), these existing skills apply well here:

- **`brainstorming`** — before any non-trivial UI or architecture change. Mindle is small enough to fit the model of it in your head; brainstorming externalises tradeoffs before you commit to one.
- **`debugging`** — for race conditions in the WKWebView/JS bridge or the MCP watch loop. The systemic approach pays off because the bugs hide between Swift and JS.
- **`finishing-a-development-branch`** — for the rebase + ff-merge + cleanup pattern at the end of a feature.

Skills worth writing for this repo specifically (not yet authored):

- **`mindle:cut-release`** — codifies the tag + release notes + appcast flow. Most of it is mechanical, but each step has a foot-gun (hyphenated tags trigger the beta channel, the build number drifts if you don't bump the fallback, signatures need re-issuing after a retag).
- **`mindle:debug-annotation-anchor`** — when a highlight disappears or lands in the wrong place, the failure modes are (1) stale Swift-side selection cache, (2) prefix/suffix mismatch on a re-rendered DOM, (3) re-anchor against a diff's "before" text. A skill that walks these in order would save time.
- **`mindle:add-mcp-tool`** — adding a new MCP tool touches `MCPServer.swift`, `MindleMCP/main.swift`, the README, and (often) the event-log + watch-loop filter. A checklist skill keeps the surface in sync.

## Things to read first

- `README.md` — what Mindle is from the user's perspective.
- `docs/v2-roadmap.md` — where Mindle is heading (multi-user, BYO sync).
- `docs/releases/v2.0.0.md` — the most recent shipped stable release and its dogfooding notes. The "polish-as-bugs" pattern in the notes is instructive.
- `Resources/web/reader.js` — the entire reader pipeline lives here, end-to-end.
- `Sources/mindle/DocumentStore.swift` — the model. When a UI feature misbehaves, the store is usually where the truth is.

## Build & run

Agent-run commands must always have an explicit bounded timeout. Use 30 seconds for quick inspection commands, 2–4 minutes for tests, and at most 5 minutes for a full build. If a command exceeds its bound, stop it, report the timeout, and investigate rather than leaving an unbounded process running.

```bash
./build.sh           # produces build/Mindle.app
open build/Mindle.app
```

Requires macOS 14+, Xcode Command Line Tools, and `xcode-select -p` pointed at a recent Xcode install. No package manager step — Sparkle and the JS vendor libs are checked into the repo so the build is hermetic.
