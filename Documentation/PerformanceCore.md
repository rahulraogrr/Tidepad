# Editor performance core — September 2026

This milestone keeps SwiftUI, AppKit, NSTextView, TextKit 1 and native UndoManager. It adds no editor features or external dependencies. The compact interface and search architecture remain intact.

## Findings and methodology

Measurements use this MacBook Air (Apple Silicon, 16 GiB), macOS 27 and Xcode 27, deployment target macOS 14. Release (`swiftc -O` and Xcode Release) is authoritative. Fixtures are generated and deleted by the test programs. Numbers are observations, not guarantees or statistically sampled percentiles. AppKit operation timings include synchronous work; they do not purport to measure end-to-end display latency. The editor harness explicitly reports a first-layout run-loop settling interval, which includes a deliberate 150 ms minimum. Already-open tab measurements reuse existing sessions.

Before changing the editor architecture, the old sources were preserved under `build/performance-baseline/Tidepad`, and the existing native edit path was timed. At 10 MB, one baseline edit spent approximately 146 ms detecting line endings and 136 ms rebuilding line offsets, within a 284 ms operation. At 50 MB the corresponding components were 671 ms and 618 ms, within 1,296 ms. These preliminary samples had different system load from the final comparison table below.

Apple Time Profiler captured a real 50 MB run in `build/editor-performance.trace`; the exported stacks and summary are alongside it. Approximately 7,894 samples included CodeTextView background drawing and 6,031 included line-fragment lookup. Approximately 3,706 included cursor metrics during native undo, with 3,529 in Swift String distance. Stacks overlap; counts must not be added. This identified two additional fixes: avoid laying out an offscreen caret for a cosmetic decoration, and count complete selected lines from cached character totals. The trace was taken during development before these two fixes, not presented as the final performance result. No Allocations instrument claim is made; memory numbers use current process RSS.

## Reference investigation and independent design

The official [Notepad++ repository](https://github.com/notepad-plus-plus/notepad-plus-plus) separates the application in PowerEditor from its editor and lexers. [PowerEditor source layout](https://github.com/notepad-plus-plus/notepad-plus-plus/tree/master/PowerEditor/src) is the application lifecycle reference; Tidepad retains its existing document/session separation.

The [Scintilla design overview](https://www.scintilla.org/Design.html) describes separate buffer, document, and editor responsibilities, line positions, and grouped insert/delete undo actions. The useful principle is to deliver edit ranges to derived state instead of rebuilding it from complete text. Tidepad independently applies NSTextStorage edit notifications to its line index and keeps AppKit's undo engine.

[Scintilla's documented interface](https://www.scintilla.org/ScintillaDoc.html) provides savepoints, position queries, margins, decoration ranges and background loading boundaries. Tidepad uses generation savepoints, an NSRulerView, temporary attributes and immutable background results. Coordinates remain UTF-16 to match AppKit, rather than adopting Scintilla's byte positions or a custom cell buffer.

[Lexilla](https://www.scintilla.org/LexillaDoc.html) reinforces the separation of lexical analysis from presentation. Tidepad preserves its independent Swift lexer/cache and AppKit painting adapter. No source code, implementation translations, comments, artwork or third-party dependencies were imported.

## Text ownership and savepoints

NSTextStorage is authoritative while a session is alive. EditorDocument exposes a lazy, revision-invalidated immutable String snapshot for Save and Search. There is no per-keystroke assignment of NSTextView.string to an observed document String. Loading text and its prepared index are relinquished by the document after session attachment.

Dirty state is a stored Boolean computed from integer editing-state/savepoint tokens. The monotonically increasing revision still rejects stale search results, including after undo. Tiny reciprocal state-token actions are grouped with native UndoManager text operations; text itself is still managed exclusively by AppKit undo. Saving breaks native typing coalescing at the savepoint. Tests cover undo to clean, redo to dirty, saving between edits, and that undo changes actual text rather than consuming a standalone token action.

A document without a live session retains the existing explicit String assignment behavior, including content-based clean detection. Its initial/saved values can share Swift copy-on-write storage. That compatibility path is not used by native keystrokes. The saved String is discarded on session attachment.

Remaining document-sized representations:

- Native text/attribute storage and TextKit glyph/layout caches are unavoidable in the current editor.
- A lazy immutable search/save snapshot can share storage initially, then require a copy when text changes. A running worker retains its own snapshot until cancellation/completion.
- Enabled syntax analysis takes a debounced immutable snapshot, with a previous/new line cache during analysis. It never takes snapshots on every keystroke.
- Native undo retains deleted/replaced text. Full-document replacement and undo can retain multiple document-sized buffers.
- Decoding uses Data plus String, and index preparation temporarily uses UTF-16 units. These are transient loading allocations, not live mirrored editor text.
- Search replacement planning intentionally creates replacement text; bulk commit uses one storage transaction and one undo group.

## Line indexing and metrics

Before: a value-type `[Int]` index rebuilt by converting the whole document to UTF-16 for every edit; the ruler retained a copy-on-write view of the array.

After: a shared reference index with compact UTF-16 starts, per-line ending kinds, and cumulative Unicode-character counts. Each storage edit reparses affected complete lines plus adjacent boundaries, handling CR/LF joins/splits, Unicode separators and the final empty line. Only the subsequent numeric offsets/counts shift. CR and CRLF counters make line-ending status constant-time. Sharing the index with the ruler avoids a forced array copy on every mutation.

An ordinary edit costs **O(affected line text + subsequent line count)**, not O(total text). This is deliberately still an offset array, not a logarithmic tree. Binary caret lookup is O(log lines); line-to-offset is O(1). Character counts for complete interior lines are cached; selection and column work only scans boundary fragments. Single enormous lines remain a worst case. A future block/tree index should be justified by the offset-shift measurements, not introduced speculatively.

Length comes from NSTextStorage.length. Dirty state, line-ending status, and line count are cached. Selection changes do not invoke syntax analysis. Decorations read the storage's NSString view and have a 20,000-code-unit bracket scan budget independent of file size. Current-line and bracket drawing is restricted to the viewport to avoid distant layout work.

## Syntax and large-file policy

The standalone Release lexer matrix measures full and incremental cache updates at 100 KB, 1 MB and 10 MB. Existing line-token reuse, cancellation, stale-result rejection, 90 ms debounce and visible-range temporary attributes remain. The lexer still enumerates all lines in its background update even when tokenizing only changed lines; it is not a fully incremental large-file parser.

`EditorPerformanceMode` makes the policy explicit:

| Tier | UTF-16 length | Behavior |
|---|---:|---|
| Normal | ≤1,000,000 | Existing asynchronous syntax enabled, subject to SyntaxPolicy |
| Medium | >1,000,000 and <10,000,000 | Syntax disabled; native editing, undo and bounded decorations retained |
| Large | ≥10,000,000 | Same conservative analysis limits; explicit boundary for future large-file work |

The 1 MB analysis ceiling is retained because measured full analysis is around 0.1 seconds in a worker, while 10 MB exceeds a second and introduces a large cache/snapshot cost. Medium/large currently share reductions; the distinction is a policy foundation, not an unimplemented UI toggle. No undo depth limit or editing restriction was introduced.

## Loading and native layout

NSOpenPanel, recent-file opening and application open events now perform file reading, decoding and index preparation in a detached task. AppKit storage population and UI mutation remain on the main actor. Search-result activation reuses the same loaded value and retains its existing stale-file checks. Duplicate URLs are checked again at publication.

The service uses a Data read, BOM-aware UTF decoding, and Foundation's legacy encoding detection fallback. UTF-8/16/32 BOMs are preserved. Normal Data, FileHandle and mappedIfSafe are benchmarked independently. Mapping is not enabled by default: these local warm reads show that decoding/index work matters more than the small read difference; mapped input would still need lifetime/change-safety decisions. Streaming/incremental decoding is future work, not claimed as implemented.

TextKit 1 uses noncontiguous layout with background layout disabled. This avoids leaving a whole-document layout obligation for the first keystroke. A contiguous prototype can appear cheap at first viewport layout but then spends seconds in the first edit. Noncontiguous layout has its own native invalidation costs, which are included in the measured operation times.

Bulk replacement validates/registers native undo once, brackets a single NSTextStorage mutation with begin/endEditing, groups undo, and publishes one coherent index/metric/syntax refresh. Full replacement still necessarily rebuilds the affected index and copies replacement/undo text. This is not thousands of individual Replace operations.

## TextKit comparison scope

`NativeCoreBench` constructs explicit TextKit 1 and TextKit 2 stacks in separate processes at 1, 10 and 50 MB. It measures population, first viewport layout, ASCII/Unicode/newline/deletion, selection, scrolling, undo/redo and current RSS. TextKit 2 is checked to remain active (no accidental layoutManager fallback). It is an isolated native prototype, not a production migration.

The production ruler uses TextKit 1 glyph APIs and syntax uses temporary attributes. Equivalent TextKit 2 ruler geometry and rendering attributes were not implemented in the prototype; those remain migration work and a regression risk. The prototype emitted Apple's `NSTextLayoutManagerBreakOnNilContentManager` diagnostic around undo, so it is not asserted to be a production-quality TextKit 2 configuration. The measurements do not prove TextKit 2 can never be fast. They do provide no basis for migrating this application now. **Recommendation: retain TextKit 1.**

## SwiftUI observation

EditorDocument uses property-granular Observation. UI reads lightweight filename/dirty state, metrics or language properties rather than live text. WorkspaceView observes document membership/selection and layout preferences; the toolbar observes selected-document availability. StatusBarView alone reads caret metrics. Search views read their own controller/results. Sessions are retained across tab switches, and search progress cannot construct another NSTextStorage.

Opt-in Debug body counters (`TIDEPAD_OBSERVATION_AUDIT`) and an automated caret/selection/edit/savepoint sequence record actual view reevaluations. These counters are no-ops in Release. Subsystem timing is opt-in with `TIDEPAD_PROFILE`; it never logs document contents.

## Reproduction

```sh
bash Tests/run-checks.sh
bash Tests/run-search-checks.sh
bash Tests/run-performance-core.sh
xcodebuild -project Tidepad.xcodeproj -scheme Tidepad -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Tidepad.xcodeproj -scheme Tidepad -configuration Release -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
open build/DerivedData/Build/Products/Debug/Tidepad.app
```

`run-performance-core.sh` runs benchmark processes serially. The TextKit 2 50 MB case is intentionally slow. Fixtures are temporary. Logs and traces stay in build/, not in source fixtures.

## Launch and observation results

The launch driver starts the exact Release executable and times from process creation until the editor has been created and the window's layout/display pass has run. It asserts the editor is editable and records the bundle path. Observed first launch was **708.6 ms**; subsequent launches were **264.9 ms** and **324.9 ms**. This is a first-observed versus warm comparison, **not a controlled cold filesystem-cache measurement**. No cache purge or reboot was performed for the benchmark, so a true cold-cache number remains unmeasured.

The real Debug app's body counters reported:

| Action | Reevaluated views |
|---|---|
| Caret movement | StatusBarView once |
| Selection change | StatusBarView once |
| Typing in an already-dirty document | StatusBarView once |
| Saving/renaming at a savepoint | StatusBarView and DocumentTabView once each |

Workspace, toolbar and search views did not reevaluate for the caret/selection actions. Existing session identity is retained; these are measured observations, not merely an inference from the source architecture.


## Final Release comparison

All values below are milliseconds, **before → after**, using the same current fixture/operation harness against the preserved original sources and final sources. Fixtures are ordinary short-line logs. Single trials can vary with OS scheduling and thermal state. First typing includes cold native edit/undo setup; background-file typing is a subsequent edit while a Find in Files worker runs.

| Operation | 100 KB | 1 MB | 10 MB | 50 MB |
|---|---:|---:|---:|---:|
| Read/decode/document/index preparation | 5.603 → 0.628 | 46.121 → 4.908 | 515.466 → 72.746 | 2301.514 → 284.678 |
| Session creation | 45.651 → 37.306 | 14.935 → 2.813 | 129.366 → 8.016 | 581.896 → 24.023 |
| First layout + ≥150 ms settling | 150.441 → 150.777 | 167.551 → 152.570 | 1660.350 → 220.617 | 7513.600 → 229.007 |
| First ASCII edit | 12.909 → 21.576 | 24.813 → 12.181 | 260.087 → 69.013 | 1224.365 → 73.820 |
| Subsequent ASCII edit + file search | 8.485 → 12.820 | 26.944 → 6.185 | 284.330 → 17.993 | 1363.314 → 21.300 |
| Unicode insertion | 36.512 → 26.288 | 32.109 → 7.716 | 269.878 → 17.129 | 1277.167 → 54.258 |
| Newline | 6.140 → 3.200 | 25.850 → 2.146 | 259.425 → 7.517 | 1260.331 → 22.154 |
| Delete | 5.971 → 5.593 | 35.224 → 6.616 | 258.511 → 7.648 | 1224.187 → 11.345 |
| Backspace | 8.092 → 9.887 | 31.677 → 11.750 | 241.581 → 18.264 | 1209.318 → 47.400 |
| Small paste | 8.229 → 5.037 | 30.631 → 2.994 | 256.125 → 6.321 | 1360.556 → 22.004 |
| ~100 KB paste | 35.241 → 18.957 | 68.105 → 19.863 | 279.560 → 29.650 | 1390.352 → 111.141 |
| Undo edit group | 24.326 → 16.424 | 166.920 → 27.624 | 1411.391 → 53.600 | 7346.671 → 111.808 |
| Redo edit group | 46.514 → 23.803 | 272.636 → 43.693 | 1422.265 → 88.879 | 7068.392 → 213.463 |
| 100 caret moves | 6.286 → 5.491 | 4.137 → 4.438 | 4.591 → 4.198 | 4.324 → 4.514 |
| 50-character selection | 0.077 → 0.068 | 0.052 → 0.050 | 0.055 → 0.049 | 0.052 → 0.059 |
| Select All | 20.547 → 0.160 | 186.220 → 0.762 | 956.469 → 5.112 | 4785.711 → 32.670 |
| 20 viewport scrolls | 2.152 → 1.855 | 1.444 → 1.688 | 1.560 → 1.494 | 1.481 → 1.597 |
| Switch tabs and back | 3.602 → 3.192 | 2.057 → 2.304 | 2.221 → 2.187 | 2.171 → 2.413 |
| Search snapshot | 0.000 → 0.002 | 0.001 → 0.008 | 0.001 → 0.004 | 0.001 → 0.006 |
| Sparse replacement planning | 1.152 → 1.173 | 6.162 → 9.457 | 52.550 → 62.241 | 266.489 → 338.054 |
| Replace All commit | 2.513 → 3.425 | 4.567 → 26.828 | 24.234 → 188.174 | 138.556 → 989.183 |
| Replace All undo | 27.264 → 6.357 | 151.960 → 25.334 | 1197.580 → 131.818 | 5997.618 → 692.283 |

Opening has changed responsibilities: the after column includes prepared indexing; baseline indexing happened during session creation. Compare the sum as well as each stage. Native layout/drawing, Foundation bridging and undo remain outside the tiny custom incremental-index callback. The table does not claim that all first keystrokes meet a 16.7 ms frame budget.

**Regression retained and disclosed:** the 50 MB bulk commit is slower than baseline. Its profile attributes about 750 ms to `NSTextView.shouldChangeText`, which registers native replacement undo; storage mutation itself is about 0.53 ms, end-editing about 54 ms, and final custom refresh about 0.33 ms in that sampled run. A full-index rebuild on restoring 50 MB still costs about 485 ms. Native undo semantics were retained instead of replacing them with an unproven custom implementation.

The sparse bulk benchmark replaces each group of ten full log lines with a short replacement. It is a whole-range transformation and native undo workload, not the same query as the dedicated Search benchmark. This keeps planned matches below the existing 100,000 replacement limit. An initial dense 50 MB trial hit that existing safety limit; the corrected workload was rerun for all sizes.

## Decoder and index alternatives

| Size | Data read | UTF-8 decode | FileHandle read | mappedIfSafe read | Mapped UTF-8 decode | Full prepared index | Incremental offset index | Legacy line-ending scan |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 MB | 0.191 | 0.167 | 0.148 | 0.125 | 0.126 | 9.876 | 0.053 | 55.047 |
| 10 MB | 0.901 | 0.383 | 1.153 | 0.168 | 1.006 | 51.340 | 0.252 | 484.587 |
| 50 MB | 5.609 | 4.116 | 6.410 | 0.331 | 5.726 | 257.601 | 1.465 | 2422.390 |

These compare complete index rebuild against the chosen offset-shift update. A tree was not implemented: the measured numeric suffix shift is small compared with native editing/layout. Character-count indexing adds approximately 8 bytes per line beyond the original offset array; ending kinds add approximately one byte per line. Long-line reparsing and O(lines) shifting remain explicit limitations.

## Isolated TextKit results

Milliseconds except memory. “RSS max observed” is the largest sampled current RSS in that one process, not an allocation attribution. These are isolated NSTextView operations without the production lexer/ruler and therefore must not be substituted for the application benchmark above.

| Stack | MB | Populate | First viewport | ASCII | Unicode | Newline | Delete | Scroll ×20 | Undo | Redo | RSS max observed MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| TK1 contiguous | 1 | 14.11 | 7.72 | 272.71 | 220.91 | 214.97 | 214.58 | 1.22 | 1.42 | 0.52 | 93.5 |
| TK1 contiguous | 10 | 17.58 | 7.66 | 2642.30 | 2145.72 | 2128.81 | 2128.95 | 1.22 | 1.72 | 0.51 | 195.3 |
| TK1 contiguous | 50 | 19.18 | 7.69 | 13302.93 | 10842.62 | 10739.13 | 10755.01 | 1.25 | 3.82 | 0.57 | 597.2 |
| TK1 noncontiguous | 1 | 14.72 | 6.86 | 13.48 | 1.63 | 7.22 | 1.96 | 1.11 | 8.21 | 7.24 | 87.1 |
| TK1 noncontiguous | 10 | 17.51 | 8.16 | 19.94 | 8.37 | 8.96 | 2.98 | 1.10 | 17.85 | 16.20 | 125.1 |
| TK1 noncontiguous | 50 | 39.97 | 12.91 | 47.59 | 38.08 | 13.45 | 7.69 | 1.10 | 59.91 | 57.99 | 293.6 |
| TK2 | 1 | 13.78 | 395.82 | 109.36 | 100.63 | 119.67 | 120.54 | 103.39 | 265.61 | 262.12 | 275.7 |
| TK2 | 10 | 12.24 | 4118.60 | 1291.38 | 1305.28 | 1484.83 | 1495.38 | 905.57 | 3458.63 | 3483.92 | 1980.8 |
| TK2 | 50 | 17.74 | 21440.92 | 6555.27 | 6586.32 | 7628.18 | 7793.63 | 3964.17 | 19965.59 | 20237.03 | 4552.4 |

TK2 stayed active, but its costly viewport updates and undo diagnostics make the prototype unsuitable for adoption. In particular, its 50 MB memory use is unacceptable. This is evidence about this prototype and OS build, not a universal comparison of every possible TextKit 2 implementation.

## Independent memory measurements

Actual Release Tidepad processes, each starting empty and opening only its own dynamically generated Swift fixture. RSS includes shared frameworks and allocator caches. MiB = 1,048,576 bytes.

| Document | Empty app MiB | Populated app MiB | Increment MiB | Open-to-publication observation | Largest main-actor heartbeat gap |
|---|---:|---:|---:|---:|---:|
| 1 MB | 135.7 | 165.9 | 30.2 | 102.1 ms | 95.0 ms |
| 10 MB | 135.7 | 204.2 | 68.5 | 162.4 ms | 76.2 ms |
| 50 MB | 135.8 | 447.7 | 311.9 | 391.0 ms | 111.8 ms |

The open observation polls every 100 ms and is not an exact storage-population stopwatch. Heartbeat gaps include native storage/layout/UI publication: moving I/O off the main actor removes decoding stalls but does not make the complete open operation nonblocking. A roughly 112 ms observed gap at 50 MB remains.

Separate editor-only processes isolate snapshots and undo from the SwiftUI application baseline:

| Stage (MiB RSS) | 1 MB | 10 MB | 50 MB |
|---|---:|---:|---:|
| empty editor | 80.3 | 80.2 | 80.3 |
| decoded document + prepared index | 85.4 | 129.1 | 334.7 |
| live editor + first layout | 92.2 | 144.9 | 393.9 |
| syntax settled | 96.3 | 149.0 | 398.0 |
| immutable search snapshot | 96.3 | 149.0 | 398.0 |
| edit while snapshot retained | 100.8 | 153.6 | 402.7 |
| snapshot released | 100.8 | 153.6 | 402.7 |
| select all cached metrics | 104.8 | 192.7 | 598.1 |
| bulk undo retained | 111.1 | 216.6 | 700.1 |
| undo released | 111.5 | 216.6 | 700.1 |

RSS staying high after releasing undo/snapshots is not proof those objects remain alive: allocators may retain pages. Snapshot creation often has no immediate RSS increase because Foundation/Swift share backing storage; an edit can force detachment. The model no longer eagerly retains a second live text and saved text snapshot.

Estimated payload costs, excluding object/allocator overhead: UTF-16 storage can require 2 bytes per code unit; index arrays use about 17 bytes per logical line; syntax retains line Strings and token arrays only in normal mode; a full replacement undo record can require another complete old-text representation. Exact ownership costs cannot be inferred by subtracting overlapping RSS samples. The measurements do not establish a 100 MB or 1 GB memory guarantee.

## Search regression matrix

Final Release checks retained the existing engine. Previous milestone numbers are from Documentation/SearchMilestone.md; these are separate runs, so tiny sub-millisecond differences are noise.

| Operation at 10 MB | Previous milestone ms | Final ms |
|---|---:|---:|
| next | 0.003 | 0.003 |
| previous | 0.001 | 0.001 |
| findAll | 36.473 | 34.582 |
| regexPrevious | 133.530 | 130.952 |
| regexAll | 134.712 | 131.257 |
| replaceAll | 61.474 | 59.318 |
| files | 313.220 | 301.650 |
| Cancellation | 0.126 | 0.134 |

The dedicated search logs also cover 100 KB and 1 MB in both Debug and Release. No meaningful search regression was observed. Native result activation now carries prepared loaded text/indexes through the existing asynchronous path; search matching/planning algorithms were not rewritten.

## Syntax cache measurements

The isolated cache probe estimates retained payload (line records, line text bytes, token records and offsets), excluding allocator headers, bridging overhead, and transient previous/new caches:

| Input | Full analysis ms | Incremental update ms | Cache payload estimate MiB |
|---|---:|---:|---:|
| 100,000 bytes | 25.108 | 2.524 | 0.54 |
| 1,000,000 bytes | 121.098 | 12.449 | 5.44 |
| 10,000,000 bytes | 1056.634 | 126.645 | 54.43 |

The 10 MB case is an isolated analysis experiment: production syntax is disabled at that size. The results support retaining the conservative 1 MB ceiling rather than enabling expensive large-file caches. Snapshot and cache payload estimates are not additional independently measured RSS allocations because they may share backing storage.

## Validation and build results

- Core checks passed, including 2,000 incremental edit comparisons against a rebuilt index, Unicode character totals, CR/LF/CRLF boundaries, language overrides, dirty state, UTF-8/16/32 BOM preservation, and native BOM-less encoding detection compatibility.
- Native editor checks passed on `.txt`, `.java`, `.json`, `.swift`: opening, editing, saving, undo/redo to savepoints, selection/caret metrics, line numbers, scrolling, font/tab settings, wrapping, language changes and bracket/syntax behavior. Light/dark editor captures were inspected.
- Save All, Close Other Tabs, Close All, Go to Line bounds, and grouped replacement/undo checks passed.
- Search Debug and Release suites passed: normal/extended/regex, captures, zero-width matches, Unicode offsets, result building, history, recursive file search, limits and cancellation.
- Actual Debug application integration checks passed for native menu structure, all required singleton system commands, menu checkmarks, disabled placeholders, full screen, New/Open/Save/Close shortcuts, Find/Replace panels, scoped Replace All, stale results/replacements, result navigation and file activation.
- Save As was additionally checked through the actual native panel using Accessibility UI automation: a new disposable tab was saved to `build/performance-save-as-manual.txt`, exact bytes verified, filename/clean state observed, and the tab closed without prompting. The programmatic panel-dismissal adapter was not reliable for this operation, so the native UI check is the validation evidence.
- **Debug: BUILD SUCCEEDED. Release: BUILD SUCCEEDED.** No compiler, concurrency or actor-isolation warnings remained. Xcode emits its non-actionable “AppIntents metadata extraction skipped” warning because this application has no AppIntents dependency.
- The latest Debug application was launched with `open -n` at the exact path below; the running executable path was checked. There was no fallback to `build/Tidepad.app`.

```text
/Users/rahulraogonda/codex/Tidepad/build/DerivedData/Build/Products/Debug/Tidepad.app
```

A repeat warm launch sequence on the final functional build measured 326.6, 281.3 and 267.2 ms. The earlier 708.6 ms first-observed launch remains distinct from these cached runs; neither is represented as a controlled cold-cache experiment.

## Remaining limitations and next recommendations

This is a performance-core improvement, not completion of every responsiveness target:

- The final 10 MB first ASCII edit was **69.0 ms**, above the 16.7 ms ideal. A subsequent edit during file search was **18.0 ms**. The 50 MB first edit was **73.8 ms**, and the subsequent edit **21.3 ms**. Native editing/layout remains material after removing the custom full-text scans.
- The 100 KB first edit regressed from **12.9 to 21.6 ms** in this single-trial harness. The native layout tradeoff is not a universal improvement at every size.
- A 50 MB Replace All commit was **989 ms**, worse than the baseline 139 ms. Its undo improved from **5,998 to 692 ms**. Bulk operations can still visibly pause the main actor; the report does not label them instantaneous.
- Line-index shifting remains O(lines after the edit). Long logical lines still require reparsing/counting boundary fragments, so minified or pathological single-line files are not covered by the short-line results.
- File decoding and index preparation are asynchronous, but NSTextStorage population and native UI publication are still main-thread work. An observed 50 MB heartbeat gap of about 112 ms remains.
- Save is still synchronous and creates encoded Data. Search, regex and bulk replacement still use immutable whole-document snapshots/replacement buffers. Find in Files retains its existing 64 MiB per-file and 100,000-result limits.
- Full-document undo, selection/layout and allocator caches can retain substantial memory. The actual app's 50 MB RSS increase is about 312 MiB. This does not establish low-memory 100 MB or 1 GB support.
- Syntax is disabled beyond the measured ceiling. Tree-sitter, plugins, split views, file comparison, custom rendering and chunked document storage were not added.
- TextKit 2 line-number/rendering-attribute parity remains unimplemented; prototype performance and undo diagnostics provide no compelling migration case.
- 100 MB was not tested. True cold-cache startup, large-file percentile latency, allocation ownership, and adversarial long-line behavior require additional measurements.

**Future 100 MB work:** keep the current native editor while testing long lines, Unicode-heavy logs, first-input tail latency and UI publication. Profile native undo registration and memory with Allocations. Compare a blocked or balanced line index when numeric suffix shifts become meaningful. Reduce transient loading/index buffers, and investigate incremental decoding and snapshot lifetimes. Preserve responsiveness and native semantics before raising search or syntax limits.

**Future 500 MB–1 GB work:** prototype paged or chunked text storage, a balanced line/byte/UTF-16 mapping index, bounded snapshots, disk-aware undo limits and streaming search/save. Test whether custom NSTextStorage can prevent NSTextView from materializing full strings or full layout. If measurements show that native text-system assumptions defeat paging, evaluate a focused AppKit/Core Text viewport renderer. Do not infer that a rope alone, a newer TextKit version, or this milestone makes the current full-buffer editor a 1 GB editor.

## Files changed

- [Tidepad/App/TidepadApp.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/App/TidepadApp.swift)
- [Tidepad/Commands/FileCommands.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Commands/FileCommands.swift)
- [Tidepad/Documents/DocumentManager.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Documents/DocumentManager.swift)
- [Tidepad/Documents/TextFileService.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Documents/TextFileService.swift)
- [Tidepad/Editor/CodeTextView.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Editor/CodeTextView.swift)
- [Tidepad/Editor/EditorSession.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Editor/EditorSession.swift)
- [Tidepad/Editor/LineIndex.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Editor/LineIndex.swift)
- [Tidepad/Editor/LineNumberRulerView.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Editor/LineNumberRulerView.swift)
- [Tidepad/Editor/SyntaxHighlighter.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Editor/SyntaxHighlighter.swift)
- [Tidepad/Models/EditorDocument.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Models/EditorDocument.swift)
- [Tidepad/Search/SearchController.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Search/SearchController.swift)
- [Tidepad/Search/SearchPanelView.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Search/SearchPanelView.swift)
- [Tidepad/Search/SearchResultsView.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Search/SearchResultsView.swift)
- [Tidepad/Syntax/SyntaxLanguage.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Syntax/SyntaxLanguage.swift)
- [Tidepad/Views/DocumentTabView.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Views/DocumentTabView.swift)
- [Tidepad/Views/EditorToolbar.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Views/EditorToolbar.swift)
- [Tidepad/Views/StatusBarView.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Views/StatusBarView.swift)
- [Tidepad/Views/WorkspaceView.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Views/WorkspaceView.swift)
- [Tidepad.xcodeproj/project.pbxproj](/Users/rahulraogonda/codex/Tidepad/Tidepad.xcodeproj/project.pbxproj)
- [Tests/CoreChecks.swift](/Users/rahulraogonda/codex/Tidepad/Tests/CoreChecks.swift)
- [Tests/EditorChecks.swift](/Users/rahulraogonda/codex/Tidepad/Tests/EditorChecks.swift)
- [Tests/EditorPerformance.swift](/Users/rahulraogonda/codex/Tidepad/Tests/EditorPerformance.swift)

## Files added

- [Tidepad/Utilities/EditorDiagnostics.swift](/Users/rahulraogonda/codex/Tidepad/Tidepad/Utilities/EditorDiagnostics.swift)
- [Tests/AppPerformanceValidation.swift](/Users/rahulraogonda/codex/Tidepad/Tests/AppPerformanceValidation.swift)
- [Tests/NativeCoreBench.swift](/Users/rahulraogonda/codex/Tidepad/Tests/NativeCoreBench.swift)
- [Tests/MemoryPerformance.swift](/Users/rahulraogonda/codex/Tidepad/Tests/MemoryPerformance.swift)
- [Tests/SyntaxPerformance.swift](/Users/rahulraogonda/codex/Tidepad/Tests/SyntaxPerformance.swift)
- [Tests/run-performance-core.sh](/Users/rahulraogonda/codex/Tidepad/Tests/run-performance-core.sh)
- [Tests/run-app-performance.py](/Users/rahulraogonda/codex/Tidepad/Tests/run-app-performance.py)
- [Tests/run-app-regressions.py](/Users/rahulraogonda/codex/Tidepad/Tests/run-app-regressions.py)
- [Documentation/PerformanceCore.md](/Users/rahulraogonda/codex/Tidepad/Documentation/PerformanceCore.md)

Raw benchmark, build, UI validation, snapshot and profile artifacts are under `build/`. No generated multi-megabyte fixture files were added to source control.
