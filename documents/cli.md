# Marka Command Line

Marka can turn a Markdown file into a PDF straight from Terminal - no window opens. The PDF looks exactly like **File → Export PDF…** in the app: same A4 pages, fonts, margins, page numbers, tables, images, math and diagrams, using your Marka Settings.

## Export a PDF

```bash
/Applications/Marka.app/Contents/MacOS/Marka -pdf cli.md cli.pdf
```

- The first file is the Markdown to read, the second the PDF to write.
- The PDF name is optional. Without it Marka writes `notes.pdf` next to `notes.md`:

  ```bash
  /Applications/Marka.app/Contents/MacOS/Marka -pdf cli.md
  ```

- `--pdf` works too. Paths may be relative to the current folder or start with `~`.
- Pictures and links are found relative to the Markdown file, as in the app.
- Missing folders for the PDF are created.

## What it prints

After the export Marka prints the same numbers as the **Page** popover in the app:

```text
Exported /Users/you/Documents/notes.pdf

Pages           6
Words           745
Characters      5,681
Without spaces  4,190
Reading time    4 min
Paragraphs      16
Lines           152
Headings        5
Links           9
Images          3
Tables          1
Code blocks     9
```

A **Tasks** line (for example `3 of 5 done`) appears when the document has task lists.

## A shorter command

Typing the full path each time is long. Make a `marka` command once:

```bash
# Just for you (zsh, the macOS default shell):
echo 'alias marka=/Applications/Marka.app/Contents/MacOS/Marka' >> ~/.zshrc
source ~/.zshrc
```

or, for every user and every shell:

```bash
sudo ln -sf /Applications/Marka.app/Contents/MacOS/Marka /usr/local/bin/marka
```

Then:

```bash
marka -pdf README.md README.pdf
```

## In scripts

The exit code tells a script what happened:

| Code | Meaning |
| --- | --- |
| 0 | The PDF was written |
| 1 | Something went wrong (for example the Markdown file does not exist); the reason is printed |
| 2 | Wrong arguments (no input file); the usage is printed |

Export every Markdown file in a folder:

```bash
for f in docs/*.md; do
  marka -pdf "$f" "pdf/$(basename "${f%.md}").pdf" || echo "failed: $f"
done
```

## Help

```bash
marka --help
```

Marka must be installed (in `/Applications`). The export runs without the app's window, Dock icon or menu bar, and it does not change any of your documents.
