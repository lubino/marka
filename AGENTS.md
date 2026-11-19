# AGENTS.md — Developer guide for Marka

Read this before changing Marka. All code, comments, commit messages, and documentation on disk must remain in **English**. Chat with humans may be multilingual.

End users should read [`README.md`](./README.md).

- ---

## What Marka is

**Marka** is a native, lightweight Markdown editor for macOS. You edit like in Word, the file stays clean GitHub-Flavored Markdown, and the pages on screen match print and PDF (A4).

Hard product rules (from the original spec):

- Swift + AppKit (SwiftUI only if AppKit cannot do the job). TextKit 2 for layout.
- **No WebKit, Electron, or JavaScript.** No `WKWebView`.
- macOS 14+, Apple Silicon first.
- App bundle ≤ 8 MB. Typical 20-page document ≤ 60 MB RAM. Launch under 0.5 s.
- Minimum dependencies. v1 uses a range-accurate parser in `MarkaCore` so styling maps 1:1 onto UTF-16 ranges in the source. Do not add packages without a written reason.
- MIT license.
- **The `.md` file is the source of truth.** Saving must not rewrite lines the user did not edit. Unedited documents round-trip **byte-identically** (BOM and line endings included).
- What you see on the A4 pages is what PDF and print produce (one layout).

Out of scope for v1: cloud sync, collaboration, plugins, LaTeX, Mermaid, code syntax highlighting, Windows, Linux.

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
│   └── generate-icon.swift       # Programmatic AppIcon.iconset
├── Sources/
│   ├── MarkaCore/                # Foundation only — unit-tested
│   │   ├── PageGeometry.swift    # A4 points, exclusion-path pagination math
│   │   ├── EditorSettings.swift  # UserDefaults-backed settings
│   │   ├── FileCodec.swift       # UTF-8 BOM + LF/CRLF/CR identity encode
│   │   ├── MarkdownSyntax.swift  # GFM-ish spans (content vs hidden markers)
│   │   ├── MarkdownEditing.swift # wrap, headings, lists, return/tab rules
│   │   ├── TableMutator.swift    # insert/delete GFM rows, columns, and whole tables
│   │   └── ShellRunner.swift     # shell fences → Terminal .command files
│   ├── MarkaApp/                 # MarkaUI library (AppKit)
│       ├── MarkaRuntime.swift    # MarkaRuntime.start()
│       ├── Testing/
│       │   └── EditorWindowHarness.swift
│       ├── AppDelegate.swift     # menus + custom NSDocumentController
│       ├── Document/
│       │   ├── MarkdownDocument.swift
│       │   └── DocumentWindowController.swift
│       ├── Crash/
│       │   └── CrashReporter.swift # local ~/Library/Logs/Marka crash files
│       ├── Editor/
│       │   ├── MarkdownTextView.swift
│       │   └── StyleEngine.swift # attributes + Typora-style marker hiding
│       ├── Layout/
│       │   ├── PagedEditorView.swift  # A4 sheets, exclusions, page breaks, chrome
│       │   └── CenteringClipView.swift # zoom-out pages sit in the middle of the window
│       ├── Views/
│       │   ├── CodeBlockChromeView.swift  # GitHub-style fence fill + copy button
│       │   ├── LinkCardView.swift         # Word-style hyperlink card (Open / Copy / Remove)
│       │   ├── TableOverlayView.swift     # visual GFM table + Pages-style + handles
│       │   ├── TableSizePickerView.swift  # Pages-style insert-table grid
│       │   ├── ThumbnailSidebar.swift
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
3. **A4 pagination.** One text container whose width is the content area. Inter-page gaps (bottom margin + grey gutter + top margin) are `NSTextContainer.exclusionPaths`. Forced breaks are `<!-- pagebreak -->` plus an extra hole to the bottom of the current page.
4. **WYSIWYG markers.** Markdown delimiters stay hidden in WYSIWYG (near-zero font, clear color). Clicking must not reveal `*`, `_`, `` ` ``, or quotes, and must not restyle the whole document (that jumps layout). Source mode (`⌘/`) shows the raw Markdown.
5. **Images.** Drag/drop copies the file into `./assets/` next to the document and inserts `![alt](assets/…)`. Overlays draw the bitmap; the Markdown line stays in the file.
6. **Fenced code.** WYSIWYG keeps the source fences; padding is paragraph indent/spacing. A rounded GitHub-style fill is drawn *behind* the text view (clicks pass through). A semi-transparent copy chip (two overlapping squares) **hangs off the top-right corner** of the block; only that chip takes hits (`hitTest` uses superview coordinates). The same chip is used on block quotes (copies inner text without `>`). Hover uses the pointing-hand cursor; a click copies inner text with a single `setString`. Shell fences (`sh` / `bash` / `zsh` / `shell` / `fish` / `ksh`) also get a terminal chip to the left of copy; a click writes an executable `.command` file (`ShellRunner`) that `cd`s to the document directory and opens it with Terminal.app. If a fenced block crosses a page break, the fill and text are clipped to each page’s content rect (`PageLayout.pageContentPieces`) so nothing paints the grey gutter.
7. **Links.** WYSIWYG shows only the display text (blue, underlined, pointing-hand), including `[`code`](url)` such as `[`README.md`](./README.md)`. Do **not** set `NSAttributedString.Key.link` on the glyphs — that steals clicks. The URL stays in the Markdown but is hidden as a marker. Clicking a link places the caret in the **label** so it can be typed; the Word-style card shows the address (Open / Copy / Remove) without taking first responder. ⌘K focuses the address field. ⌘-click and Open resolve via `Hyperlink.destination`: local `.md` files open in a new Marka window; other local files and `http(s)` / `mailto` URLs open with the system.
8. **Tables.** Insert uses a Pages-style size grid (`TableSizePickerView`). New tables start with empty cells (header placeholders only). WYSIWYG hides the GFM source and shows `TableOverlayView` with translucent floating `+`/`−` chips on the grid edges (add row on the bottom line, add column on the right line, delete row on the left of the selection, delete column on the top). Deleting the last data row, last column, or the header removes the whole table (GFM needs a header). Format → Table → Delete Table and the overlay context menu do the same. Tab/Return at the last cell add a row. Edits go through `TableMutator`. Source mode shows the raw pipes. A table that does not fit the rest of the page continues on the next page (`PageLayout.flowTableRows`); the header row is repeated and chrome is clipped out of the grey gutter. Table spacing is folded into the bounded `relayout()` loop — never `queueRelayout()` from `refreshTables`, or adding a column can flicker the window and hang.
9. **Format toolbar.** Heading popup, Bold, Italic, Strike, List, Link, and Code follow `MarkdownEditing.FormatState` at the caret. A highlighted Bold click unwraps via `toggleInline`. Paragraph is heading level 0. Controls that cannot apply at the caret are **disabled**: fenced code, page-break, and thematic-break lines lock every format control; WYSIWYG table overlay does the same; inline code blocks bold/italic/strike/link (the Code button stays on so it can unwrap); source-mode table cells still allow inline wraps.
10. **Sidebar.** The thumbnail pane slides open and closed like Preview (ease-in-out, 0.25 s, width animates to 0). Auto/Wide zoom follows the editor width during the animation. Do not snap `isHidden` until the width is 0. Thumbnails are A4 white pages (snapshot of `paperRect`) with a soft shadow and no grey frame; the selected page gets an accent ring that hugs the paper. The sidebar toolbar item sits **before** `sidebarTrackingSeparator` so it leads the window title, like Preview.
11. **Undo.** `MarkdownTextView.allowsUndo` is true and uses the window `UndoManager`. Cmd+Z and Ctrl+Z both undo. Format and table inserts go through `shouldChangeText` so they register one undo unit. `applyStyles` must disable undo registration so attribute restyling is not an undo step. `setDocumentText` disables registration and clears actions with the text view as target (file open / reload). Do not mix a custom snapshot stack with AppKit `NSUndoTyping` in the same group.
12. **No WebKit.** Verify with `otool -L build/Marka.app/Contents/MacOS/Marka` — `WebKit.framework` must not appear.
13. **Headings.** Spacing is compact (AppKit does not collapse adjacent paragraph spacing). `h1`/`h2` draw a GitHub-style full-width rule in the heading’s `paragraphSpacingAfter`. The blank line or setext underline under that rule is not typeable (`MarkdownEditing.snapOutOfHeadingRule`). Zoom toolbar is Preview-like: minus glass, auto (magnifier + A), plus glass — no percent label. Zoomed-out pages are centered with `CenteringClipView`.
14. **Crash reports.** `CrashReporter` installs an uncaught-exception handler and fatal-signal handlers, writes `~/Library/Logs/Marka/crash-*.log`, and on the next launch shows an alert with **Show Log**. No third-party crash service. Do not present the alert from UI tests (`MarkaRuntime.start` is the only installer).
15. **Empty untitled windows.** The text view is `initialFirstResponder`. Toolbar controls `refusesFirstResponder`. Typing into an empty TextKit 2 document goes through `MarkdownTextView.insertText`.

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
```

Never commit secrets, `.DS_Store`, or build artifacts (`/.build`, `/build`, `*.app`, `*.dmg`).

GitHub Actions:

- `.github/workflows/ci.yml` — on push/PR: tests + `Marka.app`; on `main` also packages DMG/ZIP as artifacts.
- `.github/workflows/release.yml` — on tag `v*` (and workflow_dispatch): tests, universal package, GitHub Release assets (`Marka.dmg`, `Marka-macos.zip`, `SHA256SUMS.txt`).

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
4. For a downloadable GitHub Release, also tag SemVer (`git tag vX.Y.Z && git push origin vX.Y.Z`) so `release.yml` publishes binaries.
