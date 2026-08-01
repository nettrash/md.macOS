# md for macOS

[![build](https://github.com/nettrash/md.macOS/actions/workflows/macos.yml/badge.svg)](https://github.com/nettrash/md.macOS/actions/workflows/macos.yml)

The simplest Markdown editor for the Mac. Write Markdown on the left, see
it rendered on the right — or switch to a full-window **Edit** or
**Preview**. Built in SwiftUI on top of the native `NSDocument` document
architecture, with a hand-written Markdown renderer. **No third-party Swift
packages, no accounts, no servers** — your files live wherever you keep them
(on disk, or in iCloud Drive). The only vendored code is the offline math /
diagram engines under `md/rich/` (KaTeX with the mhchem chemistry extension,
Mermaid, Graphviz, PlantUML, and highlight.js for code).

> This is the native macOS sibling of [**md**](https://github.com/nettrash/md),
> the iPhone / iPad editor. The two share the same hand-written Markdown
> parser, renderer and themed HTML export byte-for-byte; only the editor,
> the document chrome and the export plumbing differ, because this app is
> pure **AppKit** under the SwiftUI surface (`NSTextView`,
> `NSSharingServicePicker`, `NSPrintOperation`) rather than UIKit. A native
> Mac build is what makes a *real* `NSDocument`-backed `DocumentGroup`
> possible — so the title-bar folder display, **Rename**, **Move To**,
> **Duplicate** and **New** all work natively, which a Mac Catalyst port
> could never do reliably.

## Features

- **Document-based, the Mac way.** Open, edit and save `.md` / `.markdown`
  files anywhere through the standard open / save panels, with autosave,
  versions, and the title-bar proxy menu's **Rename / Move To / Duplicate**
  — all native, because the app is a real `NSDocument` `DocumentGroup`.
  Plain-text files open too and keep their extension. A **TextBundle**
  (`.textbundle`) or **TextPack** (`.textpack`) — the Markdown-with-images
  container Ulysses, iA Writer and Bear write — opens too, imported as its
  text for editing (the bundle's own `assets/` images aren't shown in the
  preview).
- **Live preview.** A built-in renderer covers the everyday Markdown you
  actually write:
  - Headings (`#`–`######`)
  - **Bold**, *italic*, `inline code`, [links](https://nettrash.me) and
    ~~strikethrough~~ (via Apple's own inline Markdown engine)
  - Bullet, numbered and **task lists** (`- [ ]` / `- [x]`), with nesting
  - Fenced code blocks (```` ``` ```` and `~~~`), with horizontal scroll —
    **syntax-highlighted** in md's own quiet paper palette when the fence
    names a language (`swift`, `js`, …); a bare fence stays plain
  - Block quotes (including nested)
  - GitHub-style tables, with column alignment
  - **CSV / TSV blocks** (` ```csv `, ` ```tsv `) — data pasted straight
    out of a spreadsheet drawn as a table, quoted fields and all, with
    all-number columns lined up on the right; the source stays the data,
    so it can be replaced wholesale when the numbers change
  - Thematic breaks (`---`)
  - YAML / TOML **front matter** (`---` … `---` or `+++` … `+++`) at the
    very top of a file — recognised as metadata and hidden from the page,
    print and PDF, instead of showing up as a rule and stray text
  - **Footnotes** (`[^id]` in the text, `[^id]: the note` on a line of its
    own) — gathered under a rule at the foot of the rendered page and
    numbered in the order a reader meets them, each reference linking down
    to its note and each cited note linking back
- **Math and diagrams.** TeX/LaTeX math (`$…$`, `$$…$$` and ` ```math `) —
  with **chemistry** notation (`\ce{…}` / `\pu{…}`) via the bundled mhchem
  extension — plus **Mermaid** (` ```mermaid `), **Graphviz** (` ```dot `, ` ```graphviz `
  or ` ```gv `, and every layout program — `neato`, `circo`, `fdp`, `sfdp`,
  `twopi`, `osage`, `patchwork` — usable as the block language) and
  **PlantUML** (` ```plantuml `), all drawn on-device by the vendored
  engines and carried through to print and PDF. A raw `.puml` or `.gv` file
  opens and renders as the diagram it describes, source still editable.
- **Three layouts.** *Edit*, *Split* (side by side, re-rendering as you
  type) and *Preview*, chosen with a segmented control in the window
  toolbar. The layout is remembered per window.
- **Typewriter feel.** Warm paper background (light "fresh paper" / dark
  "carbon paper") and the American Typewriter face throughout, with
  Courier New for code.
- **Editing you'd expect.** A plain, undo-aware `NSTextView` editor driven
  by the standard **Edit ▸ Undo / Redo**, continuous autosave through the
  document architecture, and Markdown punctuation left literal (no
  smart-quote / dash surprises).
- **Print & share.** Print or share the *rendered* document as a themed
  PDF (matching light / dark) — at A4, A5, US Letter or Legal, or a
  print-on-demand trim size (6 × 9″, 5 × 8″, 5.5 × 8.5″), the choice
  remembered and applied to the book compile too — export it as one
  self-contained `.html` file that opens anywhere with nothing beside it
  (diagrams as drawings, formulas as selectable text), export it as an
  **EPUB** e-book with the document's own headings as its table of
  contents, export it as LaTeX `.tex` source (formulas as the `$…$` you
  typed rather than a picture of them, ready to paste into a paper), export
  a single **diagram** (Mermaid, Graphviz or PlantUML — math is HTML text,
  not a drawing, so it isn't offered) as a standalone `.svg` vector file,
  export the document as a **TextBundle** with any local images it
  references gathered into the bundle's `assets/`, or share the raw Markdown
  source — from the toolbar or from **File ▸ Print… (⌘P)**, the File menu's
  Export commands and the Share commands.
- **Light / dark and text selection** throughout. The app is sandboxed and
  makes no network connections.

## Platforms

- macOS **14 (Sonoma) or later**

## Build

Pure Apple system frameworks — nothing to resolve, just open and build.

```bash
# Run the unit tests
xcodebuild test  -project md.xcodeproj -scheme md \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# Build the app
xcodebuild build -project md.xcodeproj -scheme md \
  -destination 'platform=macOS'
```

The build number (`CFBundleVersion`) auto-increments on every build via a
scheme post-action running `agvtool bump`.

## License

MIT — see [LICENSE](LICENSE). © 2026 nettrash.
