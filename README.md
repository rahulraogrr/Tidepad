# Tidepad

Current milestone: dedicated native Find / Replace / Find in Files, indexed Go to Line, and a collapsible results pane. See [the search milestone report](Documentation/SearchMilestone.md) for architecture, tests, measured Debug/Release timings, file inventory and limitations. Large-document typing/undo still have measurable stalls; this is not yet the 100 MB–1 GB storage engine.

Native macOS 14+ text editor using SwiftUI for the workspace and AppKit NSTextView for editing. The existing document, file-operation, tab, and editor-session architecture is preserved. Open `Tidepad.xcodeproj` and run the shared Tidepad scheme.

## Build and launch

```sh
xcodebuild -project Tidepad.xcodeproj -scheme Tidepad -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
open build/DerivedData/Build/Products/Debug/Tidepad.app
```

Built with Xcode 27.0 (27A266a), for arm64 and x86_64 with a macOS 14 deployment target. Latest visual-pass build log: `build/visual-build.log`. This is a local unsigned development build, not a notarized distribution. The original command-line Swift fallback in `build/Tidepad.app` is an older build; use the DerivedData app above.

## Editor behavior

- Consolas when installed, otherwise Menlo, then system monospace. The reusable `EditorFontConfiguration` defaults to 12 pt and four-space tabs; sessions accept a configuration.
- A 31-point flat toolbar with 15-point icons, 26-point rectangular tab strip, 36-point minimum gutter, thin separators, and 21-point segmented status bar retain the compact Notepad++-inspired layout. The selected tab meets the editor without a bottom border; dirty tabs show an amber document icon and dot. Inactive tabs have a separate background, the active tab uses an amber top edge, and the compact + button stays at the far right.
- The shared palette uses a #202020 dark editor, #191919 gutter, and #D4D4D4 text; light mode uses a white editor and #F0F0F0 gutter. Text starts 6 pt after the gutter. A subtle full-width caret-line background and matching bracket outlines work in light and dark appearances. Native caret, selection, undo, clipboard, and find remain in NSTextView.
- Gutter typography follows the actual editor font. Right-aligned numbers redraw on clip-view scrolling and edits, with a subtle grey background and separator.
- Status shows file type, UTF-16 length, logical lines, cursor line/column, selected Unicode character count, encoding, line endings, and INS. Columns count Unicode characters, with a tab counting as one. Overwrite mode is not implemented.
- Cmd+N/O/S/Shift+S/W create, open, save, save as, and close tabs. Cmd+F opens the dedicated Tidepad search panel. Opening accepts any extension. Dirty tab/window/quit flows offer Save, Cancel, and Don’t Save.

## Architecture and syntax

The existing `EditorDocument`, `DocumentManager`, `TextFileService`, SwiftUI views, and per-document `EditorSession` remain responsible for their original concerns.

`CodeTextView` adds background drawing only. `BracketMatcher` is a separate Foundation-only UTF-16 scanner for nested `()`, `[]`, and `{}`. It checks the bracket before the caret, then the one after it, with a 20,000-unit scan limit. It does not interpret strings or comments.

The new `Syntax/` layer is independent of documents and NSTextView:

- `SyntaxLanguage` detects Swift, Java, JSON, XML, SQL, JavaScript, TypeScript, HTML, CSS, YAML, and Markdown from extensions and defines token kinds and policy.
- `LineLexer` recognizes keywords, quoted strings, numbers, comments, literals, punctuation, markup names, and Markdown headings/code where applicable. It carries block-comment, multiline-string, markup, and fenced-code state between lines.
- `IncrementalSyntaxEngine` caches line text, tokens, and incoming/outgoing lexer state. It reuses unchanged prefixes and suffixes once state converges. It handles line insertions/deletions and multiline-state changes. Snapshot line splitting/comparison is still linear in document size and runs off the main actor.
- `SyntaxPalette` supplies distinct light/dark token colors.

`Editor/SyntaxHighlighter` adapts these results to AppKit. It debounces edits by 90 ms, tokenizes snapshots in a background task, cancels superseded work, and rejects stale revisions. Only the visible area plus a small vertical margin receives temporary foreground attributes, capped at 80,000 UTF-16 units per paint. Stable colors remain during typing until the new result arrives. Coloring never changes saved text, creates undo actions, or moves selection. Storage delegate callbacks only record invalidation; attributes are applied after TextKit has processed the edit.

The injectable `SyntaxPolicy` can disable coloring and defaults to skipping documents above 1,000,000 UTF-16 units. This is a defensive coloring limit, not large-file optimization. Changing a filename/extension through Save As updates language detection and coloring without replacing the editor session.

## Validation

```sh
Tests/run-checks.sh
```

The standalone checks compile against the selected Xcode SDK. The native AppKit suite requires a logged-in macOS GUI session; it creates offscreen windows and does not modify user files. Log: `build/milestone-checks.log`.

- Core: Unicode and CR/LF/CRLF offsets, dirty-state restoration, UTF-8/UTF-16 round trips.
- Syntax: all 11 language profiles, cache reuse, multiline invalidation, inserted-line offsets, extension detection, and nested/mismatched/bounded bracket matching.
- Native integration: opens the checked-in `.txt`, `.java`, `.json`, and `.swift` fixtures through DocumentManager, edits them through NSTextView, verifies live selection/cursor metrics, temporary colors, clean undo, redo, and saved-file round trips.
- Scroll checks: 250-line document, line 200 gutter alignment, newly visible syntax, bulk line deletion, and unwrapped horizontal scrolling.
- Policy: text remains editable and uncolored above the configured syntax limit.
- Rendered editor snapshots: `build/editor-checks/editor-light.png`, `editor-dark.png`, and `editor-scrolled.png`.

The four fixture checks and native render checks are automated AppKit integration tests, not a claim of exhaustive manual menu/dialog testing. Prior v0.1 checks covered native find and tab switching.

## Files changed in this milestone

Modified:

- `Tidepad/Editor/AppKitTextView.swift`
- `Tidepad/Editor/EditorSession.swift`
- `Tidepad/Editor/LineNumberRulerView.swift`
- `Tidepad/Models/EditorDocument.swift`
- `Tidepad/Utilities/EditorFontProvider.swift`
- `Tidepad/Views/DocumentTabView.swift`
- `Tidepad/Views/EditorToolbar.swift`
- `Tidepad/Views/EditorView.swift`
- `Tidepad/Views/WorkspaceView.swift`
- `Tidepad.xcodeproj/project.pbxproj`
- `README.md`

Added:

- `Tidepad/Editor/BracketMatcher.swift`
- `Tidepad/Editor/CodeTextView.swift`
- `Tidepad/Editor/SyntaxHighlighter.swift`
- `Tidepad/Syntax/SyntaxLanguage.swift`
- `Tidepad/Syntax/LineLexer.swift`
- `Tidepad/Syntax/IncrementalSyntaxEngine.swift`
- `Tidepad/Syntax/SyntaxPalette.swift`
- `Tests/SyntaxChecks.swift`
- `Tests/EditorChecks.swift`
- `Tests/run-checks.sh`
- `Tests/Fixtures/sample.txt`, `Sample.java`, `sample.json`, `Sample.swift`

## Remaining limits

This is lexical coloring, not a complete language parser: embedded script/style languages, interpolation, regular-expression literals, and complex Markdown/YAML grammar are not fully parsed. Bracket matching can include brackets inside strings/comments and intentionally stops at its scan limit.

Whole document strings and saved snapshots remain in memory. The existing line index is rebuilt on edits and file I/O is synchronous. The app is not yet suitable for 100 MB–1 GB files. No Tree-sitter, plugin system, file comparison, split editor, or large-file storage changes have been added.

Overwrite mode, session restoration, external-file-change detection, encoding conversion UI, and line-ending conversion UI remain unimplemented. Existing newline sequences are retained; newly typed returns use native LF, so editing CRLF files can produce mixed endings (status detects CRLF first). Validation ran on the installed macOS/Xcode, not a macOS 14 runtime.


## Visual fidelity pass — September 2026

This pass changes presentation without replacing editor/document architecture or adding editor features.

Shared `TidepadMetrics` centralizes workspace dimensions, fonts, padding, separators, and gutter sizing. `TidepadTheme` provides dynamic light/dark colors consumed by SwiftUI and AppKit. `CompactChrome` supplies square hover/pressed button surfaces and thin separators. The left status section expands; length/lines, Ln/Col, Sel, line endings, encoding, and INS have separate compact segments.

UI files modified: `Views/WorkspaceView.swift`, `DocumentTabView.swift`, `EditorToolbar.swift`, `StatusBarView.swift`; `Editor/EditorSession.swift`, `CodeTextView.swift`, `LineNumberRulerView.swift`; and `Utilities/EditorFontProvider.swift`.

Added `Utilities/TidepadMetrics.swift`, `Utilities/TidepadTheme.swift`, and `Views/CompactChrome.swift`. The Xcode project registers these files. `App/TidepadApp.swift` contains an opt-in Debug-only visual-QA hook backed by `Tests/VisualCapture.swift`. Normal launches do not activate it; Release compiles it out.

External window screenshots were unavailable on this host. The actual freshly built Debug process rendered its own live window content for inspection, recording its bundle path, PID, and selected font. This verified **Menlo-Regular at 12 pt** (Consolas was unavailable). Captures are in `build/visual-review/workspace-light.png` and `workspace-dark.png`; process details are in `runtime.txt`. The capture excludes native title-bar controls, which remain macOS-managed. The app restores its original appearance after capture.

To reproduce the live visual capture from the repository directory:

```sh
open -n --env TIDEPAD_VISUAL_CAPTURE="$PWD/build/visual-review" --env TIDEPAD_VISUAL_FIXTURES="$PWD/Tests/Fixtures" "$PWD/build/DerivedData/Build/Products/Debug/Tidepad.app"
```

`TIDEPAD_VISUAL_FIXTURES` optionally opens only the checked-in JSON and Swift samples in that new instance for tab and editor review. No system appearance setting is changed. The new Debug app is at `build/DerivedData/Build/Products/Debug/Tidepad.app`.

## Native menu milestone

The editor layout and toolbar/tab/status-bar dimensions are unchanged. Native menus now appear in this order:

**Tidepad → File → Edit → Search → View → Encoding → Language → Settings → Tools → Window → Help**

`Commands/` uses SwiftUI `Commands`, `CommandMenu`, and `CommandGroup`. `WorkspaceCommandContext` routes actions to the selected document and its existing editor session. Reactive menu-content views track document and preference changes. `NativeMenuCoordinator` arranges the generated native menus while retaining the standard application and Window commands; it does not draw menu popups.

Functional commands include New/Open/Save/Save As, Save All, tab/group closing with existing unsaved-change protection, Recent Files, native editing, Find/Next/Previous/Replace, zoom, toolbar/status/gutter visibility, word wrap, full screen, per-document language overrides, System/Light/Dark appearance, native editor font selection, and tab widths 2/4/8. Preferences and display choices apply to this app session. Language overrides remain attached to their open documents, including across Save As, until reset with Use File Extension.

Cmd+H opens native Replace; Hide Tidepad moves to Ctrl+Cmd+H. Cmd+, opens the Preferences placeholder (macOS may label this item Settings…). Find in Files and Go to Line also show explanatory placeholders. Help and Keyboard Shortcuts display reference dialogs. Advanced line editing, Find All, C/C++, formatting, case conversion, sorting, duplicate removal, and encoding conversion remain disabled. Encoding checkmarks are informational; existing UTF-8/UTF-16 BOMs are detected and preserved on save.

Added:

- `Tidepad/Commands/TidepadCommands.swift`, `WorkspaceCommandContext.swift`, `NativeMenuCoordinator.swift`
- `Tidepad/Commands/FileCommands.swift`, `EditCommands.swift`, `SearchCommands.swift`, `ViewCommands.swift`
- `Tidepad/Commands/EncodingCommands.swift`, `LanguageCommands.swift`, `SettingsCommands.swift`, `ToolsCommands.swift`
- `Tidepad/Models/EditorPreferences.swift`
- `Tests/MenuValidation.swift`

Modified:

- `Tidepad/App/TidepadApp.swift`
- `Tidepad/Models/EditorDocument.swift`
- `Tidepad/Documents/DocumentManager.swift`, `TextFileService.swift`
- `Tidepad/Editor/EditorSession.swift`, `AppKitTextView.swift`
- `Tidepad/Utilities/EditorFontProvider.swift`
- `Tidepad/Views/WorkspaceView.swift`, `EditorView.swift`
- `Tidepad.xcodeproj/project.pbxproj`
- `Tests/CoreChecks.swift`, `EditorChecks.swift`, and `README.md`

Build log: `build/menu-build.log`. Regression log: `build/menu-regressions.log`. The regression suite covers BOM round trips, language overrides, Save All/group closes, wrapping and font/tab/gutter settings in addition to the existing four-file editor tests.

The opt-in Debug menu harness exercises the actual running app's NSMenu actions and keyboard equivalents, inspects native Open/Preferences dialogs, checks Find/Replace controls, and verifies language/view checkmarks. It does not run on normal launches and is compiled out of Release. To reproduce (creates a separate test instance and test files under the specified output directory):

```sh
open -n --env TIDEPAD_MENU_VALIDATE="$PWD/build/menu-validation" "$PWD/build/DerivedData/Build/Products/Debug/Tidepad.app"
```

The report and native menu inventories are written inside that directory. This is automated native-app integration validation, not exhaustive manual UI testing.
