# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The build number (`CFBundleVersion`) is auto-incremented on every build by
a scheme post-action (`agvtool bump`) and is not tracked here.

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
