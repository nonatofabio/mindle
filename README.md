<p align="center">
  <img src="assets/logo.svg" width="128" height="128" alt="Mindle logo">
</p>

<h1 align="center">Mindle</h1>

<p align="center">
  <em>A quiet place to read Markdown.</em>
</p>

<p align="center">
  <a href="https://nonatofabio.github.io/mindle/"><strong>Website</strong></a> &bull;
  <a href="#install">Install</a> &bull;
  <a href="#features">Features</a> &bull;
  <a href="#agent-collaboration">Agents</a> &bull;
  <a href="#keyboard-shortcuts">Shortcuts</a> &bull;
  <a href="#build-from-source">Build</a> &bull;
  <a href="#roadmap">Roadmap</a> &bull;
  <a href="#contributors">Contributors</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="macOS 14+">
  <img src="https://img.shields.io/badge/swift-6.x-orange?style=flat-square" alt="Swift 6">
  <img src="https://img.shields.io/badge/license-MIT%20%2B%20Commons%20Clause-blue?style=flat-square" alt="MIT + Commons Clause (v2.0+)">
  <img src="https://img.shields.io/github/actions/workflow/status/nonatofabio/mindle/build.yml?style=flat-square&label=build" alt="Build status">
  <img src="https://img.shields.io/github/downloads/nonatofabio/mindle/total?style=flat-square&label=downloads" alt="Total downloads">
</p>

---

**Mindle** is a native macOS Markdown reader built for focused, distraction-free reading. Think of it as a personal e-reader for your `.md` files — serif typography, warm themes, and the ability to highlight and annotate passages without ever leaving the document.

Since v2.0, Mindle also speaks MCP. When you're collaborating with an AI agent on a document, your annotations become a back-and-forth channel anchored to the passage — you mark up, the agent picks up the event, addresses it, replies inline in the thread. The conversation lives in the file, not in a chat window.

As of v2.1, that conversation can include teammates too. Annotations carry author identity, status (open / resolved / wontfix), assignee, labels, and a threaded reply trail. Any teammate with the same `.md` + `.mindle.json` pair on a shared drive (iCloud / Dropbox / git) becomes a co-author — Mindle just makes you see them. No accounts, no backend.

No Electron. No subscriptions. No telemetry. The auto-update check is the only network call, and it's opt-in.

## Install

### Download (recommended)

Grab the latest `Mindle.dmg` from [**Releases**](https://github.com/nonatofabio/mindle/releases), open it, and drag **Mindle** into **Applications**. Signed with a Developer ID and notarized by Apple — no Gatekeeper prompt, no terminal commands.

### Build from source

```bash
git clone https://github.com/nonatofabio/mindle.git
cd mindle
./build.sh
open build/Mindle.app
```

Requires **macOS 14+** and **Xcode Command Line Tools** (`xcode-select --install`).

## Features

### Reading
- **Full GitHub-Flavored Markdown** — tables, task lists, footnotes, strikethrough, syntax-highlighted code, emoji, nested lists, raw HTML. Powered by [markdown-it](https://github.com/markdown-it/markdown-it) + [highlight.js](https://highlightjs.org).
- **LaTeX math** — inline (`$a^2 + b^2 = c^2$`) and display (`$$ \int e^{-x^2} dx = \sqrt{\pi} $$`) blocks rendered with [KaTeX](https://katex.org), bundled locally.
- **Mermaid diagrams** — flowcharts, sequence diagrams, and the rest, rendered inline. Click to expand.
- **Images** — relative, absolute, `file://`, and `data:` URLs all resolve. Remote `http(s)` is blocked — no tracking pixels.
- **YAML frontmatter** — files like `SKILLS.md` show their `---`-delimited block as a syntax-highlighted code fence instead of two horizontal rules around plain text.
- **Three themes** — Light, Sepia, Dark. Cycle with `⌘⇧T`.
- **Typography controls** — scale the serif reading font with `⌘+` / `⌘-`.
- **Reading width** — three-stop column control (Narrow / Medium / Wide) under **View → Reading Width** with `⌘1` / `⌘2` / `⌘3`. Narrow is the typography-recommended 680px column; Medium and Wide fill more of the horizontal space on large displays.
- **Reader font** — swap between the default serif stack and **OpenDyslexic** (bundled, SIL OFL) under **View → Reader Font**. Code blocks stay monospace regardless.
- **Bionic Text** — toggle under **View** that bolds the first half of each word, an aid for re-anchoring the eye when scanning long prose. Skips code, headings, and already-bold runs.

### Workflow
- **Tabs and multi-window** — open many files in one window (`⌘O` adds a tab) or pop a new window with `⌘N`. Each tab carries its own scroll, theme, font scale, and collaborator registry. `⌘W` closes the active tab when more than one is open, otherwise the window.
- **Open a folder** — `⌘⌥O` opens a local directory directly.
- **SSH profiles** — the ssh button at the top left opens the favorite profile from `~/Library/Application Support/Mindle/ssh-profiles.yaml` or **Mindle → Settings → SSH Profiles**.
- **Open remote URLs** — `⌘⇧L` opens any `http(s)` URL pointing at raw Markdown (a GitHub raw link, a hosted doc) as a tab. Annotations on URL documents persist locally keyed by URL hash, so re-opening the same URL brings the annotations back.
- **Open from Clipboard** — `⌘⇧V` opens the pasteboard contents as a Markdown tab. Use this when the source is behind a login your browser already handles (internal GitLab raw, Confluence, anything auth-walled): copy the raw Markdown there, paste it here. Tabs are content-addressed, so re-pasting identical text re-opens the same tab with its prior annotations.
- **File browser** — scoped sidebar tree of `.md`, `.markdown`, `.mdown`, `.mkd`, `.txt`, and `.pdf` files (`⌘⇧F`). Additional configuration is available under **Mindle → Settings → File Browser**.
- **Find in document** — live search with match count, `⌘F` / `⌘G` / `⌘⇧G`.
- **Live reload** — external edits (vim, an agent, Dropbox, anything) re-render automatically. Bursty writes are debounced; scroll position is preserved. Sidecar changes (a teammate's annotation arriving via shared folder or `git pull`) flow in the same way.
- **Diff-on-reload** — when an external write changes the active file, Mindle renders the change as a Word-style track-changes overlay you can ✓ Keep or ✗ Revert per chunk, or whole-document with `⌘⌥⏎` / `⌘⌥⌫`. Diffs run a second pass at word granularity inside each line, so you see just the changed words struck or underlined — not the whole line.
- **Collapsible YAML frontmatter** — `---`-delimited blocks at the top of a file collapse behind a small chevron; click to inspect. PDF export force-opens them.
- **PDF export** — `⌘P` produces a paginated Letter-sized PDF with print-styled typography.
- **Auto-update** — opt-in, off by default. EdDSA-verified binaries via [Sparkle](https://sparkle-project.org). Pre-releases ship on a separate `beta` channel; flip **Mindle → Include Pre-release Updates** to opt in.

### Annotation
- **Highlight & note** — select any passage, press `⌘⇧H` to highlight or `⌘⇧N` to attach a note, or `⌘⇧K` to add a comment to the current selection. Works across paragraphs, headings, lists, and code blocks.
- **Annotations sidebar** — toggle with `⌘⇧A`. Click any annotation to jump to its passage; notes are editable inline. The new card auto-scrolls into view.
- **Identity-colored highlights** — set your alias once (click the badge at the top of the sidebar) and your highlights tint with your registered color in the reader pane. A teammate's highlights tint with theirs. CSS `color-mix` against the current theme keeps every tint legible against light, sepia, and dark.
- **Status, assignment, labels** — every card carries a status pill (**OPEN / RESOLVED / WONTFIX**) with one-click Resolve/Reopen, an Assign dropdown for handing it to a collaborator, and label chips (`question` / `blocker` / `nit` / `todo` / `suggestion`).
- **Threads** — each annotation carries a conversation. You, your teammates, and the agent can reply back and forth in a single-column transcript with per-author color stripes and aliases. Return commits a reply; Shift+Return inserts a newline.
- **Persistent locally** — saved to a hidden `.yourfile.md.mindle.json` sidecar alongside the document. Nothing leaves your machine; sync is whatever you point the folder at (iCloud, Dropbox, git…).
- **Export** — `⌘⇧E` exports highlights and notes as Markdown or JSON.

### Team collaboration (new in v2.1)
- **Sync is your folder.** The `.md` + `.mindle.json` pair lives wherever you keep your notes. Drop the file into iCloud / OneDrive / Dropbox / a git repo — anyone with a copy is a co-author. No accounts, no backend, no servers.
- **Author identity.** A small badge at the top of the sidebar lets you set your alias and a color. Every save auto-registers you in the document's collaborator registry; the next person to open the file sees your annotations stamped with your name.
- **Live sidecar updates.** When a teammate pushes a change to the shared folder (or you `git pull` it), Mindle's sidecar watcher pulls it in without close-and-reopen. New annotations and replies appear inline as they arrive.
- **Per-document registries.** Each open tab carries its own collaborator state — colors and aliases never bleed across documents in the same window.
- **Status + assignment + labels** are the shared triage surface for the team — see the **Annotation** section above.

### Agent collaboration (new in v2.0)
- **Read-side parity** — an agent can list every file you have open in Mindle and read your annotations on each. Selection text and surrounding context arrive verbatim, so the agent knows exactly what you're pointing at.
- **Write-side affordances** — the agent can post comments to a thread, open a fresh annotation on a passage ("does this read better?"), and dismiss its own annotations with a one-line summary. Agent-authored annotations are visually distinct (muted dot, "Agent" label).
- **Ambient watch loop** — a long-polling tool lets the agent wait for your next annotation or thread reply. You annotate, the agent wakes within a second, addresses it, waits again. Pure MCP, so any compatible client (Claude Code, Codex, Cursor, custom) can drive the loop.
- **Self-filtering** — the agent's own mutations never wake itself. Each helper process gets a per-launch UUID; events tagged with that UUID are filtered out of its own watch responses.

See [Agent Collaboration](#agent-collaboration) below for setup.

### Plumbing
- **Native Swift / SwiftUI** — no Electron. Single-binary app, no frameworks to install at runtime.
- **Local-only by default** — auto-update is the lone network feature, opt-in.
- **Signed and notarized** — Developer ID + Apple notarization on every release.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘O` | Open a file (adds a tab if a window is open) |
| `⌘⌥O` | Open a folder in the file sidebar |
| `⌘N` | New window |
| `⌘W` | Close active tab (or window, when only one tab is open) |
| `⌘F` | Find in document |
| `⌘G` / `⌘⇧G` | Next / previous match |
| `⌘⇧L` | Open URL… (fetch a raw-Markdown URL as a tab) |
| `⌘⇧V` | Open from Clipboard (pasteboard contents as a Markdown tab) |
| `⌘P` | Export as PDF |
| `⌘⇧E` | Export annotations (Markdown or JSON) |
| `⌘⇧H` | Highlight selection |
| `⌘⇧N` | Add note to selection |
| `⌘⇧K` | Add comment to selection |
| `⌘⇧A` | Toggle annotations sidebar |
| `⌘⇧F` | Toggle files sidebar |
| `⌘⇧D` | Toggle debug console (annotation lifecycle events) |
| `⌘⇧T` | Cycle theme (light / sepia / dark) |
| `⌘1` / `⌘2` / `⌘3` | Reading width: Narrow / Medium / Wide |
| `⌘+` / `⌘-` | Increase / decrease font size |
| `⌘⌥⏎` | Keep all in-flight changes |
| `⌘⌥⌫` | Revert all in-flight changes |
| `Return` (in annotation editor) | Commit the note / reply |
| `⇧Return` (in annotation editor) | Insert a newline |

## Agent Collaboration

Mindle ships an MCP (Model Context Protocol) server so an agent can read your open files, see your annotations, and join the conversation. The collaboration loop is the headline v2.0 feature; everything below is optional but rewarding.

### Setup with Claude Code

```bash
claude mcp add mindle /Applications/Mindle.app/Contents/MacOS/mindle-mcp
```

Restart Claude Code so it handshakes the new server, then ask:

> watch my Mindle annotations and answer them

The agent calls `wait_for_annotation_event` in a loop. You annotate (`⌘⇧N` for a note, then type, then Return); the agent wakes within a second, reads the surrounding context, and posts a reply in the thread or edits the file and clears the annotation.

Any MCP-aware client works the same way — the tool descriptions carry enough protocol guidance that vanilla agents run the loop without a custom skill.

### Tools exposed

| Tool | Direction | What it does |
|------|-----------|--------------|
| `list_open_files` | read | Every file open in any Mindle window |
| `get_annotations(path)` | read | Annotations + threads on a file |
| `get_collaborators(path)` | read | Identity registry for a document |
| `comment_on_annotation(path, id, text)` | write | Append an agent message to a thread |
| `react_to_annotation(path, id, kind, message_id?)` | write | Toggle a 👍 / ❤️ / 😄 reaction on an annotation or thread message |
| `create_annotation(path, text, prefix, suffix, note)` | write | Open an agent-authored annotation on a passage |
| `clear_annotation(path, id, summary)` | write | Mark an annotation done with a summary |
| `resolve_annotation(path, id, author?)` | write | Move an annotation to **resolved** |
| `assign_annotation(path, id, assignee)` | write | Hand an annotation to a collaborator |
| `wait_for_annotation_event(timeout_seconds, since_event_id)` | read | Long-poll for the next user event (created / thread reply / deleted) |

The server is read-only as far as the file system is concerned — file IO stays in the agent's own tools. Mindle exposes only the annotation channel.

## Architecture

```
SwiftUI shell (window, tabs, toolbar, theme + font + diff state)
  ├── DocumentStore (per window) ── FSEvents file watcher
  └── WKWebView (reader pane)
        ├── markdown-it     → Markdown → HTML (+ task-lists, footnote, anchor)
        ├── highlight.js    → syntax coloring
        ├── KaTeX           → inline + display math
        ├── mermaid         → diagrams (click to expand)
        ├── jsdiff          → diff-on-reload chunks
        └── reader.js       → unified applyAll() pipeline:
                              annotation overlays, search marks,
                              diff render, scroll preservation
```

Annotations use a **text + context** anchoring strategy (inspired by [Hypothes.is](https://web.hypothes.is/)): each highlight stores the selected text plus 48 chars of prefix/suffix. This means highlights survive minor edits to the source file — and is what makes diff-on-reload's accept/reject loop coherent: annotations re-anchor against the new text instead of going stale.

## Roadmap

The big-picture plan lives in [`docs/v2-roadmap.md`](docs/v2-roadmap.md). Where we are:

**Shipped**

- ✅ **v2.0 — MCP collaboration loop.** Mindle is the review surface for agent-driven markdown work. The agent writes, you mark up; the agent reads your annotations and threads back, replies inline, or addresses them by editing the file. See [Agent Collaboration](#agent-collaboration).
- ✅ **v2.1 — Multi-user collaboration.** Identity, author-stamped annotations, status / assignment / labels, threaded replies with per-author colors, and a sidecar watcher so a teammate's edits land in the open document live. A colleague editing your file in iCloud / OneDrive / Dropbox / git is architecturally indistinguishable from an agent — Mindle just makes you see them. No new sync code; the shared folder is the transport.
- ✅ **v2.2 — Collaboration polish + typography.** 👍 / ❤️ / 😄 reactions on annotations and thread replies (with an agent-side `react_to_annotation` MCP tool), **Open from Clipboard** for Markdown sources behind a login your browser already handles, three-stop **Reading Width** control, bundled **OpenDyslexic** font, **Bionic Text** rendering, and selectable text inside annotation cards.

**v3 — Two paths**

- **PDF as a content surface.** Open arxiv papers and other PDFs in Mindle alongside Markdown. Same annotation primitive, same sidecar (`.paper.pdf.mindle.json`), same agent loop, same team-collab story — built on PDFKit. The researcher's natural place for "read this paper, redline it, talk to the agent about it."
- **Edit-as-annotation.** A new annotation kind that proposes a text replacement instead of a comment. Accept writes through to the file; reject discards. Composes with everything: agents propose edits the same way they leave comments, teammates' suggested edits arrive as track-changes cards via the sidecar watcher, Mindle stays reader-first while the WYSIWYG-edit ask gets answered as reviewing-with-receipts.

**Eventually**

- **Bring-your-own sync (S3 first).** A `SyncProvider` protocol with an S3 backend for teams whose markdown lives in a bucket. ETag-based optimistic concurrency, conflicts surfaced through the same diff-on-reload UX. Tentative; shared-folder sync may be enough for most teams.
- **Homebrew cask** — `brew install --cask mindle` for one-line install.
- **iOS / iPadOS port** — multiplatform build sharing the same WebKit reader and annotation engine.

## Contributors

A huge thank-you to [**@ADAS-Ash**](https://github.com/ADAS-Ash) for landing the foundation of v2.1's team-collaboration feature ([PR #17](https://github.com/nonatofabio/mindle/pull/17)) — the annotation data model extensions (status, assignee, labels), `IdentityManager`, the collaborator registry, identity-colored highlights, the debug console, the `⌘⇧K` shortcut, and the `resolve` / `assign` / `get_collaborators` MCP tools. The polish on top (per-tab registries, sidecar watcher, sidebar author cues) all built directly on that work.

And to [**@ad-cqc**](https://github.com/ad-cqc) for shaping v2.2's polish round — filing the **Reading Width** request ([#27](https://github.com/nonatofabio/mindle/issues/27)) that drove the three-stop column control, and contributing [PR #30](https://github.com/nonatofabio/mindle/pull/30) for selectable text inside annotation cards. The PR correctly diagnosed that SwiftUI's `Text(...).textSelection(.enabled)` doesn't survive the sidebar's per-mutation re-render, and added a clean `SelectableText` `NSViewRepresentable` with wrap-aware `intrinsicContentSize` — the right pattern for any future read-only text we want selectable in the sidebar.

## License

Mindle **v2.0 and later** is licensed under [**MIT + Commons Clause**](LICENSE). Use it, fork it, modify it, embed it in your own work — same MIT freedoms you'd expect — with one added condition: you may not *Sell* the Software (or sell hosting / support / services whose value derives substantially from it) without a separate commercial agreement. For commercial licensing inquiries, please get in touch.

Versions **v1.x** were released under the pure [MIT License](https://opensource.org/license/mit/) and remain available under those terms in the corresponding v1.x release tags.
