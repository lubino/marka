# Marka

Native macOS Markdown editor with a live A4 page preview.

You edit like in Word. The file stays clean Markdown. The pages on screen match print and PDF.

Requires **macOS 14 (Sonoma)** or newer.

## Install

### 1. One-line installer (recommended)

Downloads the latest GitHub Release, verifies the SHA-256 checksum, installs `Marka.app` into `/Applications`, and launches it:

```bash
curl -fsSL https://raw.githubusercontent.com/lubino/marka/main/install.sh | bash
```

To update, run the same command again. To uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/lubino/marka/main/install.sh | bash -s -- --uninstall
```

### 2. Disk image from GitHub Releases

1. Download **`Marka.dmg`** from the **[latest release](https://github.com/lubino/marka/releases/latest)**.
2. Open the disk image and drag **Marka.app** into **Applications**.

Marka is open source and ad-hoc signed (no paid Apple Developer ID). If Gatekeeper blocks a browser download, choose **Open Anyway** in **System Settings → Privacy & Security**, or run:

```bash
xattr -cr /Applications/Marka.app && open /Applications/Marka.app
```

### 3. Zip from GitHub Releases

Download **`Marka-macos.zip`** from the same [releases page](https://github.com/lubino/marka/releases/latest), unzip it, and move `Marka.app` to Applications.

### 4. Build from source

Command Line Tools with Swift 6+ are enough (`xcode-select --install`). Full Xcode is not required:

```bash
curl -fsSL https://raw.githubusercontent.com/lubino/marka/main/install.sh | bash -s -- --from-source
```

Or clone and build locally:

```bash
git clone https://github.com/lubino/marka.git
cd marka
./scripts/build-app.sh
open build/Marka.app
```

## What you get

The saved file is ordinary UTF-8 GitHub-Flavored Markdown. Opening and saving without edits keeps the original bytes, including line endings.

**Writing**

- WYSIWYG Markdown: markers stay hidden while you write; source mode (`⌘/`) shows the raw Markdown.
- Headings (GitHub-style rule under Heading 1 and 2), bold, italic, strikethrough, lists, task lists, quotes, images, horizontal rules, and manual page breaks (`<!-- pagebreak -->`).
- Bold and italic can wrap links and inline code (`**[readme](README.md)**`, `**`Marka.dmg`**`); inline code gets GitHub's rounded box.
- Live format toolbar: controls highlight from the cursor, toggle off when already applied, and disable where a format cannot apply (fenced code, tables, …). The Code pull-down toggles inline code or inserts an empty fenced block (Text, Bash, Python, Swift, JSON).
- Search & replace popover from the toolbar search button (`⌘F` / `⌥⌘F`): match count, next/previous, Replace, Replace All, Match Case, Whole Words.
- Editing never makes the view jump, even when you change a code block's language.

**Links**

- Word-style links: only the blue label shows; a card shows the address (Open / Copy / Remove). `⌘`-click opens.
- Links to Markdown files open in a new Marka tab. A link to a Markdown file that does not exist yet creates it (empty) next to the document.

**Code**

- Fenced code is syntax-highlighted: bash, JSON, Python, JavaScript/TypeScript, C/C++, Swift, HTML, XML, CSS, YAML, Go, Rust, Java, Kotlin, Ruby, SQL, PHP.
- Small round glass Copy icon on code blocks and quotes; shell blocks also get a Run-in-Terminal icon.

**Tables**

- Tables look like GitHub's. Insert one from the toolbar's Table gallery (Basic, Two Columns, Wide, Compact, Tall, Grid).
- Cells hold inline Markdown (bold, italic, `code`, links), rendered in place; click a cell to edit its source. Tab / Return move between cells and add a row at the end.
- With the cursor in a cell, a small bar under the table inserts and deletes rows and columns, and grips let you drag a row or column to a new place. The same commands are in Format → Table and the cell's right-click menu.
- Long tables continue on the next page with the header repeated.

**Pages, export, print**

- Live A4 pages; what you see is what PDF and print produce.
- Export PDF (`⇧⌘E`) keeps links clickable. File → Print… (`⌘P`) and the toolbar Print button open the standard print dialog.
- Share the document's `.md` file with the standard macOS share button or File → Share.

**Window**

- Preview-style window: full-height thumbnail sidebar with the window controls on it, the document scrolling under a translucent toolbar, Liquid Glass on macOS 26+.
- New documents open as tabs; the tab bar appears once two or more tabs are open.
- Zoom pull-down with 25–400 % presets and Auto (fits the page to the window, shown as "Auto %").
- The toolbar shows the current page number. Click it (or View → Go to Page…, `⌥⌘G`) to jump to a page and see word, character, selection and reading-time counts, structure counts, a word-goal progress bar, encoding, line endings, file size, and the file path.
- Settings (`⌘,`): default font and size (Times New Roman 10 pt), margins, page numbers, autosave, dark paper, word goal, page number in the toolbar.
- Autosave, light/dark UI (paper stays white unless you enable dark paper). Crash logs go to `~/Library/Logs/Marka`, and the next launch offers to show the latest report.

## Shortcuts

| Action                        | Shortcut                                  |
| ----------------------------- | ----------------------------------------- |
| Undo / Redo                   | `⌘Z` or `⌃Z` / `⇧⌘Z`                      |
| Bold / Italic / Link          | `⌘B` / `⌘I` / `⌘K`                        |
| Heading 1 / 2 / 3             | `⌥⌘1` / `⌥⌘2` / `⌥⌘3`                     |
| Find / Find and Replace       | `⌘F` / `⌥⌘F`                              |
| Find Next / Previous          | `⌘G` / `⇧⌘G`                              |
| Go to Page                    | `⌥⌘G`                                     |
| Source mode                   | `⌘/`                                      |
| Thumbnails sidebar            | `⌥⌘S`                                     |
| Zoom in / out / actual size   | `⌘+` / `⌘-` / `⌘0`                        |
| Export PDF / Print            | `⇧⌘E` / `⌘P`                              |
| Settings                      | `⌘,`                                      |
| Table rows and columns        | Format → Table, or the bar under a table  |

## License

[MIT](./LICENSE)
