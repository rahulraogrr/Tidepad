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
- Editor engine (2026-09-27): hybrid. Files open in `NSTextView` (Apple's full text system) unless
  they're too large or have too-long lines, in which case they open in a large-file view built on Core
  Text over the piece-table storage (`Tidepad/Storage`). The mode is chosen once when the file opens
  (file size from the file system; line lengths from the open scan) and changes only on reopen.
  Measured on a 500 MB file (`Tests/run-large-file-prototype.sh`): the storage opens in ~0.15 s and edits
  in microseconds, but TextKit 1 (`NSLayoutManager`) used 2.9 GB and ~112 ms per keystroke, and TextKit 2
  (`NSTextLayoutManager`, including `relocateViewport(to:)`) took 48–58 s and 5–7 GB to jump or undo,
  because both lay out everything up to a location. A single Core Text view for all files was
  considered and rejected: normal files would lose `NSTextView`'s input methods, bidirectional text,
  accessibility and more until rebuilt. Both modes share one engine (storage, `TextCommands`, search,
  lexer) so features aren't written twice; the large-file view uses Apple APIs for what it takes over
  (Core Text, `NSTextInputClient`, `NSUndoManager`, `NSPasteboard`, `NSAccessibility`).
- Terminal panel (2026-09-28): the shell runs on a pseudo-terminal created with `forkpty` from macOS's
  C library, not Foundation's `Process`, because `Process` can't give the shell a controlling
  terminal, which job control, Ctrl-C and full-screen programs need; Terminal.app works the same way.
  There is no Apple terminal view, so the screen is Tidepad's own xterm-compatible emulator
  (`TerminalScreen`, Foundation only) drawn with Core Text; input uses `NSTextInputClient`.
