# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The build number (`CFBundleVersion`) is auto-incremented on every build by
a scheme post-action (`agvtool bump`) and is not tracked here.

## [1.2] — Unreleased

### Added

- **Export as PDF.** A dedicated "Export as PDF…" action — in the share menu
  and in the File menu — renders the document and saves the PDF through the
  standard save panel, alongside the existing share flow.
- **Table of contents.** A "Contents" menu in the toolbar lists every heading
  in the document; choosing one jumps the preview — and the editor — straight
  to it. Headings now carry GitHub-style anchors, so `[…](#section)` links
  navigate inside the document too.
- **Page breaks.** Write `\newpage` (or `\pagebreak`) on its own line — the
  Pandoc convention — to end a page where *you* decide: the shared / exported
  PDF becomes one content-tall page per section (still nothing sliced
  mid-line), printing breaks there, and the preview shows a subtle dashed
  rule.
- **Private author notes.** `<!-- note: … -->` comments are the writer's
  working notes: a new "Notes" toolbar menu lists them and jumps to them in
  the editor, and they never appear in the preview, the PDF, or print.
  (Other HTML comments are now dropped from the rendered output as well.)
- **Writer mode: books.** Create a book from scratch (File ▸ New Book… — one
  save panel names it and chooses where it lives) or open an existing folder
  as one (File ▸ Open Book…), also from the new "Book" toolbar menu: its
  subfolders are chapters, its Markdown files are articles, ordered by
  numeric filename prefix ("01-intro.md") and then alphabetically. The book
  window (File ▸ Show Book, ⇧⌘B) opens any article and creates new chapters
  and articles in place; the book is remembered across launches.
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
- **PDF Layout setting.** Choose how PDFs are built, in the File menu and
  the share menu: "One long page" (the continuous, nothing-sliced page —
  still the default) or "A4 pages" — real A4 pagination with line-aware
  page breaks, produced by the same engine as printing, honouring
  `\newpage`.
- **Export a book as EPUB.** "Export as EPUB…" packages the book as a
  standard EPUB 3 — chapters and articles in reading order with a proper
  table of contents — that opens in Apple Books and other readers. Math
  formulas and Mermaid / PlantUML diagrams are rendered by the app's own
  offline engines and embedded as images, so they display in any reader.

### Changed

- Printed and exported documents now use a smaller body size (11 pt, down
  from 13 pt) — standard print typography that fits more of the document per
  page — and long code lines wrap instead of being clipped at the code
  block's edge (on screen they scroll; paper can't). The on-screen preview
  is unchanged.

### Fixed

- **Shared PDFs no longer cut lines.** "Share Rendered PDF" (and the new
  export) now produces a single continuous page exactly as tall as the
  rendered document — the whole page as you see it in the app — so no line of
  text or diagram is ever sliced at an A4 page boundary. Documents that
  render taller than the PDF format's 14,400 pt (200-inch) page cap are
  scaled down uniformly so the export is still one complete page rather than
  being clipped at the cap. Printing still paginates to real paper,
  unchanged.

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
