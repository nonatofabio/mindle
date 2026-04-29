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
  <a href="#keyboard-shortcuts">Shortcuts</a> &bull;
  <a href="#build-from-source">Build</a> &bull;
  <a href="#roadmap">Roadmap</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="macOS 14+">
  <img src="https://img.shields.io/badge/swift-6.x-orange?style=flat-square" alt="Swift 6">
  <img src="https://img.shields.io/github/license/nonatofabio/mindle?style=flat-square" alt="MIT License">
  <img src="https://img.shields.io/github/actions/workflow/status/nonatofabio/mindle/build.yml?style=flat-square&label=build" alt="Build status">
  <img src="https://img.shields.io/github/downloads/nonatofabio/mindle/total?style=flat-square&label=downloads" alt="Total downloads">
</p>

---

**Mindle** is a native macOS Markdown reader built for focused, distraction-free reading. Think of it as a personal e-reader for your `.md` files — serif typography, warm themes, and the ability to highlight and annotate passages without ever leaving the document.

No Electron. No subscriptions. No network calls. Just a fast, local, single-binary SwiftUI app.

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

### Workflow
- **Tabs and multi-window** — open many files in one window (`⌘O` adds a tab) or pop a new window with `⌘N`. `⌘W` closes the active tab when more than one is open, otherwise the window.
- **File browser** — scoped sidebar tree of every `.md` and `.txt` in the current folder (`⌘⇧F`). Never escapes upward.
- **Find in document** — live search with match count, `⌘F` / `⌘G` / `⌘⇧G`.
- **Live reload** — external edits (vim, an agent, Dropbox, anything) re-render automatically. Bursty writes are debounced; scroll position is preserved.
- **Diff-on-reload** — when an external write changes the active file, Mindle renders the change as a Word-style track-changes overlay you can ✓ Keep or ✗ Revert per chunk, or whole-document with `⌘⌥⏎` / `⌘⌥⌫`.
- **Quick Look extension** — Spacebar on any `.md` in Finder previews it through the same reader pipeline.
- **PDF export** — `⌘P` produces a paginated Letter-sized PDF with print-styled typography.
- **Auto-update** — opt-in, off by default. EdDSA-verified binaries via [Sparkle](https://sparkle-project.org).

### Annotation
- **Highlight & note** — select any passage, press `⌘⇧H` to highlight or `⌘⇧N` to attach a note. Works across paragraphs, headings, lists, and code blocks.
- **Annotations sidebar** — toggle with `⌘⇧A`. Click any annotation to jump to its passage; notes are editable inline.
- **Persistent locally** — saved to a hidden `.yourfile.md.mindle.json` sidecar. Nothing leaves your machine.
- **Export** — `⌘⇧E` exports highlights and notes as Markdown or JSON.

### Plumbing
- **Native Swift / SwiftUI** — no Electron. Single-binary app, no frameworks to install at runtime.
- **Local-only by default** — auto-update is the lone network feature, opt-in.
- **Signed and notarized** — Developer ID + Apple notarization on every release.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘O` | Open a file (adds a tab if a window is open) |
| `⌘N` | New window |
| `⌘W` | Close active tab (or window, when only one tab is open) |
| `⌘F` | Find in document |
| `⌘G` / `⌘⇧G` | Next / previous match |
| `⌘P` | Export as PDF |
| `⌘⇧E` | Export annotations (Markdown or JSON) |
| `⌘⇧H` | Highlight selection |
| `⌘⇧N` | Add note to selection |
| `⌘⇧A` | Toggle annotations sidebar |
| `⌘⇧F` | Toggle files sidebar |
| `⌘⇧T` | Cycle theme (light / sepia / dark) |
| `⌘+` / `⌘-` | Increase / decrease font size |
| `⌘⌥⏎` | Keep all in-flight changes |
| `⌘⌥⌫` | Revert all in-flight changes |

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

A separate **Quick Look extension** (`MindleQuickLook.appex`) bundles the same web pipeline (minus mermaid) so Spacebar previews in Finder render identically to the in-app reader.

Annotations use a **text + context** anchoring strategy (inspired by [Hypothes.is](https://web.hypothes.is/)): each highlight stores the selected text plus 48 chars of prefix/suffix. This means highlights survive minor edits to the source file — and is what makes diff-on-reload's accept/reject loop coherent: annotations re-anchor against the new text instead of going stale.

## Roadmap

The big-picture plan lives in [`docs/v2-roadmap.md`](docs/v2-roadmap.md). Headlines:

- **v2.0 — MCP collaboration loop.** Mindle becomes the calm review surface for agent-driven markdown work. The agent writes, you read, you mark up; the agent reads your annotations back via Mindle's read-only MCP server and revises. A bundled skill teaches Claude Code (and friends) the loop.
- **Homebrew cask** — `brew install --cask mindle` for one-line install.
- **iOS / iPadOS port** — multiplatform build sharing the same WebKit reader and annotation engine.

## License

[MIT](LICENSE) — use it, fork it, make it yours.
