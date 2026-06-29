# md for macOS

[![build](https://github.com/nettrash/md.macOS/actions/workflows/macos.yml/badge.svg)](https://github.com/nettrash/md.macOS/actions/workflows/macos.yml)

The simplest Markdown editor for the Mac. Write Markdown on the left, see
it rendered on the right — or switch to a full-window **Edit** or
**Preview**. Built in SwiftUI on top of the native `NSDocument` document
architecture, with a hand-written Markdown renderer. **No third-party
dependencies, no accounts, no servers** — your files live wherever you
keep them (on disk, or in iCloud Drive).

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
  Plain-text files open too and keep their extension.
- **Live preview.** A built-in renderer covers the everyday Markdown you
  actually write:
  - Headings (`#`–`######`)
  - **Bold**, *italic*, `inline code`, [links](https://nettrash.me) and
    ~~strikethrough~~ (via Apple's own inline Markdown engine)
  - Bullet, numbered and **task lists** (`- [ ]` / `- [x]`), with nesting
  - Fenced code blocks (```` ``` ```` and `~~~`), with horizontal scroll
  - Block quotes (including nested)
  - GitHub-style tables, with column alignment
  - Thematic breaks (`---`)
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
  PDF (matching light / dark), or share the raw Markdown source — from the
  toolbar or from **File ▸ Print… (⌘P)** and the Share commands.
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

MIT — see [LICENSE](LICENSE). © 2026 nettrash (Ivan Alekseev).
