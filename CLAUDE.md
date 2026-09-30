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
- Large-file spike (2026-09-30, `Tests/run-large-file-spike.sh`, 500 MB, 5.74 M lines, M1 Air):
  - TextKit 2 with our own `NSTextContentManager` over the piece table is ruled out: to relocate the
    viewport it enumerated every element from the start (5.74 M to the middle in 52 s and 7.2 GB,
    11.5 M to the end in 120 s and 21.9 GB), and its estimated height was unusable (1,892 pt).
  - Core Text: a whole screen (find, decode, build, draw 60 lines) at any line takes 1.25 ms median,
    1.52 ms worst, 11 MB. So the large-file view is our own Core Text view.
  - Line index on bytes, not UTF-16: memchr finds 5.74 M lines in 53 ms (UTF-16 through the piece
    table: 650 ms). Sparse, every 64th line start: 700 KB instead of 43 MB; any line in microseconds.
  - A mapped file that another app truncates crashes the reader with SIGBUS (proved with `mmap`).
    Mapping an APFS clone (`clonefile`, 0.14 ms for 500 MB, no extra space) survives. Map clones
    with `mmap` directly; Foundation's `.alwaysMapped` doesn't document when it copies instead.
    Volumes without cloning fall back to chunked reads.
  - An 850-million-point-tall scroll view stays sharp and evenly spaced, so no virtual scrolling.
- Large-file search (2026-09-30): regular expressions use `NSRegularExpression`, the same expression
  as the normal editor (`SearchEngine.expression`), over 4 MB chunks decoded to `NSString`, with a
  64 KB overlap and 4 KB of context on each side (`LargeTextSearch`). One `NSString` for the whole
  file was rejected: 500 MB of UTF-8 becomes ~1 GB of UTF-16 and a full decode before the first match.
  Limits: a match can't be longer than 64 KB, and look-arounds see 4 KB. Plain text stays a byte
  search: memchr for the pattern's rarest byte, then a compare, because macOS's memmem runs at
  ~1.3 GB/s while its memchr is vectorised; memmem only when the rarest byte is everywhere. ^ and $
  match at every line in both editors, as in Notepad++. Replace All goes in as pieces over the file
  (nothing rewritten), capped at 100,000 like the normal editor.
- Large-file colours (2026-09-30): the normal editor's `LineLexer` and `SyntaxPalette`, lexing only
  the lines drawn (`LargeSyntaxEngine`). Lexer states at every 256th line are worked out by a
  low-priority background pass from the top; until it reaches a line, its state is guessed from 200
  lines above, and the view redraws when the exact state arrives. Lexing the whole file up to the
  viewport first, as Scintilla does, was rejected: seconds of waiting on every jump in a 500 MB file.
  Bold is the font's real bold face (`NSFontManager`). Lines over 16 KB (drawn in slices) aren't coloured.
- Lexer speed (2026-09-30, `Tests/run-lexer-performance.sh`): `LineLexer` reads UTF-16 or UTF-8 through
  one generic implementation (everything it matches is ASCII), matches keywords in place from tables
  by length and first letter, keeps its state as a plain value, and skips lines where nothing can open
  a string, comment or tag when only following the state. The large-file pass lexes the mapped bytes
  where they lie (`LargeTextBuffer.forEachLine`). Measured, optimised build: tokens 19 → 148 MB/s,
  background pass 15 → 240 MB/s (500 MB in about 2 s). Debug builds run such code 25–50× slower, so
  judge speed in a Release build. Parallel lexing was not needed.
- Terminal panel (2026-09-28): the shell runs on a pseudo-terminal created with `forkpty` from macOS's
  C library, not Foundation's `Process`, because `Process` can't give the shell a controlling
  terminal, which job control, Ctrl-C and full-screen programs need; Terminal.app works the same way.
  There is no Apple terminal view, so the screen is Tidepad's own xterm-compatible emulator
  (`TerminalScreen`, Foundation only) drawn with Core Text; input uses `NSTextInputClient`. Because
  the view draws its own text, it describes itself to VoiceOver through `NSAccessibility` as a text
  area (`TerminalAccessibility.swift`), and has new output read with announcement notifications.
- Help (2026-09-28): Tidepad Help is an Apple Help Book (`Tidepad/Tidepad.help`) shown in macOS's
  Help Viewer, the system's own help mechanism, which also makes the Help menu's search field find it.
  When a feature, menu or shortcut changes, update its page and run `Scripts/build-help-index.sh`.
