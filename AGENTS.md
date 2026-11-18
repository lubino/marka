# AGENTS.md — Developer guide for Marka

Read this before changing Marka. All code, comments, commit messages, and documentation on disk must remain in **English**. Chat with humans may be multilingual.

End users should read [`README.md`](./README.md).

---

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
   - Tests live in `Tests/MarkaCoreTests/main.swift` and run with `swift run MarkaTests`.
3. `Package.swift` uses `swift-tools-version: 6.0`. Keep `MarkaCore` `Sendable` where it crosses isolation. AppKit types stay on the main actor.

---

## Project structure

```text
marka/
├── Package.swift                 # MarkaCore, executable Marka (MarkaApp), MarkaTests
├── VERSION                       # SemVer read by scripts/build-app.sh
├── install.sh                    # User installer (release zip or --from-source)
├── scripts/
│   ├── build-app.sh              # swift build + Info.plist + AppIcon + ad-hoc codesign
│   ├── package-dmg.sh            # Universal DMG + ZIP + SHA256SUMS.txt
│   └── generate-icon.swift       # Programmatic AppIcon.iconset
├── Sources/
│   ├── MarkaCore/                # Foundation only — unit-tested
│   │   ├── PageGeometry.swift    # A4 points, exclusion-path pagination math
│   │   ├── EditorSettings.swift  # UserDefaults-backed settings
│   │   ├── FileCodec.swift       # UTF-8 BOM + LF/CRLF/CR identity encode
│   │   ├── MarkdownSyntax.swift  # GFM-ish spans (content vs hidden markers)
│   │   ├── MarkdownEditing.swift # wrap, headings, lists, return/tab rules
│   │   └── TableMutator.swift    # add/remove GFM rows and columns
│   └── MarkaApp/                 # AppKit document app
│       ├── main.swift
│       ├── AppDelegate.swift     # menus + custom NSDocumentController
│       ├── Document/
│       │   ├── MarkdownDocument.swift
│       │   └── DocumentWindowController.swift
│       ├── Editor/
│       │   ├── MarkdownTextView.swift
│       │   └── StyleEngine.swift # attributes + Typora-style marker hiding
│       ├── Layout/
│       │   └── PagedEditorView.swift  # A4 sheets, exclusions, page breaks
│       ├── Views/
│       │   ├── ThumbnailSidebar.swift
│       │   └── SettingsWindowController.swift
│       └── Export/
│           └── PDFExporter.swift # PDF + NSPrintOperation (same pages)
└── Tests/MarkaCoreTests/main.swift
```

---

## Architecture invariants

1. **One source string.** `NSTextStorage.string` is the Markdown. Styles and hidden markers are display attributes only. Never replace the source with RTF, HTML, or attachments that drop syntax.
2. **Identity save.** `FileCodec.encode` returns the original `Data` when the normalized string is unchanged.
3. **A4 pagination.** One text container whose width is the content area. Inter-page gaps (bottom margin + grey gutter + top margin) are `NSTextContainer.exclusionPaths`. Forced breaks are `<!-- pagebreak -->` plus an extra hole to the bottom of the current page.
4. **WYSIWYG markers.** Markdown delimiters use a near-zero font and clear color unless the caret intersects the span’s `group` range (Typora behaviour). Source mode (`⌘/`) shows the raw Markdown with highlighting and does not hide markers.
5. **Images.** Drag/drop copies the file into `./assets/` next to the document and inserts `![alt](assets/…)`. Overlays draw the bitmap; the Markdown line stays in the file.
6. **No WebKit.** Verify with `otool -L build/Marka.app/Contents/MacOS/Marka` — `WebKit.framework` must not appear.

---

## Build, test, release

```bash
# Unit tests (must pass before every commit)
swift run MarkaTests

# Ad-hoc signed app → build/Marka.app
./scripts/build-app.sh

# Universal DMG + ZIP + checksums → build/
./scripts/package-dmg.sh
```

Never commit secrets, `.DS_Store`, or build artifacts (`/.build`, `/build`, `*.app`, `*.dmg`).

GitHub Actions:

- `.github/workflows/ci.yml` — on push/PR: tests + `Marka.app`; on `main` also packages DMG/ZIP as artifacts.
- `.github/workflows/release.yml` — on tag `v*` (and workflow_dispatch): tests, universal package, GitHub Release assets (`Marka.dmg`, `Marka-macos.zip`, `SHA256SUMS.txt`).

---

## Maintainer push protocol

When the user says **push**:

1. Run `swift run MarkaTests`. Confirm `git status` / `git diff` contain no secrets or build artifacts.
2. Patch-bump `VERSION` (MAJOR.MINOR.PATCH).
3. Stage intended files, commit in English (what + why), `git push origin main`.
4. For a downloadable GitHub Release, also tag SemVer (`git tag vX.Y.Z && git push origin vX.Y.Z`) so `release.yml` publishes binaries.
