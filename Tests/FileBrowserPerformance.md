# File browser performance and issue #36 verification

## Automated red/green evidence

The focused harness was wired before the implementation files existed. Against the `origin/main` shape, `./run-tests.sh` failed with:

```text
error: error opening input file 'Sources/mindle/FileTree.swift'
error: error opening input file 'Sources/mindle/FileBrowserState.swift'
error: error opening input file 'Sources/mindle/GitFileMetadata.swift'
error: error opening input file 'Sources/mindle/PerformanceTrace.swift'
```

After implementation, the focused suites pass. The row/state checks specifically verify:

- URL-derived row IDs remain stable across flattening, collapse, expansion, and refresh.
- changing the selected tab/file does not mutate or republish the rows array;
- collapsed directory state survives selection changes and an equal tree refresh;
- an equal refresh does not publish a replacement row collection;
- stale tree and Git metadata generations cannot overwrite the latest root;
- cancelled generations cannot publish rows;
- repeated batched Git collection completes without process-pipe hangs.

These checks cover the state/identity conditions intended to prevent the LazyVStack regression, but they do not prove SwiftUI preserves the live scroll offset. The manual checklist below remains required.

## Benchmarks

Command:

```bash
scripts/profile-file-browser.sh 1000 5 5
```

Environment: macOS 26.6.1 (25G76), Apple M5 Max, optimized Swift (`swiftc -O`). The deterministic fixture contained 1,000 tracked Markdown documents, 10 modified documents, 10 untracked documents, one text file, hidden content, and an unsupported-only directory. It flattened to 1,231 visible rows. Values are five measured runs from the command above.

| Metric | Before median | After median | Before runs | After runs |
|---|---:|---:|---|---|
| Main-thread refresh work | 26.482 ms | 0.025 ms | 33.547, 26.079, 32.038, 25.748, 26.482 | 0.140, 0.025, 0.022, 0.019, 0.026 |
| Tree scan to published rows | 26.482 ms | 28.729 ms | 33.547, 26.079, 32.038, 25.748, 26.482 | 28.729, 30.352, 28.501, 28.757, 27.496 |
| Initial 320×600 row render | 78.648 ms | 31.835 ms | 121.621, 78.155, 78.648, 79.159, 78.296 | 33.323, 30.179, 32.333, 31.535, 31.835 |
| Initially realized row bodies | 1,231 rows | 28 rows | 1231, 1231, 1231, 1231, 1231 | 28, 28, 28, 28, 28 |
| Git changes + last-edited, 5 files | 723.214 ms | 45.178 ms | 723.214, 723.633, 724.241, 723.171, 721.502 | 71.250, 47.595, 43.534, 45.178, 44.312 |

The Git baseline deliberately invokes `diff` and `log` per file: 10 processes per run versus 3 batched processes. Larger per-file samples were attempted but exceeded the five-minute command bound, so they were discarded rather than reported. The final sample keeps the full 1,000-document tree and bounds only the intentionally slow per-file Git comparison.

Interpretation:

- total tree work is similar, but it no longer blocks the main actor;
- lazy realization reduced initial row bodies by 97.7% and median render time by 59.5%;
- even at five files, batched Git metadata was 16.0× faster; the process-count gap grows linearly with file count.

## Manual issue #36 checklist

Fixture setup:

```bash
rm -rf .build/issue-36-fixture
scripts/generate-file-browser-fixture.sh 1000 .build/issue-36-fixture
open -n -a "$PWD/build/Mindle.app" \
  "$PWD/.build/issue-36-fixture/section-19/chapter-09/document-0999.md"
```

Checklist:

1. Open the file sidebar and expand enough directories to place `document-0999.md` well below the first viewport.
2. Open at least four files that sort above the active file as tabs.
3. Scroll until the active row is near the vertical center; note the rows immediately above and below it and the scrollbar thumb position.
4. Close inactive tabs above the active selection one at a time.
5. Verify the same neighboring rows and scrollbar position remain visually stable and the active row remains visible.
6. Repeat while crossing the two-tabs-to-one-tab boundary, which removes the tab bar.
7. Repeat after collapsing and re-expanding a directory above the active row.
8. Repeat with keyboard `⌘W` and with tab close buttons.

### Manual status

Not manually verified. The final built app was launched against the 1,000-document fixture and remained running after four additional file-open events were sent. The accessibility probe needed to operate the sidebar failed before interaction:

```text
Not authorized to send Apple events to System Events. (-1743)
```

Because the sidebar could not be scrolled or its tab close controls driven, no claim is made about visual scroll stability. Run the checklist above in an interactive macOS session with Accessibility/Automation permission before merging.

## LazyVStack fallback if #36 is unstable

`FileBrowserRowStack` is the adapter seam. If the checklist reveals movement:

1. add an internal `FileBrowserRowRealizationPolicy` with `.lazy` and `.eagerStable`;
2. keep the flat `FileTreeRowModel`, external collapse state, Equatable rows, background scanning, batched Git work, and generation guards unchanged;
3. switch only the adapter from `LazyVStack` to `VStack` for `.eagerStable`;
4. preserve a debug/UserDefaults override long enough to compare both modes on affected systems;
5. if eager fallback is too costly for very large trees, replace the adapter with an AppKit `NSCollectionView` wrapper that virtualizes rows while explicitly restoring `NSScrollView.contentView.bounds.origin` after selection/tab updates.

The first fallback is intentionally narrow and low-risk. The AppKit adapter is the longer-term option if SwiftUI lazy layout cannot provide stable scroll identity on macOS 14.
