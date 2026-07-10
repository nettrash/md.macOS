//
//  DocumentView.swift
//  md
//
//  Created by nettrash on 29/06/2026.
//
//  The content of one document window: a raw-Markdown editor and a live
//  rendered preview, with a mode switch in the window toolbar. macOS always
//  has room, so all three modes are available — Edit, Split (side by side,
//  re-rendering as you type) and Preview. The chosen mode is remembered per
//  window via `@SceneStorage`, so two open document windows can each keep
//  their own layout.
//
//  The whole window wears the typewriter theme — warm paper behind both
//  panes, American Typewriter type — and the toolbar carries the mode
//  switch (a native segmented control), the Contents / Notes navigation
//  menus, the Book menu (writer mode, see `BookNavigator`) and a share /
//  print menu. Undo / Redo aren't in the toolbar: macOS has a menu bar, so
//  the standard Edit ▸ Undo / Redo drive the editor's `NSTextView` natively.
//
//  Contents / Notes navigate via one-shot requests: choosing an entry
//  bumps a small `@State` value (a fresh UUID plus the target), and the
//  visible pane(s) consume each request exactly once by its id — the
//  preview scrolls to the heading's anchor, the editor puts the caret on
//  the source line.
//
//  The window also publishes its document to the menu bar via
//  `focusedSceneValue`, so File ▸ Print… and the Share commands act on the
//  frontmost window (see `mdApp.swift`).
//

import SwiftUI

struct DocumentView: View {
    @Binding var document: MarkdownDocument
    /// The document's file URL, when it has been saved. Used to name the
    /// shared / exported files and the print job, and to share the real
    /// source file. `nil` for a brand-new, never-saved document. The title
    /// bar's name / folder / rename is handled natively by `DocumentGroup`.
    let fileURL: URL?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// Per-window mode preference (SceneStorage, not AppStorage, so each
    /// document window keeps its own layout).
    @SceneStorage("md.viewMode") private var storedMode = Mode.split.rawValue
    /// The stored book bookmark (see `BookLibrary`), observed only so the
    /// Book menu's Close item tracks whether a book is currently open.
    @AppStorage(BookLibrary.bookmarkKey) private var bookBookmark = ""
    /// The app-wide PDF layout preference (see `PDFLayout`), mirrored in
    /// the File menu.
    @AppStorage(PDFLayout.storageKey) private var pdfLayout = PDFLayout.single.rawValue

    /// One-shot navigation requests bumped by the Contents / Notes menus.
    /// Each pane consumes a request exactly once by its id and reports back,
    /// and the request is then cleared here — it must not linger in state,
    /// or a pane recreated after a mode round-trip (whose dedupe died with
    /// it) would replay the old jump.
    @State private var previewNavigation: PreviewNavigation?
    @State private var editorJump: EditorJump?

    enum Mode: String, CaseIterable, Identifiable {
        case edit, split, preview
        var id: String { rawValue }
        var label: String {
            switch self {
            case .edit: return "Edit"
            case .split: return "Split"
            case .preview: return "Preview"
            }
        }
        var symbol: String {
            switch self {
            case .edit: return "square.and.pencil"
            case .split: return "rectangle.split.2x1"
            case .preview: return "eye"
            }
        }
    }

    /// The mode actually shown: the stored preference, defaulting to Split.
    private var effectiveMode: Mode { Mode(rawValue: storedMode) ?? .split }

    /// Base name used for export / print filenames and the print job.
    private var baseName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    var body: some View {
        content
            .background(Typewriter.paper.ignoresSafeArea())
            .frame(minWidth: 480, minHeight: 320)
            .toolbar { toolbarContent }
            // Hand the frontmost document to the menu-bar commands so
            // File ▸ Print… / Share… act on it (see `DocumentCommands`).
            .focusedSceneValue(\.activeDocument,
                               ActiveDocument(text: document.text,
                                              title: baseName,
                                              fileURL: fileURL,
                                              dark: colorScheme == .dark))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Mode switch — a native segmented control, the Mac idiom.
        ToolbarItem(placement: .principal) {
            Picker("View Mode", selection: modeBinding) {
                ForEach(Mode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Switch between editing, split and preview")
        }

        // Contents — jump to any heading. Recomputing the outline on every
        // toolbar refresh is fine: the parser's outline pass is
        // line-oriented and cheap by design.
        ToolbarItem(placement: .primaryAction) {
            let outline = MarkdownParser.outline(document.text)
            Menu {
                ForEach(outline, id: \.line) { entry in
                    Button {
                        jump(to: entry)
                    } label: {
                        // Two spaces of indent per heading level mirror the
                        // document's hierarchy inside the flat menu.
                        Text(String(repeating: "  ", count: max(0, entry.level - 1)) + entry.text)
                    }
                }
            } label: {
                Label("Contents", systemImage: "list.bullet")
            }
            .menuIndicator(.hidden)
            .disabled(outline.isEmpty)
            .help("Jump to a heading")
        }

        // Notes — the writer's private `<!-- note: … -->` comments. They
        // exist only in the source (never in the rendered output), so a
        // note always jumps the *editor*.
        ToolbarItem(placement: .primaryAction) {
            let notes = MarkdownParser.notes(document.text)
            Menu {
                ForEach(notes, id: \.line) { note in
                    Button {
                        jump(to: note)
                    } label: {
                        Text(Self.notePreview(note.text))
                    }
                }
            } label: {
                Label("Notes", systemImage: "note.text")
            }
            .menuIndicator(.hidden)
            .disabled(notes.isEmpty)
            .help("Jump to a private author note")
        }

        // Book (writer mode) — mirrors the File-menu commands so the
        // feature is discoverable from the toolbar. The book is app-wide
        // state, not part of this document (see `BookNavigator`).
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New Book…") {
                    if BookLibrary.newBook() { openWindow(id: BookLibrary.windowID) }
                }
                Button("Open Book…") {
                    if BookLibrary.chooseBook() { openWindow(id: BookLibrary.windowID) }
                }
                Button("Show Book") {
                    openWindow(id: BookLibrary.windowID)
                }
                Divider()
                Button("Close Book") {
                    // Forget the bookmark and take the navigator window
                    // down with it.
                    BookLibrary.closeBook()
                    dismissWindow(id: BookLibrary.windowID)
                }
                .disabled(bookBookmark.isEmpty)
            } label: {
                Label("Book", systemImage: "books.vertical")
            }
            .menuIndicator(.hidden)
            .help("Open a folder of chapters and articles as a book")
        }

        // Share / export / print.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    DocumentExport.shareSource(fileURL: fileURL, text: document.text, title: baseName)
                } label: {
                    Label("Share Source…", systemImage: "doc.plaintext")
                }
                Button {
                    Task { await DocumentExport.sharePDF(source: document.text, title: baseName,
                                                         dark: colorScheme == .dark) }
                } label: {
                    Label("Share Rendered PDF…", systemImage: "doc.richtext")
                }
                Button {
                    Task { await DocumentExport.exportPDF(source: document.text, title: baseName,
                                                          dark: colorScheme == .dark) }
                } label: {
                    Label("Export as PDF…", systemImage: "square.and.arrow.down")
                }
                Divider()
                // The app-wide layout the two PDF actions above honor —
                // mirrored in the File menu, like the actions themselves.
                Picker("PDF Layout", selection: $pdfLayout) {
                    ForEach(PDFLayout.allCases) { layout in
                        Text(layout.label).tag(layout.rawValue)
                    }
                }
                Divider()
                Button {
                    Task { await DocumentExport.print(source: document.text, title: baseName,
                                                      dark: colorScheme == .dark) }
                } label: {
                    Label("Print…", systemImage: "printer")
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .help("Share or print the document")
        }
    }

    // MARK: - Panes

    @ViewBuilder
    private var content: some View {
        switch effectiveMode {
        case .edit:
            editorPane
        case .preview:
            previewPane
        case .split:
            // Side by side when there's room; if the window is dragged
            // narrow, stack the panes vertically rather than cramping two
            // unusable columns.
            GeometryReader { geo in
                if geo.size.width >= 640 {
                    HStack(spacing: 0) {
                        editorPane
                        Divider()
                        previewPane
                    }
                } else {
                    VStack(spacing: 0) {
                        editorPane
                        Divider()
                        previewPane
                    }
                }
            }
        }
    }

    /// Binds the segmented control to the persisted mode.
    private var modeBinding: Binding<Mode> {
        Binding(get: { effectiveMode }, set: { storedMode = $0.rawValue })
    }

    private var editorPane: some View {
        // Clear a performed jump out of state (guarded by id, in case a
        // newer request already replaced it): the pane's own dedupe dies
        // with the pane, so a request left in `@State` would replay into a
        // recreated editor after an Edit → Preview → Edit round-trip.
        MarkdownEditor(text: $document.text, jump: editorJump) { handled in
            if editorJump?.id == handled { editorJump = nil }
        }
            .overlay(alignment: .topLeading) {
                if document.text.isEmpty {
                    // The text view has no native placeholder; mimic one,
                    // aligned to its content inset.
                    Text("# Start writing…")
                        .font(Typewriter.font(15))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 16)
                        .padding(.leading, 16)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewPane: some View {
        // The rendered preview is a WebView showing the same themed HTML as
        // print / share, so LaTeX math, Mermaid and PlantUML render (offline).
        // It scrolls and lays out internally (see the CSS in MarkdownHTML).
        // The performed-navigation clearing mirrors the editor pane's — see
        // the comment there.
        MarkdownWebView(text: document.text, title: baseName,
                        navigation: previewNavigation) { handled in
            if previewNavigation?.id == handled { previewNavigation = nil }
        }
    }

    // MARK: - Navigation (Contents / Notes)

    /// Jump to a heading: whichever panes are visible follow it. In Split
    /// both move; Edit-only moves just the caret, and Preview-only stays in
    /// preview — a reader browsing the rendered document shouldn't be
    /// dropped into the source.
    private func jump(to entry: OutlineEntry) {
        if effectiveMode != .edit {
            previewNavigation = PreviewNavigation(id: UUID(), slug: entry.slug)
        }
        if effectiveMode != .preview {
            editorJump = EditorJump(id: UUID(), line: entry.line)
        }
    }

    /// Jump to a note. Notes never render, so the target is always the
    /// editor — leaving preview-only mode first when necessary.
    private func jump(to note: NoteEntry) {
        if effectiveMode == .preview { storedMode = Mode.edit.rawValue }
        editorJump = EditorJump(id: UUID(), line: note.line)
    }

    /// A menu-sized note preview: first line only, whitespace collapsed,
    /// capped at ~50 characters so one long note can't dwarf the menu.
    private static func notePreview(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return "(empty note)" }
        guard collapsed.count > 50 else { return collapsed }
        return collapsed.prefix(50).trimmingCharacters(in: .whitespaces) + "…"
    }
}
