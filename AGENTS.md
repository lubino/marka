# AGENTS.md — Developer guide for Marka

Read this before changing Marka. All code, comments, commit messages, and documentation on disk must remain in **English**. Chat with humans may be multilingual.

End users should read [`README.md`](./README.md).

---

## What Marka is

**Marka** is a native, lightweight Markdown editor for macOS. You edit like in Word, the file stays clean GitHub-Flavored Markdown, and the pages on screen match print and PDF (A4).

Hard product rules (from the original spec):

- Swift + AppKit (SwiftUI only if AppKit cannot do the job). TextKit 2 for layout — note the editor currently runs on AppKit's **TextKit 1 fallback** (`textLayoutManager == nil`) because `layoutManager` is touched; code that measures text must handle both (see `MarkdownTextView.inlineCodeBoxRects`).
- **No WebKit, Electron, or JavaScript.** No `WKWebView`.
- macOS 14+ (deployment target 14.0, so the compiler rejects newer APIs), Apple Silicon first, universal builds for releases. Liquid Glass only through runtime checks (`GlassChrome`); SF Symbols referenced by name must exist on macOS 14 or have a fallback (`DocumentWindowController.sonomaFallbackSymbols`).
- App bundle ≤ 8 MB. Typical 20-page document ≤ 60 MB RAM. Launch under 0.5 s.
- Minimum dependencies. v1 uses a range-accurate parser in `MarkaCore` so styling maps 1:1 onto UTF-16 ranges in the source. Do not add packages without a written reason.
- MIT license.
- **The `.md` file is the source of truth.** Saving must not rewrite lines the user did not edit. Unedited documents round-trip **byte-identically** (BOM and line endings included).
- What you see on the A4 pages is what PDF and print produce (one layout).

Out of scope: cloud sync, collaboration, plugins, Windows, Linux. Code syntax highlighting, LaTeX math and Mermaid diagrams were added on request — natively (rules 21 and 28), never via a web view.

---

## Critical toolchain constraint (no full Xcode)

Marka must compile and test with **macOS Command Line Tools** (`swift build` / `swift run`). Full `Xcode.app` is optional.

1. Do **not** use SwiftUI / Observation macros (`@State`, `@Observable`, `@Model`).
2. Do **not** import `XCTest` or Swift Testing macros (`@Test`, `#expect`).
   - Unit tests: `Tests/MarkaCoreTests/main.swift` → `swift run MarkaTests`.
   - UI tests: `Tests/MarkaUITests/main.swift` (off-screen AppKit, no XCTest) → `swift run MarkaUITests`.
3. `Package.swift` uses `swift-tools-version: 6.0`. Keep `MarkaCore` `Sendable` where it crosses isolation. AppKit types stay on the main actor.

---

## Project structure

```text
marka/
├── Package.swift                 # MarkaCore, MarkaUI, executable Marka, MarkaTests, MarkaUITests
├── VERSION                       # SemVer read by scripts/build-app.sh
├── install.sh                    # User installer (release zip or --from-source)
├── scripts/
│   ├── build-app.sh              # swift build + Info.plist + AppIcon + ad-hoc codesign
│   ├── install-local.sh          # build + install to /Applications and launch
│   ├── package-dmg.sh            # Universal DMG + ZIP + SHA256SUMS.txt
│   ├── publish-release.sh        # Local GitHub Release (DMG/ZIP/checksums)
│   ├── install-git-hooks.sh      # core.hooksPath → .githooks (tag push publishes)
│   └── generate-icon.swift       # Vector icon source → AppIcon.iconset, Resources/AppIcon.icon, preview
├── Resources/
│   └── AppIcon.icon/             # Icon Composer bundle (icon.json + SVG layers) → Liquid Glass Assets.car
├── Sources/
│   ├── MarkaCore/                # Foundation only — unit-tested
│   │   ├── PageGeometry.swift    # A4 points, exclusion-path pagination math
│   │   ├── EditorSettings.swift  # UserDefaults-backed settings
│   │   ├── FileCodec.swift       # UTF-8 BOM + LF/CRLF/CR identity encode
│   │   ├── DocumentStats.swift   # word/paragraph/heading/link/table/task counts for the info popover
│   │   ├── MarkdownSyntax.swift  # GFM-ish spans (content vs hidden markers)
│   │   ├── MarkdownEditing.swift # wrap, headings, lists, return/tab rules
│   │   ├── TableMutator.swift    # insert/delete GFM rows, columns, and whole tables
│   │   ├── SyntaxHighlighter.swift # dependency-free fenced-code lexer (UTF-16 token ranges)
│   │   ├── FindEngine.swift      # plain-text find / replace (case, whole words)
│   │   ├── MathParser.swift      # LaTeX math subset → MathNode tree (+ symbol tables)
│   │   ├── Mermaid.swift         # Mermaid flowchart / sequence / pie parsing + flowchart layout
│   │   └── ShellRunner.swift     # shell fences → Terminal .command files
│   ├── MarkaApp/                 # MarkaUI library (AppKit)
│       ├── MarkaRuntime.swift    # MarkaRuntime.start()
│       ├── Testing/
│       │   └── EditorWindowHarness.swift
│       ├── AppDelegate.swift     # menus + custom NSDocumentController
│       ├── Document/
│       │   ├── MarkdownDocument.swift        # NSDocument: identity save, print operation
│       │   ├── DocumentWindow.swift          # tab bar only with 2+ tabs
│       │   └── DocumentWindowController.swift # window, toolbar, sidebar, zoom, find, share, info
│       ├── Crash/
│       │   └── CrashReporter.swift # local ~/Library/Logs/Marka crash files
│       ├── Editor/
│       │   ├── MarkdownTextView.swift
│       │   └── StyleEngine.swift # attributes + Typora-style marker hiding
│       ├── Layout/
│       │   ├── PagedEditorView.swift  # A4 sheets, exclusions, page breaks, chrome
│       │   └── CenteringClipView.swift # zoom-out pages sit in the middle of the window
│       ├── Views/
│       │   ├── CodeBlockChromeView.swift  # GitHub-style fence fill + glass copy / run icons
│       │   ├── LinkCardView.swift         # Word-style hyperlink card (Open / Copy / Remove)
│       │   ├── PagesTableView.swift       # GitHub-style table grid, per-page slices
│       │   ├── CellMarkdown.swift         # inline Markdown in table cells (rendered / raw while editing)
│       │   ├── TableStylePickerView.swift # Pages-style insert-table gallery (presets)
│       │   ├── TableEditChrome.swift      # in-table drag grips + round +/− controls
│       │   ├── FindReplaceView.swift      # search & replace popover
│       │   ├── MathRenderer.swift         # TeX-style box layout on STIX Two Math
│       │   ├── MermaidRenderer.swift      # native Mermaid drawing
│       │   ├── ThumbnailSidebar.swift
│       │   ├── DocumentInfoView.swift      # toolbar page-number button + document info popover
│       │   ├── GlassChrome.swift            # Liquid Glass (NSGlassEffectView) + vibrant fallback
│       │   └── SettingsWindowController.swift
│       └── Export/
│           └── PDFExporter.swift # PDF + NSPrintOperation (same pages)
│   └── MarkaLauncher/            # @main executable
│       └── main.swift
└── Tests/
    ├── MarkaCoreTests/main.swift
    └── MarkaUITests/main.swift   # AppKit UI tests without XCTest
```

---

## Architecture invariants

1. **One source string.** `NSTextStorage.string` is the Markdown. Styles and hidden markers are display attributes only. Never replace the source with RTF, HTML, or attachments that drop syntax.
2. **Identity save.** `FileCodec.encode` returns the original `Data` when the normalized string is unchanged.
3. **A4 pagination.** One text container whose width is the content area. Inter-page gaps (bottom margin + grey gutter + top margin) are `NSTextContainer.exclusionPaths`. Forced breaks are `<!-- pagebreak -->` plus an extra hole to the bottom of the current page. The page count follows the **content** (`PagedEditorView.contentPageCount`): through the last non-whitespace character's line fragment (paragraph spacing included, so a table's overlay space counts) plus the caret's page while blank lines are typed at the end. It shrinks when content is removed, and trailing newlines never add an empty last page.
4. **WYSIWYG markers.** Markdown delimiters stay hidden in WYSIWYG (near-zero font, clear colour). Clicking must not reveal `*`, `_`, `` ` ``, or quotes, and must not restyle the whole document (that jumps layout). Source mode (`⌘/`) shows the raw Markdown.
5. **Images.** Drag/drop copies the file into `./assets/` next to the document and inserts `![alt](assets/…)`. Overlays draw the bitmap; the Markdown line stays in the file.
6. **Fenced code.** WYSIWYG keeps the source fences; padding is paragraph indent/spacing. A rounded GitHub-style fill is drawn *behind* the text view (clicks pass through). Small round **glass** icons (22 pt, SF Symbols, no border tile; `NSGlassEffectView` on macOS 26+, a translucent material on 14/15) hang off the block's top-right corner; only the icons take hits (`hitTest` uses superview coordinates), and the text view keeps the pointing hand over them (`MarkdownTextView.pointerHotspot`) because it would otherwise re-apply its I-beam on every mouse move. Copy writes the inner text with a single `setString`; block quotes get the same icon (copies without `>`). Shell fences (`sh` / `bash` / `zsh` / `shell` / `fish` / `ksh`) also get a Terminal icon that writes an executable `.command` file (`ShellRunner`) which `cd`s to the document directory and opens in Terminal.app. A block that crosses a page break is clipped to each page's content rect (`PageLayout.pageContentPieces`).
7. **Links.** WYSIWYG shows only the display text (blue, underlined, pointing hand), including `[`code`](url)`. Do **not** set `NSAttributedString.Key.link` on the glyphs — that steals clicks. Clicking a link puts the caret in the **label**; the Word-style card shows the address (Open / Copy / Remove) without taking first responder; ⌘K focuses the address field. ⌘-click and Open resolve via `Hyperlink.destination` (local paths percent-decoded, `<…>` unwrapped, resolved against the document folder): local `.md` files open as a new Marka **tab**; a missing `.md` target is created empty (missing folders too, never overwriting — `Hyperlink.createMarkdownFileIfMissing`); other files and `http(s)` / `mailto` open with the system.
8. **Inline formatting.** `**…**` / `*…*` may wrap links and inline code (`**[readme](README.md)**`, `**`Marka.dmg`**`, `*`Marka.dmg`*`): only the delimiters must be free in `MarkdownSyntax.parseInline`. Bold/italic are applied in a last pass that *adds a trait* to the existing font (monospaced bold, bold links). Inline code is a GitHub box: rounded (4 pt), `rgba(175,184,193,0.2)` / dark `rgba(110,118,129,0.4)`, 90 % code font; the hidden backticks carry the horizontal padding as kern, and `MarkdownTextView` draws the boxes (`.markaInlineCode`) behind the glyphs.
9. **Tables — display.** A table looks exactly like GitHub's: bold header, 1 px `#d0d7de` grid, even data rows striped `#f6f8fa`, starting at the content's left edge, and no permanent chrome (no column letters, row numbers, or +/− chips — `PagesTableView.hasOnlyGitHubGrid`). WYSIWYG collapses the GFM source (near-zero line height, clear glyphs) and paints the opaque table over that hole; the source is re-hidden in a **last** `StyleEngine` pass, because inline passes (code font, link blue, bold colour) would otherwise leak cell text around the table. Cells render their inline Markdown (`CellMarkdown`, `MarkdownCellField`: bold, italic, strike, code, links) and switch to the raw source while edited. A table that does not fit the rest of the page is split into one `TableSliceView` per page (`PageLayout.flowTableRows` + `tablePageSlices`) with the header repeated. Table spacing is folded into the bounded `relayout()` loop — never `queueRelayout()` from `refreshTables`. Source mode shows the raw pipes.
10. **Tables — editing.** Cells are edited in place and **WYSIWYG**: the field editor holds the cell's Markdown source with markers hidden and content styled (`CellMarkdown.styleSource`, restyled on every change; `allowsEditingTextAttributes`). Read the source from the field editor's string (`currentSource`, captured *before* `textDidEndEditing` calls super) — afterwards `stringValue` is the display value without the hidden markers. Selection follows **first-responder changes** (`MarkdownCellField.onFocus` → `cellDidFocus`), not `controlTextDidBeginEditing`, which only fires on the first keystroke; grips, the bar and Format → Table all use that selection. Tab / Return move between cells and add a row at the end; ↑ / ↓ move a row (header ↔ body, the delimiter row is skipped, never inserts) and ← / → cross into the neighbouring cell at the start / end of the text. **While the cursor is in a cell** two control clusters appear: in the left margin a blue row grip beside the row, a green **+** on the row's top and bottom edges (insert above / below) and a red **−** left of the grip (delete row); above the table a blue column grip over the column, a green **+** on its left and right edges (insert left / right) and a red **−** above the grip (delete column). Each **+** sits exactly where the new row or column appears (`TableCircleButton`). The header row shows only "+ below" (it never moves or goes away). Dragging a grip moves the row (header excluded) or column (alignment included) — `TableMutator.moveRow` / `moveColumn`, one undo step each, with a drop line while dragging. The chrome hangs outside the table frame, so `PagesTableView.hitTest` checks it first and `pointerHotspot` includes it. The same commands are in **Format → Table** and the cell's context menu; they act on the focused cell and are disabled outside a table (`validateMenuItem`). Every structural edit **commits the focused cell first** (commits always use `currentSource`, never the rendered text) and `applyTableEdit` detaches the editing field (`detachEditingField`) — otherwise the old field commits stale text into the new table shape when it resigns. `TableMutator.render` keeps GFM alignment colons. Table edits keep **the table** where it is on screen (`PagedEditorView.tableAnchor`, re-applied after each queued relayout pass), skip the controller's caret anchor (`isApplyingTableEdit` — the text caret may be anywhere in the document), and leave a zero-length caret so no hidden source is ever shown selected. The toolbar **Table** button (view-based, so the popover anchors under it) opens a Pages-style gallery (`TableStylePickerView`: Basic, Two Columns, Wide, Compact, Tall, Grid); one click inserts that shape with the cursor in the first cell.
11. **Format toolbar.** Heading popup, Bold, Italic, Strike, List, Link, Table, and the Code *insert* pull-down follow `MarkdownEditing.FormatState` at the caret. Code offers Inline Code, Text, Bash, Python, Swift, JSON: fence types insert an empty fenced block with the caret on the inner line (`MarkdownEditing.insertCodeBlock`), or retype the block the caret is in. A highlighted Bold click unwraps via `toggleInline`. Paragraph is heading level 0. Controls that cannot apply are **disabled**: fenced code, page-break, and thematic-break lines lock every format control. While a **table cell** is being edited the toolbar works on the cell's field editor instead (`activeCellEditor`: Bold, Italic, Strike, Inline Code, Link via `MarkdownEditing.toggleInline` / `insertLink` on the cell text; block formats disabled), and it follows the cell's selection (`NSTextView.didChangeSelectionNotification`). Inside a link label inline formatting works (`[the **docs**](url)`); inline code blocks bold/italic/strike/link (the Code pull-down stays enabled to unwrap); source-mode table cells still allow inline wraps.
12. **Headings.** Spacing is compact (AppKit does not collapse adjacent paragraph spacing). `h1`/`h2` draw a GitHub-style full-width rule in the heading's `paragraphSpacingAfter`. The blank line or setext underline under that rule is not typeable (`MarkdownEditing.snapOutOfHeadingRule`).
13. **Window chrome and sidebar (Preview parity).** The window uses `.fullSizeContentView` and its `contentViewController` is an `NSSplitViewController`: thumbnails are an `NSSplitViewItem(sidebarWithViewController:)` (150–240 pt, default 160, collapsible — below ~140 pt the toolbar pushes the thumbnails toggle into the overflow menu, so never lower the minimum), the editor column is the content item. Do **not** hand-roll the split, paint an opaque titlebar/sidebar fill, or turn off full-size content: the system sidebar item gives the full-height Liquid Glass pane (vibrant sidebar material on 14/15) with the traffic lights on it, and makes `NSTrackingSeparatorToolbarItem(.sidebarTrackingSeparator)` track the divider. The thumbnails toggle is a view-based `NSButton` (`visibilityPriority = .user`) placed before that separator, so it sits next to the window controls — also while the sidebar is collapsed. It must **not** be `isNavigational` (macOS 26 moves navigational items into the document header). The editor scroll view runs under the semi-transparent toolbar; `automaticallyAdjustsContentInsets` keeps the first page below it (same for the first thumbnail). The sidebar collapses with `NSSplitViewItem.isCollapsed` (animated, ease-in-out 0.25 s). Thumbnails keep A4 proportions, are centred, and use the **system** scroller style (never `.legacy` or a reserved gutter); the single column auto-sizes so the list never scrolls sideways. The selected page gets a light gray-blue rounded box that includes the page number. Glass KVC keys newer than macOS 26 (e.g. `effectIsInteractive`) must be guarded with `responds(to:)`. Default body text is Times New Roman 10 pt, configurable in Settings (`⌘,`).
14. **Thumbnail resizing.** Never re-render thumbnails per resize frame. Rows use a uniform `rowHeight` (no `heightOfRow` delegate). Cells are pure layers (bitmap `contents` with `contentsGravity = .resize`, selection box as a layer, shadow with an explicit `shadowPath`, no `draw(_:)`). Bitmaps are cached per page with a generation; during live resize, or less than 120 ms after a width change, they are only scaled. Afterwards visible rows re-render in ≤ 8 ms batches when the cached bitmap is smaller than the 16 pt-bucketed target or > 1.6× larger. Edits keep the old bitmap until the new one arrives. Scrolling is inset-aware so row 0 never hides under the titlebar.
15. **Zoom.** One Keynote-style pull-down (`zoomPopup`): `PageGeometry.zoomSteps` (25–400 %; ⌘+ / ⌘− step through the same list), then **Auto** (fit the page to the window; the old Fit Width and Wide modes were merged into it, and a stored `wide` migrates to `auto`). The title is **Auto** in Auto, else the live magnification as a localized percentage (no-break spaces normalized, as NSMenuItem does); the active mode or matching preset is checked. Auto refits whenever the editor's own frame changes (`NSView.frameDidChangeNotification` on the scroll view: sidebar slide, divider drag, window resize) and once more when the sidebar animation completes — do not key it off the sidebar width, which jumps to 0 before the editor grows. Every programmatic zoom goes through `setMagnification` / `applyZoomFromSettings`, which keep the **line at the top of the visible area** in place (exactly the document top when it was showing) — plain `NSScrollView.magnification` keeps the *centre*, which pushed an opened document's first page out of view. Measure the top via view-coordinate conversion (`visibleTopDocumentY`), not clip insets, and capture it **before** a settings restyle/relayout (`applySettings` passes `keepingTop`). Opening a document scrolls to the top (`scrollToTop`). Pinch-zoom ends in manual mode. Zoomed-out pages are centred with `CenteringClipView`.
16. **Tabs.** New documents open as a **tab** of the frontmost document window: `tabbingMode = .preferred`, and `DocumentWindowController.showWindow` attaches the window with `addTabbedWindow` explicitly (automatic tabbing depends on System Settings and key-window timing). `DocumentWindow` shows the native tab bar **only while a tab group has two or more tabs** (`syncAllTabBars` after add / close / move / merge / key), because AppKit otherwise remembers an explicit "Show Tab Bar" for a lone window. The View menu toggle is disabled. Never replace the system tab bar with a custom one.
17. **Launch and open.** Document windows reopen where the last one was (`DocumentWindowController.placeWindow`: frame saved on move / resize / close under `sk.lubino.marka.windowFrame`, cascaded 22 pt if another window already sits there, ignored when mostly off-screen) and are centred the first time — never AppKit's bottom-left default. No explicit "open Untitled" in `applicationDidFinishLaunching` (files from Finder arrive after it; AppKit asks `applicationShouldOpenUntitledFile` only when nothing is being opened). Opening a file while the only document is an untouched empty Untitled replaces it (`MarkaDocumentController.isPristineUntitled`).
18. **No status bar.** The toolbar `pageInfo` item (`PageNumberButton`) shows only the visible page number (Settings can hide it; ⌥⌘G still works). Clicking it, or View → Go to Page… (⌥⌘G), opens `DocumentInfoViewController` in a transient popover: editable page field + stepper (Return jumps, clamped), "This page: N words" and "Cursor on page N" when the caret is elsewhere, an optional word-goal progress bar (Settings → Word goal; 0 = off), words, characters (with/without spaces), selection, reading time, paragraphs, lines, headings, links, images, tables, code blocks, tasks, encoding, line endings, file size, modified date, saved state, and the path (wraps by character inside the 16 pt side insets) with Show in Finder / Copy Path. The popover has a fixed 320 pt width and an explicit `contentSize` from the laid-out content (an empty root frame squeezes the stack and drops the insets). Counts come from `MarkaCore.DocumentStats`, per-page ranges from `PagedEditorView.pageTextRanges()`, computed only while the popover is open.
19. **Find & replace.** The toolbar search button (view-based) and Edit → Find… (⌘F) / Find and Replace… (⌥⌘F) open `FindReplaceViewController` in a popover: find field with "n of m" and ↑/↓ (⌘G / ⇧⌘G, Return / ⇧Return), Replace (one undo step, continues to the next match), All (one undo step), Match Case, Whole Words. The popover is a two-column grid: equal-width capsule fields (Replace is a search field without the magnifier) and equal-width segmented controls (⌃ | ⌄ and Replace | All) sharing the right edge; focus is set *after* the popover is on screen (earlier, AppKit focused Replace). Matching is `MarkaCore.FindEngine` on the Markdown source; all matches are highlighted (temporary attributes in TextKit 1, rendering attributes in TextKit 2) and the current one is selected and flashed.
20. **Export, print, share.** PDF export draws the same pages and adds a URL annotation over every link label (`PDFExporter.linkRegions`: web links as-is, local and `.md` links as absolute file URLs; links inside tables are not annotated because tables are drawn by the overlay). Print goes through `NSDocument.printDocument(_:)` → `MarkdownDocument.printOperation(withSettings:)`: the standard print sheet with preview, copies and page range (File → Print… ⌘P and the toolbar Print button). Share uses the system `NSSharingServicePickerToolbarItem` (AppKit anchors the picker under the button) and File → Share is replaced on each menu open by `NSSharingServicePicker.standardShareMenuItem`; both share the document's `.md` file (`shareItems()`: saved documents share `fileURL`, autosaving pending edits first; untitled ones a temporary `<name>.md`). Never anchor a hand-made picker to the content view.
21. **Syntax highlighting.** `MarkaCore.SyntaxHighlighter` colours fenced code by its info string (bash/sh/zsh, JSON, Python, JavaScript/TypeScript, C/C++, Swift, HTML, XML, CSS/SCSS, YAML, Go, Rust, Java, Kotlin, Ruby, SQL, PHP). It returns non-overlapping UTF-16 ranges; `StyleEngine.highlightCode` only sets foreground colours (GitHub Primer palette, light/dark), so highlighting never changes layout. No packages.
22. **Fast, flash-free styling.** `applyStyles(range:)` restyles **incrementally**: `StyleEngine.apply(limit:)` grows the edited lines (plus one line of context each side, for setext underlines) to every span group touching them until stable, and styles only that region; edits whose old or new text contains a structural character (`` ` ``, `~`, `|` — fences, tables) restyle the whole document, because they can change blocks elsewhere. All attribute changes run inside one `beginEditing` / `endEditing` (otherwise every call is processed separately). `applyEdit` (format buttons, table and replace edits) restyles **synchronously** before the window can draw, so `**` / `*` never flash; typing restyles on the next run-loop turn. `MarkdownSyntax.parseInline` sizes its scratch array to the paragraph, never the document (that was O(paragraphs × length)). A UI test checks that every incremental restyle equals a full one.
23. **Edits never move the view.** `MarkdownTextView.applyEdit` replaces only the **changed range** (common prefix / suffix diff), never the whole text: a full replacement re-laid out the whole document, re-rendered every thumbnail and made formatting (Bold, Italic, …) shake the view for a while. `MarkdownTextView.shouldChangeText` tells the controller before every edit; it records the caret's on-screen offset (`editAnchor`) and restores it after restyle + relayout settle. `canvas.hasPendingRelayout` means another pass is *queued* — the running pass does not count, or the anchor never clears and later edits jump back to an old position; anchors also expire after 1 s. (A full restyle re-lays out from estimated heights first, which used to drift the view about a line per edit.)
24. **Undo.** `MarkdownTextView.allowsUndo` is true and uses the window `UndoManager`. Cmd+Z and Ctrl+Z both undo. Format, table, and replace edits go through `shouldChangeText` so each registers one undo unit. `applyStyles` disables undo registration so restyling is not an undo step. `setDocumentText` disables registration and clears actions with the text view as target (file open / reload). Do not mix a custom snapshot stack with AppKit `NSUndoTyping` in the same group.
25. **Empty untitled windows.** The text view is `initialFirstResponder`. Toolbar controls `refusesFirstResponder`. Typing into an empty document goes through `MarkdownTextView.insertText`.
26. **Crash reports.** `CrashReporter` installs an uncaught-exception handler and fatal-signal handlers, writes `~/Library/Logs/Marka/crash-*.log`, and on the next launch shows an alert with **Show Log**. No third-party crash service. Do not present the alert from UI tests (`MarkaRuntime.start` is the only installer).
27. **No WebKit.** Verify with `otool -L build/Marka.app/Contents/MacOS/Marka` — `WebKit.framework` must not appear.
28. **Math and Mermaid (native).** `MarkaCore.MathParser` turns a LaTeX math subset into a `MathNode` tree; `MathRenderer` lays it out TeX-style (atom spacing, math axis, display / text / script styles, stretched `\left…\right`, drawn radicals) on the system **STIX Two Math** font (present on macOS 14+), using Unicode mathematical alphanumerics for italic variables, `\mathbb`, `\mathcal`, `\mathbf`, …; unknown commands render red. `MarkaCore.Mermaid` parses flowcharts (layered Sugiyama-style layout: cycle breaking, longest-path ranks, barycentre ordering; back edges route around the whole chart), sequence diagrams and pie charts; `MermaidRenderer` draws them in Mermaid's default palette (dark-paper variant). Markdown: inline `$…$` (GitHub rules — no space just inside, no digit after the closing `$`, so prices stay text), display `$$…$$` (one or several lines) and ```math / ```mermaid fences, all `codeBlock(language:)` / `.inlineMath` spans. WYSIWYG: drawn blocks collapse their source like tables and reserve the drawing's height via `extraBlockSpacing`; a drawing that would cross a page break moves to the next page (`renderedPlacement`); no code chrome. Clicking a drawing opens `RenderedSourceEditor` (source + live preview; Done / click-away applies one undoable edit between the markers). Inline math hides its source, reserves the width as kern on the closing `$`, and `MarkdownTextView` draws the formula on the baseline; with the caret inside, the source shows (incremental restyle of that line only). `$` is a structural character for incremental restyling. PDF / print draw both (`drawRenderedBlocks`, `drawInlineMathForExport`); Core Text drawing resets the text matrix, or AppKit's flipped one turns glyphs upside down. Source mode shows raw Markdown.

---

## Build, test, release

```bash
# Unit tests (must pass before every commit)
swift run MarkaTests

# Off-screen AppKit UI tests (sidebar, code chrome, tables, links)
swift run MarkaUITests

# Ad-hoc signed app → build/Marka.app
./scripts/build-app.sh

# Install that build into /Applications and launch it
./scripts/install-local.sh

# Universal DMG + ZIP + checksums → build/
./scripts/package-dmg.sh

# GitHub Release from this Mac (tags exist; Actions often fail before upload)
./scripts/publish-release.sh --tag vX.Y.Z
./scripts/install-git-hooks.sh   # once per clone: tag push publishes in the background
```

SwiftPM's default build backend stamps the binary with `sdk 14.0` (the deployment target), which makes macOS 26+ run Marka in the pre-Liquid Glass compatibility look. `scripts/build-app.sh` re-stamps `LC_BUILD_VERSION` with the real SDK via `vtool` and fails if that did not work. Check with `xcrun vtool -show-build build/Marka.app/Contents/MacOS/Marka`. Note: `swift run MarkaUITests` binaries keep the 14.0 stamp, so UI tests exercise the compatibility appearance.

**App icon.** `scripts/generate-icon.swift` is the single vector source (1024 canvas): a thick rounded slab of **clear glass** (bright rim, diagonal reflection, soft caustic) with "Marka.MD" (one bold size, glyph outlines) and rows of bars that read as Markdown — a heading row, paragraph lines, a dashed list. Text and bars are solid glossy `#505E76` (not translucent); two bars are clear-glass accents. It renders the flat `AppIcon.icns` fallback — the plate must stay **opaque** and fill the standard 824 pt rounded square (100 pt margin, 185.4 pt radius): macOS 26 uses a flat icon as its own plate only when it conforms, otherwise it puts the whole icon onto a second, system-drawn plate ("two glasses"). With `--icon Resources/AppIcon.icon` it rewrites the committed Icon Composer bundle (light glass fill; Wordmark and Bars are opaque glass groups, Glass bars translucent); `--preview <png>` writes a 1024 px preview. Re-run it after changing the design. `build-app.sh` compiles the bundle with Xcode 26+'s `actool` into `Assets.car` + `CFBundleIconName` (Liquid Glass on macOS 26+; layered vector groups). It uses the active toolchain's `actool`, else any `/Applications/Xcode*.app` via `DEVELOPER_DIR` — the Swift build itself stays on the Command Line Tools, so `xcode-select` need not change (the Xcode license must be accepted once: `sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`). Without any Xcode, builds ship only the flat `.icns`. Opening the bundle in Icon Composer is the way to tune glass, shadows, and translucency.

Never commit secrets, `.DS_Store`, or build artifacts (`/.build`, `/build`, `*.app`, `*.dmg`).

GitHub Actions:

- `.github/workflows/ci.yml` — on push/PR: tests + `Marka.app`; on `main` also packages DMG/ZIP as artifacts.
- `.github/workflows/release.yml` — on tag `v*` (and workflow_dispatch): tests, universal package, GitHub Release assets (`Marka.dmg`, `Marka-macos.zip`, `SHA256SUMS.txt`). If that job fails (common: UI tests are errors on the GitHub macOS runner), publish from this Mac with `scripts/publish-release.sh`. A `pre-push` hook in `.githooks` starts that script after a `v*` tag is pushed.

---

## After any code change (local install)

The maintainer wants the **installed** app to match the working tree after every Marka change, without waiting for push.

1. Run `swift run MarkaTests` and `swift run MarkaUITests`.
2. Run `./scripts/install-local.sh` (builds `build/Marka.app`, replaces `/Applications/Marka.app`, launches it).
3. Do **not** skip the install because the user still has an old `build/` binary open.

This is separate from GitHub Release. Push/tag only when the user says **push**.

---

## Maintainer push protocol

When the user says **push**:

1. Run `swift run MarkaTests` and `swift run MarkaUITests`. Confirm `git status` / `git diff` contain no secrets or build artifacts.
2. Patch-bump `VERSION` (MAJOR.MINOR.PATCH).
3. Stage intended files, commit in English (what + why), `git push origin main`.
4. Tag SemVer (`git tag vX.Y.Z && git push origin vX.Y.Z`). The `.githooks/pre-push` hook then runs `scripts/publish-release.sh` so GitHub gets `Marka.dmg`, `Marka-macos.zip`, and `SHA256SUMS.txt` even when `release.yml` fails. If the hook is not installed, run `./scripts/install-git-hooks.sh` once, or `./scripts/publish-release.sh --tag vX.Y.Z` after the tag push.
