# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The build number (`CFBundleVersion`) is auto-incremented on every build by
a scheme post-action (`agvtool bump`) and is not tracked here.

## [1.3] — 2026-07-23

### Added

- **Open PlantUML files.** `.puml` (and `.plantuml`) documents now open in
  md — from File ▸ Open, the Finder's "Open With", or a double-click. A file
  that is a raw PlantUML diagram (`@startuml … @enduml`, with no code fence)
  renders as the diagram in the preview, print and exported PDF, while the
  source stays fully editable and saves as plain UTF-8 text.

## [1.2] — 2026-07-14

### Added

- **Export as PDF.** A dedicated "Export as PDF…" action in the File menu
  renders the document and saves the PDF through the standard save panel,
  alongside the existing share flow.
- **Table of contents.** The new Go menu lists every heading in the
  document (in the book window, also from the toolbar); choosing one jumps
  the preview — and the editor — straight to it. Headings now carry
  GitHub-style anchors, so `[…](#section)` links navigate inside the
  document too.
- **Page breaks.** Write `\newpage` (or `\pagebreak`) on its own line — the
  Pandoc convention — to end a page where *you* decide: shared and exported
  PDFs and printouts start a fresh A4 page there, and the preview shows a
  subtle dashed rule.
- **Private author notes.** `<!-- note: … -->` comments are the writer's
  working notes: the Go menu's "Notes" lists them and jumps to them in
  the editor, and they never appear in the preview, the PDF, or print.
  (Other HTML comments are now dropped from the rendered output as well.)
- **Word and character count.** Every document window — and the book
  window's writing pane — shows the document's live word and character
  count in a footer under the page.
- **Synchronized scrolling in Split.** The editor and the preview scroll
  as one: move either pane and the other follows proportionally — in
  document windows and in the book workspace alike. Jumping to a heading
  from the Contents menu still lands each pane on its precise spot.
- **Writer mode: books.** Create a book from scratch (File ▸ New Book… — one
  save panel names it and chooses where it lives) or open an existing folder
  as one (File ▸ Open Book…): its subfolders are chapters, its Markdown
  files are articles, ordered by numeric filename prefix ("01-intro.md")
  and then alphabetically. The book window (File ▸ Show Book, ⇧⌘B) opens
  any article and creates new chapters and articles in place; the book is
  remembered across launches.
- **Images.** `![alt](url "title")` now renders in the preview, shared and
  exported PDFs, and print — including linked images (`[![…](…)](…)`).
  Links also honour an optional hover title. Images keep their original
  size, capped to the page width.
- **Built-in examples.** A new File ▸ Examples menu opens ready-made
  documents showing everything md can do — formatting, tables, code,
  images, math, diagrams, and the writer tools — each as a fresh untitled
  document of your own to explore and edit. "Example Book…" in the same
  menu unpacks a small sample book to a location you choose and opens it,
  so chapters and articles can be seen in action.
- **Book management.** Right-click any chapter or article in the Book
  window to Rename, Move Up / Move Down, or Delete it. Reordering is
  written back to the filenames — the whole group is renumbered with tidy
  "01-", "02-" prefixes — so the order is real, portable, and visible in
  Finder.
- **Compile a book to PDF.** The Book window's new share menu renders the
  entire book — a title page, then every chapter and article in reading
  order, each starting on a fresh page — through the same PDF pipeline as
  a single document, ready to share or save as "&lt;Book name&gt;.pdf".
- **Export a book as EPUB.** "Export as EPUB…" packages the book as a
  standard EPUB 3 — chapters and articles in reading order with a proper
  table of contents — that opens in Apple Books and other readers. Math
  formulas and Mermaid / PlantUML diagrams are rendered by the app's own
  offline engines and embedded as images, so they display in any reader.
- **The book window is now a writing workspace.** The book's structure sits
  in a compact sidebar and the selected article opens right there, in the
  same Edit / Split / Preview panes as a document window — with its own
  Contents and Notes menus, and a footer showing the article's word and
  character count. Everything autosaves as you write; take the window full
  screen (the green button, ⌃⌘F) for a distraction-free writing room with
  nothing on screen but the book. The workspace reopens on the article you
  last wrote in, a new article opens ready to write, and deleting one moves
  you to its neighbour.
- **Walk the book from the keyboard.** ⌃⌘↑ / ⌃⌘↓ (and toolbar chevrons)
  move to the previous / next article in reading order, and ⌘1 / ⌘2 / ⌘3 in
  the new View-menu commands switch Edit / Split / Preview — in the book
  window and in every document window alike.
- **The whole book, from the File menu.** Share Book as PDF, Export Book
  as PDF…, Export Book as EPUB… and the new Print Book… sit in the File
  menu whenever a book is open — from any window, so shipping the book
  never means leaving the page being written (the in-place editor saves
  itself first). The book window's share menu carries the same actions,
  Print… now included.
- **Articles in windows, if you prefer.** A toggle in the book window's
  share menu — "Open Articles in Separate Windows" — restores the previous
  behavior, where selecting an article opens it as its own document window.
  A double-click or the row's "Open in New Window" does the same on demand
  either way; while an article is open as a document window, that window
  owns the file and the book pane steps aside rather than fighting it over
  saves. If a file ever changes on disk beneath unsaved edits, nothing is
  clobbered silently: the workspace keeps both versions and asks.

### Changed

- **PDFs are real A4 pages.** Shared and exported PDFs come from the same
  engine as printing: A4 pages, paginated line-aware — no line of text or
  diagram sliced at a fold — with `\newpage` starting a fresh page. The
  earlier one-long-page layout (and the "PDF Layout" setting that chose
  between the two) is gone; the continuous page lives on where it belongs,
  in the on-screen preview.
- **Paper is white.** Printouts and PDFs no longer carry the on-screen
  paper tint — the tinted block ended mid-page against the white A4
  margins — and always use the light ink, even from a dark-mode window:
  the whole page is one color, the way a manuscript prints. The preview
  keeps its warm paper and dark theme on screen.
- **The document window lost its toolbar.** The menu bar is the chrome, as
  on a Mac it should be: View ▸ Edit / Split / Preview (⌘1/⌘2/⌘3) switches
  the layout, the new **Go** menu jumps through the book's articles
  (⌃⌘↑/↓) and the document's headings and private notes, and File carries
  the book, share, export and print commands (including the new Close
  Book). The book window keeps its workspace toolbar.
- Printed and exported documents now use a smaller body size (11 pt, down
  from 13 pt) — standard print typography that fits more of the document per
  page — and long code lines wrap instead of being clipped at the code
  block's edge (on screen they scroll; paper can't). The on-screen preview
  is unchanged.

### Fixed

- **Full screen works.** Document windows and the book window can now
  actually enter native full screen — the green button, View ▸ Enter Full
  Screen, fn-F. The windows never declared the capability, so the menu
  item sat permanently disabled and the green button only zoomed. Full
  screen on the book window is the distraction-free writing mode: nothing
  on screen but the book.
- **Legacy Cyrillic text files decode correctly.** A Windows-1251 file
  without a byte-order mark could be misread as UTF-16 — mojibake that the
  next autosave would have baked into the file. UTF-16 is now only detected
  by its BOM, so such files open (and round-trip) as the Cyrillic text they
  are.
- **Shared PDFs no longer cut lines.** "Share Rendered PDF" (and the new
  export) paginates with the print engine's line-aware page breaks, so no
  line of text or diagram is ever sliced through the middle at a page
  boundary — the break falls between lines, as printing always did.

## [1.1] — 2026-07-05

### Added

- **Math, Mermaid and PlantUML in the preview.** The rendered preview now draws
  TeX/LaTeX math — `$…$` inline and `$$…$$` display, plus ` ```math ` blocks,
  the way GitHub does — as well as **Mermaid** graphs (` ```mermaid `) and
  **PlantUML** diagrams (` ```plantuml `). Everything renders **on-device** from
  bundled engines: no network, no accounts, nothing leaves your device. The same
  rendering flows through to Print / Save-as-PDF and “share rendered”.

### Changed

- The rendered preview now uses the same HTML/WebKit rendering as Print / PDF /
  share (previously a separate native renderer), so the preview and the exported
  document are pixel-identical.

## [1.0] — 2026-06-29

### Added

- Initial release: a native macOS document-based Markdown editor + live
  previewer, built in SwiftUI on AppKit with no third-party dependencies.
  This is the Mac sibling of the iOS / iPadOS app
  [md](https://github.com/nettrash/md); the two share the Markdown parser,
  renderer and themed HTML export verbatim.
- `DocumentGroup` over a `MarkdownDocument` (`FileDocument`), backed by a
  real `NSDocument` on macOS: open, edit and save `.md` / `.markdown` files
  anywhere via the standard panels, with autosave, versions and the native
  title-bar **Rename / Move To / Duplicate / New**. Plain-text files open
  and round-trip with their original extension. Markdown is declared as an
  imported UTI (`net.daringfireball.markdown`).
- Hand-written block-level Markdown parser and SwiftUI renderer covering
  headings, paragraphs, bullet / ordered / task lists (with nesting),
  fenced code blocks (``` and `~~~`), block quotes (nested), GitHub
  tables with column alignment, and thematic breaks. Inline formatting
  (bold, italic, code, links, strikethrough) is rendered via Foundation's
  `AttributedString(markdown:)`.
- Edit / Split / Preview layout switch as a native segmented control in
  the window toolbar. Split shows the editor and preview side by side and
  re-renders live as you type (stacking vertically when the window is
  dragged narrow). The chosen layout is remembered per window.
- **Typewriter theme.** Warm paper background — "fresh paper" in light
  mode, "carbon paper" in dark — with the American Typewriter face across
  the editor and preview, and Courier New for code. Warm-amber
  `AccentColor` and `PaperBackground` / `PaperBackgroundSecondary` /
  `PaperInk` color sets, all with light and dark variants.
- **`NSTextView`-based editor.** Undo / Redo via the standard macOS
  **Edit** menu; "smart" quote / dash / text substitutions are turned off
  so Markdown punctuation stays literal; every keystroke flows to the
  document, so the system autosave keeps the file current as you type.
- **Print & share.** Print the rendered document and share it as a PDF,
  both rendered through WebKit so the typewriter styling and paper
  background follow the current appearance. The raw Markdown source can be
  shared too — the saved file itself when it exists, otherwise the current
  text. Available from the toolbar and from **File ▸ Print… (⌘P)** and the
  Share menu commands, routed to the frontmost document window.
- **Sandboxed, no network.** App Sandbox with user-selected file access
  only; the app makes no network connections and stores documents only
  where the user puts them.
- App icon: a cream American Typewriter "md" on a dark warm-brown gradient.
- Unit tests (38 cases) covering the Markdown parser — including regression
  coverage for setext headings, wrapped list items, `C#`-style headings,
  tab-indented lists and bounded block-quote nesting — plus the
  `MarkdownHTML` export.
