# Mindle v2.0 Roadmap

**Date:** 2026-04-28
**Status:** Living plan — adjust as releases land
**Context:** Builds on [`typora-market-research.md`](./typora-market-research.md) and [`reader-only-positioning.md`](./reader-only-positioning.md). The reader-only positioning won; the editor pivot is shelved. v2.0 is the milestone that turns Mindle into the calm collaboration surface for AI-driven markdown work.

---

## Vision

> *AI writes. You read, you mark up. The agent reads your notes back.*

No chat sidebar, no thread history, no editor surface — just the document, your annotations, and the agent's proposed changes as track-style diffs. The absence of those things is the differentiator. The "co-author in the office" feel is the product.

**The unique loop nobody else has:**

1. Agent writes (or revises) a markdown file via its own tools (Write/Edit).
2. Mindle picks up the change via file-watch and renders it as a *track-changes diff* against the last-synced version.
3. User reads, annotates passages with directives ("rewrite for non-technical readers", "expand this").
4. Agent calls `get_annotations` via Mindle's MCP, sees the directives, makes the requested changes.
5. Agent calls `clear_annotation(id, summary)` — the summary attaches to the corresponding diff chip in Mindle, closing the loop visibly.

Mindle's MCP is **read-only by design.** The agent already has Write/Edit; Mindle is purely the human-feedback channel.

---

## v1.5 — Foundation

Four independent ships, no architectural risk. Pick whichever lands cleanest first; nothing in v1.6 / v2.0 depends on the order.

- **File watch + live reload.** FSEvents-based. Debounce on bursts (size-stability check: don't reload until file size has been stable for ~200ms — guards against agent mid-write). Preserve scroll position. Preserve in-flight selection.
- **LaTeX rendering.** Vendor KaTeX into `Resources/web/vendor/` alongside Mermaid. Markdown-it plugin renders `$…$` and `$$…$$`. Table stakes for AI output (math is common in research-style markdown).
- **Quick Look extension.** Separate macOS app extension target. Renders the same HTML pipeline as the main app. Signed alongside the main bundle. Universal ask in every reader-launch thread; Smackdown shipping it earned immediate upvotes.
- **`.md` default-app handling polish.** Info.plist UTI declarations are already there; add a one-time, declinable "Make Mindle the default for `.md`" prompt on first launch.

## v1.6 — Diff-on-reload (the headline UX leap)

The Word-style track-changes surface, mapped to markdown. *Valuable on its own* — anyone editing the file in vim, Cursor, or Claude Code outside Mindle gets visible change tracking. Earns the "co-author in the office" feel before MCP is in the picture.

- **Snapshot model.** `lastSyncedText` per tab in `DocumentStore` (alongside `rawText`). Live-reload computes the diff against the snapshot, not just clobbers the view.
- **Diff engine.** Vendor a JS diff lib into `Resources/web/vendor/`. Bench `diff-match-patch` (gold standard, heavier) vs. `jsdiff` (lighter, coarser) on realistic-sized prose docs before committing.
- **Diff render.** CSS: insertions highlighted, deletions struck through. **Paragraph-block chunks with word-level inner highlights** — line-level too coarse for prose, character-level too noisy.
- **Accept / reject chips.** Per chunk. Accept clears the diff state and the new version becomes the baseline. Reject writes the original back to disk.
- **Sidecar extension.** Persist in-flight diff state so an unfinished review survives app restart.

The user never types markdown. They mark up, accept, reject. The "editor" *is* the diff review.

## v2.0 — MCP collaboration (the milestone)

The release that ties the loop together and earns the major version bump.

- **`mindle-mcp` helper binary** in `Mindle.app/Contents/MacOS/`. Stdio MCP server, talking to the running app via Unix socket (with distributed-notifications fallback). Clear error when no Mindle instance is running.
- **MCP tools (read-only by design):**
  - `list_open_files` — what's currently open in Mindle
  - `read_file` — file content + annotations in one call
  - `get_annotations` — annotations for a file
  - `clear_annotation(id, summary)` — mark addressed; summary attaches to the diff chip
- **Bundled `mindle-collaboration` skill** at `docs/skills/mindle-collaboration.md`. Install path published in the Mindle docs (drop into `~/.claude/skills/` for Claude Code; equivalent for other harnesses). The skill teaches:
  - **Tool list as deferred tools** — names only, no schemas in context until first use (zero context cost).
  - **The collaboration loop** — write file → suggest the user review in Mindle → wait for signal → `get_annotations` → revise → `clear_annotation(id, summary)`.
  - **Recognizing user intent.** *"Let me review in Mindle," "I'll mark it up," "annotate"* → stop editing and wait. *"Open in Mindle"* → ensure the file is written and suggest the user open it.
  - **Etiquette.** Don't poll. Trust note prose — don't ask for clarification on every annotation. Summaries should be concrete ("rewrote intro for non-technical readers"), not generic ("addressed feedback").
- **Theme polish pass.** "Themes that feel designed", not just light/dark/sepia variations. Smackdown's cyberpunk theme is a reference point for personality.
- **Landing-page rewrite + launch video.**

**Meta-loop worth mentioning in launch:** v1.4 shipped YAML frontmatter rendering as a code block specifically because `SKILLS.md` files have frontmatter. The skill we ship in v2.0 *is* a SKILLS-style file. Mindle renders its own skill beautifully.

---

## v2.1 — Multi-user collaboration foundation

The same diff-on-reload + annotation surface that closes the *agent* loop also closes the *teammate* loop — a colleague editing your file in iCloud/OneDrive/Dropbox is architecturally indistinguishable from an agent editing it. v2.1 makes that legible without shipping any sync code of our own.

> *Your teammate is just another writer to the file. Mindle makes you see them.*

- **Identity.** New `Mindle → Identity` setting: display name + color, stored in `~/Library/Preferences/local.fnp.mindle.plist`. Defaults to system username + a deterministic colour from the name hash. Skippable; private to the local machine until they touch a shared file.
- **Author-stamped sidecar.** Extend `Annotation` and the diff baseline record with `author` (string) and `authorColor` (hex). Old sidecars round-trip clean — missing field reads as "unknown."
- **Diff banner attribution.** Today's banner says *"3 pending changes."* Becomes *"3 changes from Alice · synced 30s ago"* / *"3 changes from agent"* / *"3 external changes"*. Heuristic: edits arriving over MCP's `clear_annotation` path → agent; edits via file watcher whose sidecar lists a fresh author entry → that teammate; everything else → unknown external.
- **Annotation colour per author.** The dot and the left-edge rule in the annotations sidebar use the author's colour. Hover shows the author name. Today's single-user view still looks identical for solo files (everything one colour).
- **Provider detection + "Shared" badge.** When the active file resolves to a path under a known cloud-drive root (`~/OneDrive*`, `~/Library/CloudStorage/OneDrive-*`, `~/Library/Mobile Documents/com~apple~CloudDocs/`, `~/Dropbox/`, `~/Library/CloudStorage/Dropbox/`, `~/Library/CloudStorage/GoogleDrive-*`), the toolbar shows a *"Shared · OneDrive"* (or matching) badge. Pure path-prefix detection — no provider APIs, no OAuth, no network.
- **Conflict-copy detection.** When the file watcher sees a sibling matching `<name> (conflict|conflicting copy) .*\.md` show up, surface a *"Conflicting copy from \<author\>"* prompt that opens both versions in tabs side-by-side with diff visible. The user picks the winner and the loser is moved to a `~/.mindle-trash/` quarantine.

**Hard scope boundaries (kept off the table on purpose):**
- No OneDrive / Google Drive / Dropbox **API** integration. The user's existing desktop sync client is the transport; Mindle never authenticates against the provider. This is what keeps *"No network calls"* on the README honest.
- No real-time presence, no live cursors, no "Alice is typing." Closest possible is a heartbeat object once v2.2 lands a sync provider that supports one.
- No identity service. Display name is whatever the user types — same trust model as a markdown filename.

**Who it's for:** anyone whose teammates already share files via iCloud/OneDrive/Dropbox/Google Drive/Syncthing/a shared NAS. Roughly 80% of the audience inherits collaboration the day v2.1 ships.

## v2.2 — Bring-your-own sync (S3 first)

For users whose markdown lives in a server-side bucket and not a desktop-synced cloud drive. v2.1's collaboration UX is reused unchanged — v2.2 just plugs a different transport underneath.

- **`SyncProvider` protocol.** Pull, push (with optimistic-concurrency token), list, observe. Three concrete implementations to start:
  - **`LocalSyncProvider`** — the default no-op. File is on disk; OS handles any sync. This is what every existing user already runs implicitly.
  - **`S3SyncProvider`** — the first real backend.
  - **`WebDAVSyncProvider`** — deferred to v2.3 unless demand pulls it in earlier.
- **S3 sync model.**
  - Config: bucket + region + prefix, credentials sourced from standard AWS chain (env vars → `~/.aws/credentials` → IAM role on EC2). No bespoke credential UI; if the user wants a non-default profile, they pick a profile name.
  - **Pull:** `ListObjectsV2` against the prefix every 30 seconds (configurable). ETag-based diff against a local index. Anything changed is downloaded into `~/Library/Caches/local.fnp.mindle/s3/<bucket-uuid>/`. From there, Mindle's file watcher takes over — the rest of the UX is identical to v2.1.
  - **Push:** debounced 5s after a local change. Upload with `If-Match: <last-known-ETag>`. On precondition failure, another writer beat us — pull their version, surface as a diff via the same machinery, user resolves.
  - **Conflict on simultaneous edit:** loser's local copy is written to `<file> (conflict from <author>).md` and surfaced the same way as v2.1's cloud-drive conflict path.
- **Settings UI.** New *Sync* pane: pick a provider, configure it, see status (last pull time, last push time, error if any). One backend per Mindle install for v2.2 — multi-backend can come later if anyone asks.
- **Auth surface.** Credentials never leave the Keychain. The Settings pane stores access-key/secret in Keychain, never plaintext. Read-only env-var / profile fallback for users on managed AWS workstations.

**Hard scope boundaries:**
- **No CRDT, no operational transform.** Last-write-wins per file, with the diff/conflict surface as the safety net. The diff-on-reload UX is doing the heavy lifting — Mindle assumes humans can read a diff better than a CRDT can guess intent on prose.
- **No object-versioning UI.** If the bucket has S3 versioning on, that's a server-side feature, not Mindle's concern.
- **No bucket creation flow.** Users come with a bucket; Mindle uses it. We're not in the AWS account-management business.

**Who it's for:** technical users, small teams self-hosting on AWS or AWS-compatible (R2, MinIO, Backblaze B2 via the S3 endpoint). Smaller audience than v2.1 but a clear pull from the "no SaaS" crowd.

---

## v2.3 — Deferred but on the table

- **`WebDAVSyncProvider`** — Nextcloud, ownCloud, Box, Apache modwebdav. Same `SyncProvider` shape as S3.
- **Optional client-side encryption** for S3 contents (passphrase-derived key in Keychain; files encrypted before upload).
- **Presence indicators** — *"Bob has this file open."* Smallest possible implementation: a heartbeat file per user (`~/.mindle-presence/<user-uuid>.json`) updated every 15s with the active file path. Cloud-drive sync (or the SyncProvider) propagates it; Mindle aggregates and shows. Still nowhere near live cursors, but enough to know who's looking. **Punted from v2.1 because it's a meaningful new surface and we want to ship v2.1's foundation first.**

---

## Out of scope for v2.x (kept on roadmap, deferred)

- **WYSIWYG editing — decided not to ship.** The diff *is* the editor. Reverse decision only if the AI-output category collapses.
- **Real-time multi-user collaboration (CRDT / live cursors / OT).** v2.1+v2.2 deliver multi-user via file-based sync and the diff surface; live editing would mean a sync server, breaking the "no network calls" line on the README. Reverse decision only if file-based collaboration hits a wall users care about.
- iOS/iPadOS port
- Homebrew cask
- Presentation mode
- On-device AI Q&A (Apple Intelligence integration)

---

## Risks worth tracking

1. **File-watch races during agent saves.** Agent writes in chunks, fsync'd or not. Mitigation: debounce + size-stability check (no reload until file size stable for ~200ms).
2. **Diff library tradeoff.** Bench diff-match-patch vs. jsdiff with realistic prose docs before vendoring. Quality of word-level alignment matters for readability.
3. **MCP transport.** Stdio shim → Unix socket → running app is the cleanest macOS pattern but ties MCP to a running Mindle instance. Need a clear, friendly error when no Mindle is open ("Mindle isn't running — open it from Spotlight or Dock and try again").
4. **Skill harness adoption.** Claude Code is the obvious first target. Cursor, Continue, Cline, etc. each have their own skill-loading conventions. Ship the canonical file; document install paths for each harness as we get user feedback.
5. **AI-wave durability.** The viewer market existed pre-AI (Marked 2 had a decade); the diff-review surface is independently useful; the floor is real even if AI tooling shifts shape.
6. **User confusion if pivoting back.** Once positioned as "the AI-collaboration reader," adding a real editor later gets pushback. Stay disciplined — if editing comes, ship it as a deliberate Phase 3 with separate framing.

---

## Launch shape for v2.0

- **60-second demo video, no narration.** Open file → annotate → ask Claude → diff lands → accept some / reject some → annotations close.
- **Blog post on the loop.** Posted to r/ClaudeCode, r/macapps, r/Markdown.
- **Landing-page tagline rewrite.** *"AI writes. You read, you mark up. The agent reads your notes back."*
- **Reach out to @agasthik.** Closed two issues already (#1 auto-update, #3 tabs); the natural first user.
- **Submit `mindle-collaboration` skill** wherever there's a public skills index.

---

## Smallest viable first step

Ship the v1.5 foundation features, starting with **file-watch + live reload** since it's the prerequisite for v1.6. Each feature in v1.5 is independent — pick whichever lands cleanest day-to-day.

After v1.5, the path to v2.0 is mechanical: snapshot model + diff engine + diff render → accept/reject UI → MCP plumbing + skill → polish + launch.
