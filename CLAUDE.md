# Tidepad — working rules

Tidepad is a native macOS text editor in the spirit of Notepad++. These rules apply to all code in this
repository, whoever (or whatever) writes it.

## Rule no. 1: 100% native Apple

- Use only Apple frameworks: Swift standard library, Foundation, AppKit, SwiftUI, Observation, Combine,
  Core Text / Core Graphics and other system frameworks.
- No third-party packages or dependencies, no web views, no cross-platform layers, no bundled engines.
- No faked behaviour: no drawing tricks that imitate a feature (e.g. double-drawing glyphs to fake bold),
  no private APIs, no emulation of something the framework already provides. Use the framework's own
  mechanism (e.g. the real bold face from `NSFontManager`).
- Prefer Apple's highest-level ready-made class for a job (e.g. `NSDocument`, `NSTextView`). Drop to
  Apple's lower-level APIs only when the high-level one can't meet a stated requirement (such as editing
  300–500 MB files), and record why under "Decisions" below.
- If something can't be done natively, stop and raise it. Don't work around it.

## Decisions

- Documents: Tidepad uses its own `DocumentManager` built on `NSFilePresenter` / `NSFileCoordinator`
  instead of `NSDocument`, because `NSDocument` reads, autosaves and versions whole files, which
  conflicts with editing 300–500 MB files. Revisit if the large-file engine makes that workable.
- Editor engine (2026-09-27): one Core Text-based editor view for all files, on the piece-table storage
  (`Tidepad/Storage`), replacing `NSTextView`. Measured on a 500 MB file (`Tests/run-large-file-prototype.sh`):
  the storage opens in ~0.15 s and edits in microseconds, but TextKit 1 (`NSLayoutManager`) used 2.9 GB
  and ~112 ms per keystroke, and TextKit 2 (`NSTextLayoutManager`, including
  `relocateViewport(to:)`) took 48–58 s and 5–7 GB to jump or undo, because both lay out everything up
  to a location. A hybrid (NSTextView for small files) was rejected to avoid two editor modes.
  The view uses Apple APIs for everything it takes over: Core Text for layout and drawing,
  `NSTextInputClient` for typing and input methods, `NSUndoManager`, `NSPasteboard`, and
  `NSAccessibility`.

## Priorities

- Near term: a polished everyday editor at Notepad++ parity.
- Long term: 100 MB–1 GB files. Don't build new features on the whole document as one `String`:
  text commands go through `TextCommands` / `TextSource` (range-based), not `document.text`.

## Editing behaviour

- Every command is one undo step with a meaningful action name.
- A command with nothing to do changes nothing (no dirty flag, no undo entry) and beeps.
- Preserve the document's encoding, BOM and line endings (including mixed endings) unless the user
  explicitly converts them.
- Syntax colouring and styling never change the saved text, dirty the document or register undo.

## Workflow

- New source files must be added to `Tidepad.xcodeproj/project.pbxproj` (file reference, group and
  Sources build phase).
- Add or extend checks for every change; Foundation-only logic gets a standalone check in
  `Tests/run-checks.sh`.
- Run `Tests/run-checks.sh` before committing. Keep commits small: one change per commit.
