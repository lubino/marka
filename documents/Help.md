# Marka Help

## What is Marka?

Marka is a writing app for your Mac. You write like in Pages or Word: bold looks bold, a heading looks like a heading, a table looks like a table.

Behind the scenes Marka saves a **Markdown** file (`.md`). Markdown is plain text with a few simple signs, like `**bold**` or `# Heading`. Almost every tool understands it - GitHub, notes apps, websites, AI assistants - so your writing never gets locked inside one app.

Think of it like this: **you see the finished cake, the file keeps the recipe.**
![preview](assets/preview.png)
## When should I use Marka?

- Notes, documentation, README files, plans, reports, letters.
- Anything that lives in a Git repository (like on GitHub).
- When you want a clean `.md` file *and* nice A4 pages you can print or turn into a PDF.

Use a design tool instead if you need posters, free placement of pictures, or columns.

## The basics

**Open and create.** ⌘N makes a new document, ⌘O opens one. Several documents open as tabs in one window.

**Saving.** Marka saves by itself while you work (Autosave). You can still press ⌘S. Marka never rewrites the parts of a file you did not touch.

**Pages.** The white sheets are real A4 pages. What you see is exactly what prints and what goes into a PDF (⇧⌘E). The thumbnails on the left show every page; click one to jump there.

**See the recipe.** Press ⌘/ to see the raw Markdown. Press it again to go back.

**Undo.** ⌘Z takes back the last change, ⇧⌘Z brings it back.

## Writing and formatting

Select some words, then click a button in the toolbar (or use the Format menu):

- **B** bold, *I* italic, ~~S~~ strikethrough.
- **Text effects** (the button next to S): underline, superscript (E = mc²), subscript (H₂O) and keyboard keys (like ⌘ K).
- **Heading** menu: Heading 1 is the biggest title, Heading 6 the smallest. Paragraph is normal text.
- **Lists**: press ↩ for the next item; press ↩ on an empty item to finish the list. Tab moves an item in, ⇧Tab moves it back out.
- **Quotes** and **code** are in the Format menu and the Code button.

Click a button again to take the formatting away.

## Links

A link is a word you can click to go somewhere - a website, another file, or a heading in this document.

1. Select a word and press ⌘K.
2. A small card appears under the word. Type the address there and press ↩.

The card's buttons, from the left:

| Button | What it does |
| --- | --- |
| Content (list) | Pick a heading of this document or a file next to it - Marka writes the address for you |
| Folder | Pick any file on your Mac |
| Arrow | Open the link |
| Two pages | Copy the address |
| Broken chain | Remove the link but keep the word |

**How addresses work.** An address starting with `https://` is a website. Anything else is a file *next to your document* - `notes.md` means "the file notes.md in the same folder". `#setup` means "the heading called Setup in this document".

⌘-click a link to open it. A link to a `.md` file that does not exist yet creates it for you.

## Pictures

Drag a picture onto the page, or use **Insert → Image…**. Marka shows the picture, never the file name.

**Picture from somewhere else?** If the picture is not in the same folder (or Git repository) as your document, Marka asks:

- **Copy Image** - puts a copy next to your document (in an `assets` folder). Choose this almost always: the picture then travels with your document.
- **Use Original Location** - points to the picture where it is. Careful: it only works on this Mac. Anyone else will see a broken picture.

**Click a picture** for its card: change the picture, open it, copy its location, remove it, or press the **gear** to set its size (in pixels or %), alignment (left, center, right) and a description for people who cannot see it.

## Tables

Tables look like on GitHub: a bold first row and thin lines.

- **Make one:** the Table button in the toolbar shows ready-made shapes - click one.
- **Type in it:** click a cell and write. Tab goes to the next cell, ↩ to the cell below. At the end of the table they add a new row.
- **Change its shape:** while you are in a cell, a blue handle appears next to the row and above the column. Drag a handle to move that row or column. Click a green **+** to add one, a red **−** to delete one.
- **Line up a column:** Format → Table → Align Column Left / Center / Right.
- Pictures can go into cells too.

## Equations and diagrams

**Insert** menu → Equation, Matrix, Flowchart, Left-to-right flow, Sequence Diagram or Pie chart. A small window shows examples; click one and it lands in your document as a finished drawing.

Click the drawing to change it. You will see its recipe on the left (LaTeX for math, Mermaid for diagrams) and a live preview - change a word, watch the drawing change. ⌘↩ or clicking away saves it.

For math inside a sentence, write it between dollar signs: `$a^2 + b^2 = c^2$`.

## Notes and warnings

**Insert → Note, Tip, Important, Warning or Caution** adds a colored box, just like on GitHub. Type your message on the line under the title.

## Emoji

**Edit → Replace Emojis…** finds codes like `:rocket:` or `:)` and turns them into real emoji 🚀 🙂 - one at a time with **Replace**, or all at once with **All**.

In Settings you can also let Marka *show* `:rocket:` codes as emoji while the file keeps the code (GitHub does the same).

## Finding your way

- **Find (⌘F):** type a word, press ↩ to jump to the next place it appears. **Find and Replace (⌥⌘F)** swaps words.
- **Content (⌘L, or the list button in the toolbar):** shows every heading of your document and the files next to it. Start typing to filter, press ↩ to go there.
- **Page (the page number in the toolbar, ⌥⌘G):** jump to a page, and see how many words, characters and pages you have, plus reading time and an optional word goal.

## When other apps change your file (Auto-load)

Imagine a friend edits your document on a shared folder, or an AI assistant fixes a typo in the file. Marka notices right away and shows the new text, without moving where you are reading.

If you were in the middle of changing the same document, Marka asks which version to keep: **Load from Disk** (theirs) or **Keep Mine** (yours).

You can turn this off in Settings → Auto-load.

## Git and Publish

**What is Git?** Git is like a time machine and a shared drawer for files. Every time you "commit", Git takes a photo of your files with a short note ("Fixed the install steps"). "Pushing" sends those photos to a shared place (like GitHub) so others can see them.

**Publish** does both for you in one click:

1. Write as usual. The **Publish** button (paper plane) lights up when your document is part of a Git repository.
2. Click **Publish**. You see:
   - **Message** - write what you changed, in one short sentence.
   - **Files** - every changed file Marka will publish, with how many lines were added (green) or removed (red).
   - **Diff** - exactly what changed: green lines are new, red lines are gone.
   - **History** - the last three publishes: who, when and what.
3. Press **Publish** (or ⌘↩). Marka saves, commits and pushes.

Good to know:

- All open documents from the same repository are published together.
- Files your document links to (and pictures it shows) are added automatically, so nothing is missing for others.
- New files Marka creates inside a repository are added to Git right away.
- If there is no shared place (no "origin"), Publish only takes the photo (commit) on your Mac.
- **If something goes wrong** (for example someone else published first), Marka tells you and keeps your changes safe. Click **Show more** to see what Git said, then fix it with a Git tool such as GitHub Desktop or Terminal.

**Newer version available.** When you open a file, Marka quietly checks whether someone published a newer version. If yes, it asks: *Update?* Choose **Yes** to get the newest version. In Settings you can make Marka update automatically, or turn the check off.

Publish appears only when Git is installed on your Mac. You can switch it off in Settings → Git.

## Settings (⌘,)

Font and size, page margins, page numbers, Autosave, Auto-load, dark paper, word goal, emoji codes, whether a script run in Terminal waits for a key press at the end, and the Git options.

## PDF from Terminal

Marka can also make a PDF without opening a window - handy for scripts:

```bash
/Applications/Marka.app/Contents/MacOS/Marka -pdf notes.md notes.pdf
```

It prints how many pages, words, headings, images and so on the document has. All the details - a short `marka` command, exit codes, exporting a whole folder - are in **cli.md** (on GitHub: https://github.com/lubino/marka/blob/main/documents/cli.md).

## More

- The hands-on tutorial: **Help → Marka Tutorial** (also the *Marka Tutorial* folder in the download).

- All keyboard shortcuts: **Help → Keyboard Shortcuts**.
- Marka is free and open source: https://github.com/lubino/marka
