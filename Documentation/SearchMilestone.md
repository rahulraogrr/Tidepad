# Tidepad search milestone

The Find / Replace / Find in Files functionality is implemented and validated. The application remains SwiftUI + AppKit NSTextView/TextKit 1, targeting macOS 14. The existing workspace dimensions, gutter, theme, syntax layer, document manager and editor-session ownership are preserved. No web UI, plugins, Tree-sitter, TextKit migration, memory mapping or large-file storage rewrite was introduced.

**Performance qualification:** search-engine timings are good on these fixtures, but the current editor does not meet an “instantaneous editing/no visible stalls” standard at 10 MB. Typing, native bulk commits and undo remain material main-thread costs. This report does not label the entire application production-proven or universally ultra-fast.

## Files added

- `Tidepad/Search/SearchQuery.swift`: query/options/modes, provider contract, snapshots, matches, results, session history, timing helper.
- `Tidepad/Search/SearchEngine.swift`: reusable compiled queries, literal/regex enumeration/navigation and replacement plans.
- `Tidepad/Search/SearchResultBuilder.swift`: bounded previews and incremental Unicode columns.
- `Tidepad/Search/FindInFilesService.swift`: bounded recursive worker and conservative decoder.
- `Tidepad/Search/SearchController.swift`: actor-safe operation lifecycle and editor integration.
- `Tidepad/Search/SearchPanelView.swift`: compact Find/Replace/Files controls and Go to Line.
- `Tidepad/Search/SearchResultsView.swift`: collapsible results pane and recycled native table rows.
- `Tests/SearchChecks.swift`, `Tests/run-search-checks.sh`.
- `Tests/EditorPerformance.swift`, `Tests/run-editor-performance.sh`.
- `Tests/SearchValidation.swift`: opt-in Debug integration checks and live view captures.
- `Documentation/SearchMilestone.md`: this report.

## Files modified

- `Tidepad/App/TidepadApp.swift`: Debug validation hook.
- `Tidepad/Commands/WorkspaceCommandContext.swift`: shared search controller and action routing.
- `Tidepad/Commands/SearchCommands.swift`: real Find in Files/Find All/Go to Line actions.
- `Tidepad/Commands/TidepadCommands.swift`: updated Help/shortcut descriptions.
- `Tidepad/Documents/DocumentManager.swift`: accept a document decoded in a background worker.
- `Tidepad/Editor/EditorSession.swift`: range navigation, indexed Go to Line, native bulk-edit transaction.
- `Tidepad/Models/EditorDocument.swift`: monotonically increasing edit revision.
- `Tidepad/Views/WorkspaceView.swift`, `EditorToolbar.swift`: results-pane placement and Find action.
- `Tidepad.xcodeproj/project.pbxproj`: source registration.
- `Tests/EditorChecks.swift`, `Tests/MenuValidation.swift`: extended regressions and updated panel expectations.
- `README.md`.

## Architecture and operation behavior

`SearchTextSource` is a traversal contract. Its current `SearchSnapshot` backend uses an immutable String value and UTF-16 coordinates. A future chunked provider can implement navigation and enumeration without promising a whole-document String. The current replacement planner and Foundation regex backend still require a contiguous snapshot; a future storage engine will need another backend and edit-transaction adapter.

The main-actor controller captures the document String value (copy-on-write; no second SwiftUI text mirror), revision, identity and relevant selection. Detached workers do navigation/scans/transforms; AppKit is touched only on the main actor. Generation tokens, revision/selection checks, query-change cancellation and file metadata checks reject stale work. File-result activation reads/decodes off-thread, then creates/reuses the existing editor session on the main actor.

Literal Find Next uses NSString range search and stops at the first relevant occurrence; backward literal search uses `.backwards`. No match array is built. Regex forward navigation stops enumeration on its first usable match. Regex previous scans the relevant prefix and retains only the last match; it is measurably slower, not constant-time. Zero-width results are excluded on repeated navigation to avoid getting stuck.

The actor-owned cache compiles NSRegularExpression once for the current query/options combination. Whole-word boundaries use Unicode letter/number/mark/underscore classes. Capture replacements use Foundation `$1`, `$2`, etc. Extended mode decodes `\n`, `\r`, `\t`, `\0`, and `\\`. Invalid expressions disable search actions and show a validation message. Regex semantics are Foundation/ICU semantics; use inline flags such as `(?m)` when needed.

Replace current, Replace + Find, Replace All and Replace All in Selection prepare a replacement plan off-thread. The main thread validates the original revision/selection, calls `shouldChangeText` exactly once, edits NSTextStorage in an editing transaction, calls `didChangeText`, and uses NSUndoManager grouping. The complete replacement becomes one logical Undo. Temporary syntax colors are not converted into stored attributes. Bulk edits avoid `insertText`'s forced scroll/layout to the end of a large replacement. Selection-scoped replacement retains the adjusted selection; global replacement keeps the caret near its previous offset. Undo/redo are native AppKit operations.

Find All builds at most 100,000 rows off-thread and publishes one bounded result set. Count streams all matches without storing rows. Results include document/file identity, range, revision/metadata, line, grapheme-based column and a bounded preview. Result activation selects and scrolls the exact UTF-16 range. Stale results are rejected. Current-match feedback uses native selection and `showFindIndicator`; it does not change text, dirty state, undo history or syntax coloring.

The results pane uses NSTableView with reusable visible rows, not one SwiftUI view per match. Its observable state is separate from the editor/workspace state. Folder results are delivered in batches between files (256 accumulated rows or about 100 ms), with awaited main-actor publication for backpressure. A single dense file is accumulated before its batch is published; scans inside that file remain cancellable. Table reload requests only visible row views.

Find in Files uses one serial detached utility worker: recursive enumeration, one file buffer at a time, no Task per file. Semicolon-separated globs support `*`, `?`, and `*.*` (including extensionless files). Symlink files and package descendants are skipped. Progress is an indeterminate native Foundation Progress/NSProgress with a completed-file count; cancellation is checked during traversal and match enumeration and propagated to the worker. Local cancellation measurements appear below; a blocking filesystem read or an expensive ICU operation can delay cancellation.

Binary screening examines the initial 8 KB for NULs and unexpected control bytes. UTF-8 (optional BOM) and BOM-marked UTF-16 LE/BE are supported. Unsupported encodings, unreadable/binary files, and files above 64 MiB are skipped and counted. UTF-32 is deliberately skipped in folder search. Reads and results are bounded; those are defensive limits, not a large-file implementation.

Go to Line uses the existing EditorSession LineIndex, including a final empty line. Non-numeric/out-of-range values remain in the dialog with an error. Search/replace/directory/filter histories are unique, most-recent-first, capped at 20 and kept only in memory.

Native APIs used: NSPanel, NSHostingView/SwiftUI native controls, NSOpenPanel, NSTextView/NSTextStorage/NSLayoutManager, NSUndoManager, NSRegularExpression, NSString/NSRange, FileHandle/FileManager, NSProgress, native NSMenu commands and Swift Concurrency. No replacement find engine from another framework was added.

## Instrumentation and benchmark method

`SearchTiming` uses ContinuousClock in Debug; its storage, clock reads and logging compile out in Release. It covers navigation, Find All, replacement planning/commit, folder search, publication and table updates. Test harnesses explicitly time operations in both configurations. Xcode 27.0 (27A266a), Apple Swift 6.4, arm64 macOS 27 were used. Compatibility is built for macOS 14, but this was not tested on a macOS 14 runtime.

Fixtures are generated at runtime: 99,944, 999,936 and 9,999,980 UTF-8 bytes, source/log-style lines. Tables report individual measured runs, not statistically robust p95s or guarantees. Sub-millisecond navigation measurements are noisy. Find All timings here are range enumeration, not full UI presentation; folder timings include result construction but not a visible table. Replace All plan timings exclude the native editor commit; separate commit timings follow.

| Fixture | Operation | Debug ms | Release ms |
|---|---|---:|---:|
| 100 KB | Find Next | 0.022 | 0.072 |
| 100 KB | Find Previous | 0.007 | 0.001 |
| 100 KB | Find All ranges | 0.403 | 0.365 |
| 100 KB | Regex previous | 1.705 | 1.360 |
| 100 KB | Regex Find All ranges | 1.650 | 1.333 |
| 100 KB | Replace All plan | 0.762 | 0.690 |
| 100 KB | Find in Files + result construction | 4.999 | 3.224 |
| 1 MB | Find Next | 0.009 | 0.001 |
| 1 MB | Find Previous | 0.003 | 0.001 |
| 1 MB | Find All ranges | 3.952 | 3.537 |
| 1 MB | Regex previous | 16.615 | 13.241 |
| 1 MB | Regex Find All ranges | 16.020 | 13.329 |
| 1 MB | Replace All plan | 7.690 | 5.901 |
| 1 MB | Find in Files + result construction | 55.259 | 30.321 |
| 10 MB | Find Next | 0.030 | 0.003 |
| 10 MB | Find Previous | 0.004 | 0.001 |
| 10 MB | Find All ranges | 45.279 | 36.473 |
| 10 MB | Regex previous | 156.600 | 133.530 |
| 10 MB | Regex Find All ranges | 159.970 | 134.712 |
| 10 MB | Replace All plan | 72.827 | 61.474 |
| 10 MB | Find in Files + result construction | 340.228 | 313.220 |

Cancellation from request to worker completion measured **0.153 ms Debug / 0.126 ms Release** on the generated local fixtures. These are not bounds for network filesystems or pathological regexes.

Editor profiling used the current AppKit editor path with `-Onone` and `-O`, in a separate native harness. It compares idle editing to editing during a continuous folder-search worker. It is not a historical pre-change baseline or full desktop frame-latency trace.

| Release editor operation | 100 KB | 1 MB | 10 MB |
|---|---:|---:|---:|
| File read/decode ms | 5.373 | 52.938 | 753.269 |
| Session creation ms | 63.666 | 17.806 | 221.698 |
| Typing, idle ms | 8.667 | 26.933 | 309.444 |
| Typing, background search ms | 4.288 | 29.420 | 275.813 |
| Native Replace All commit ms | 15.322 | 72.994 | 410.795 |
| Native Undo ms | 24.483 | 335.232 | 1454.276 |

In the 10 MB Release test, 100 cursor moves took 5.503 ms idle / 4.818 ms with search; selection took 0.066 / 0.220 ms; 20 programmatic viewport scrolls took 1.763 / 1.680 ms; a pair of existing-tab switches took 5.935 / 2.320 ms. These are harness call times, not compositor frame times. The Debug 10 MB typing times were 729.467 / 786.739 ms, commit 790.926 ms, Undo 2061.512 ms. Full logs contain every fixture/operation.

The initial Debug folder-result builder took about 6.1 seconds on 10 MB. Replacing per-character line scanning with Foundation line-boundary calls reduced that substantially. A later column cache prevents repeated prefix counting on a long single line. The initial native Release bulk commit was about 2.1 seconds; avoiding forced end-of-document layout reduced the measured commit to about 0.41 seconds. These are exploratory before/after measurements, not isolated laboratory benchmarks.

`/usr/bin/time -l` measured peak resident sets of **365,461,504 bytes Debug** and **371,621,888 bytes Release** for the entire editor benchmark process. This includes AppKit, multiple fixture sessions, text snapshots and native undo storage. It is not incremental search memory. No cold-launch timing was captured; no near-instant-launch or complete no-regression claim is made.

## Validation

All search unit tests pass in Debug and Release: forward/backward/wrap/no-match, case/whole-word, five Extended escapes, invalid regex/escape, capture replacement, selection scope, zero-width matches, emoji/surrogates/composed text, line/column/preview, long Unicode lines, history limits, recursion/globs, unreadable/binary skipping, UTF-8 BOM/UTF-16 LE/BE, 100,000-result cap and cancellation.

The existing regression suite passes: four text/Java/JSON/Swift fixtures, edits/save/dirty state, native undo/redo, cursor metrics, syntax/cache/language behavior, bracket matching, BOM round trips, save/group-close actions, scrolled gutter alignment, line deletion, wrapping/font/tab settings and gutter visibility. Added native tests exercise length-changing replacement undo/redo and first/middle/last/invalid Go to Line inputs.

The opt-in running-app search integration run passed panel/menu actions, navigation, Replace + Find, Replace All/selection/undo/redo, invalid regex, Find All activation, stale results/replacements, Go to Line, recursive folder results and opening/selecting an external result. The existing menu harness passed top-level order, checkmarks, standard command uniqueness and native full-screen entry/exit. Shifted bindings are checked by menu attributes/actions in the synthetic harness; they were also tested directly through Computer Use.

Direct native UI checks verified Cmd+F, Cmd+H, Cmd+Shift+F, Cmd+G, Cmd+Shift+G, Cmd+L; Find Next/Previous; case-sensitive zero matches versus two case-insensitive whole-word matches; no-wrap exhaustion; Extended newline count; regex Find All; invalid-expression disabling; Replace/Replace All/native Cmd+Z; result navigation; invalid and final-line Go to Line; and native Save As. Wrap-around is covered by automated engine/integration navigation tests.

For a real 2,500-file folder search (~170 MB generated solely for QA), typing/pasting and scrolling worked while the visible file count advanced from 1,030 to 1,282. A later Cancel stopped a run at 1,350 files, visibly marked Cancelled. This checks usability during background search, not an assertion of zero frame stalls under every workload. Generated manual text was saved to `build/manual-ui.txt`.

Logs and captures:

- `build/search-build.log`, `build/search-release-build.log`
- `build/search-debug-benchmarks.log`, `build/search-release-benchmarks.log`
- `build/editor-debug-performance.log`, `build/editor-release-performance.log`
- `build/editor-debug-memory.log`, `build/editor-release-memory.log`
- `build/search-regressions.log`
- `build/search-validation7/results.txt` and panel/result PNG captures
- `build/search-menu-validation/results.txt`

## Build and launch

Both configurations succeeded. No compiler/concurrency warnings remain; Xcode reports only its non-actionable AppIntents metadata-skipped notice because the app does not use AppIntents.

```sh
cd /Users/rahulraogonda/codex/Tidepad
xcodebuild -project Tidepad.xcodeproj -scheme Tidepad -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Tidepad.xcodeproj -scheme Tidepad -configuration Release -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
open /Users/rahulraogonda/codex/Tidepad/build/DerivedData/Build/Products/Debug/Tidepad.app
```

The newly built DerivedData Debug app was launched and used for direct UI validation. Test reproduction:

```sh
Tests/run-checks.sh
Tests/run-search-checks.sh
Tests/run-editor-performance.sh
open -n --env TIDEPAD_SEARCH_VALIDATE="$PWD/build/search-validation" "$PWD/build/DerivedData/Build/Products/Debug/Tidepad.app"
open -n --env TIDEPAD_MENU_VALIDATE="$PWD/build/search-menu-validation" "$PWD/build/DerivedData/Build/Products/Debug/Tidepad.app"
```

The two app harnesses are opt-in Debug-only; normal launches do not run tests or open fixtures.

## Remaining limitations and future architecture concerns

- Whole-document editor Strings, saved snapshots, line-index rebuilds and native undo are still present. Typing/large bulk edits at 10 MB can visibly pause; the measured goal of universally instantaneous editing is **not met**. Before 100 MB–1 GB support, storage/indexing, decoding/opening and undo transaction strategy need measured work.
- Bulk preparation is off-thread, but NSTextStorage mutation and AppKit undo must happen on the main thread. A 10 MB undo remains roughly 1.45 seconds in the measured Release harness.
- Regex previous is a prefix scan. ICU regex performance is input-dependent; pathological expressions and blocking file reads can delay cancellation. No hard regex timeout is promised.
- Folder search supports UTF-8 and BOM-marked UTF-16, reads at most 64 MiB per file, and retains at most 100,000 result rows. Replace All also stops with an error above 100,000 replacements, without changing text. Count is not capped. Dense single-file results are published after that file's scan rather than during each match.
- File metadata/revision checks are conservative but do not replace NSFilePresenter/coordinated external-change handling. Files may still change after validation; future file coordination remains out of scope.
- Plain matching is literal (no canonical-equivalence normalization). Ranges always use UTF-16; displayed result columns count graphemes. Native selection and the find indicator provide current-match decoration; optional all-match highlighting is not implemented.
- Search history is session-only. Find in Files searches disk contents, not unsaved open buffers. Search operations that lose their revision/selection context are cancelled rather than applying potentially wrong ranges.
- No historical launch/frame-time baseline or macOS 14 runtime validation was performed. Passing tests and the limited idle/background comparisons do not establish that every possible regression has been excluded.
