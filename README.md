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

- WYSIWYG Markdown (markers stay hidden; source mode `⌘/` shows raw Markdown)
- Live A4 pages with thumbnail sidebar (white page chips, no grey frame)
- Headings, emphasis, lists, task lists, quotes, images
- Word-style links: blue display text (including `[`file.md`](./file.md)`), URL card (Open / Copy / Remove). Local Markdown opens in Marka; other URLs open in the system app
- GitHub-style fenced code and quotes: overlapping-squares copy chip hanging off the top-right corner. Shell fences also get a Terminal chip that runs the block in Terminal.app
- Pages-style tables: size grid on insert, empty cells, A/B/C column letters and row numbers, green + to add and red − to delete (select a row or column first). Last row/column removes the table. Long tables split across pages with a repeated header. WYSIWYG never shows the raw `|` pipes.
- Crash logs in `~/Library/Logs/Marka`; the next launch offers to show the latest report
- Live format toolbar: Bold, headings, and other controls highlight from the caret and toggle off when already applied. The Code control is a popup (Inline / Text / Bash / Python / Swift / JSON) that inserts an empty fenced block with the caret inside, or toggles inline backticks. Controls disable in fenced code, a Pages table, and other places where that format cannot apply
- Compact headings and paragraphs; GitHub-style underline under Heading 1 and 2 (the rule is not a typeable line)
- Preview-style chrome: sidebar button before the document title; zoom is − / Auto / + magnifiers. Zoomed-out pages stay centered.
- Manual page break: `<!-- pagebreak -->`
- Export PDF (`⌘⇧E`) and print (`⌘P`) using the same pages
- Share the `.md` file or a generated PDF
- Autosave, find & replace, zoom, light/dark UI (paper stays white unless you enable dark paper)

The saved file is ordinary UTF-8 GitHub-Flavored Markdown. Opening and saving without edits keeps the original bytes, including line endings.

## Shortcuts

| Action               |     | Shortcut                                                    |
| -------------------- | --- | ----------------------------------------------------------- |
| Undo / Redo          |     | `⌘Z` or `Ctrl+Z` / `⌘⇧Z`                                    |
| Bold / Italic / Link |     | `⌘B` / `⌘I` / `⌘K`                                          |
| Find                 |     | `⌘F`                                                        |
| Source mode          |     | `⌘/`                                                        |
| Sidebar              |     | `⌘⌥S`                                                       |
| Export PDF           |     | `⌘⇧E`                                                       |
| Print                |     | `⌘P`                                                        |
| Zoom                 |     | Auto / Wide (default Auto), `⌘+` `⌘-` `⌘0`                  |
| Table                |     | Format → Table (row above/below, column left/right, delete) |

## License

[MIT](./LICENSE)
