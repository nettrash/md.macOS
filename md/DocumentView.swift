//
//  DocumentView.swift
//  md
//
//  Created by nettrash on 29/06/2026.
//
//  The content of one document window: a raw-Markdown editor and a live
//  rendered preview, with a footer counting the author's words and
//  characters. macOS always has room, so all three modes are available —
//  Edit, Split (side by side, re-rendering as you type) and Preview. The
//  chosen mode is remembered per window via `@SceneStorage`, so two open
//  document windows can each keep their own layout.
//
//  The whole window wears the typewriter theme — warm paper behind both
//  panes, American Typewriter type — and deliberately carries NO toolbar:
//  macOS has a menu bar, and everything lives there. View ▸ Edit / Split /
//  Preview (⌘1/⌘2/⌘3) switch the mode, the Go menu jumps to headings and
//  private notes, File carries the book, share and print commands, and the
//  standard Edit ▸ Undo / Redo drive the editor's `NSTextView` natively.
//
//  Contents / Notes navigate via one-shot requests: choosing an entry
//  bumps a small `@State` value (a fresh UUID plus the target), and the
//  visible pane(s) consume each request exactly once by its id — the
//  preview scrolls to the heading's anchor, the editor puts the caret on
//  the source line.
//
//  The window feeds the menu bar via `focusedSceneValue`: the document
//  itself (File ▸ Print… / Share…), the mode switch (View menu), and its
//  outline and notes (the Go menu) — see `mdApp.swift`.
//

import SwiftUI

// MARK: - Split-view scroll sync

/// Links the two panes of a Split view so they scroll as one: each pane
/// reports the fraction of its scrollable range it sits at, and the other
/// follows. Proportional, not line-mapped — the panes' heights diverge
/// around tall rendered content (a diagram is one source line), but the
/// neighborhood always matches, which is what side-by-side writing needs.
///
/// A plain class, deliberately not observable: scroll events arrive at
/// display rate and must never re-render SwiftUI views. Each pane's
/// coordinator registers its "follow" closure here and calls the opposite
/// report method; echo suppression lives inside the panes (the editor
/// brackets programmatic scrolls with a flag, the preview timestamps them
/// in JS), so a relayed scroll never relays back.
@MainActor
final class ScrollSync {
    /// Set by the editor pane: scroll the editor to a fraction [0, 1].
    var scrollEditor: ((CGFloat) -> Void)?
    /// Set by the preview pane: scroll the preview to a fraction [0, 1].
    var scrollPreview: ((CGFloat) -> Void)?

    func editorDidScroll(to fraction: CGFloat) {
        scrollPreview?(fraction)
    }

    func previewDidScroll(to fraction: CGFloat) {
        scrollEditor?(fraction)
    }
}

struct DocumentView: View {
    @Binding var document: MarkdownDocument
    /// The document's file URL, when it has been saved. Used to name the
    /// shared / exported files and the print job, and to share the real
    /// source file. `nil` for a brand-new, never-saved document. The title
    /// bar's name / folder / rename is handled natively by `DocumentGroup`.
    let fileURL: URL?

    @Environment(\.colorScheme) private var colorScheme
    /// Per-window mode preference (SceneStorage, not AppStorage, so each
    /// document window keeps its own layout).
    @SceneStorage("md.viewMode") private var storedMode = Mode.split.rawValue

    /// One-shot navigation requests bumped by the Contents / Notes menus.
    /// Each pane consumes a request exactly once by its id and reports back,
    /// and the request is then cleared here — it must not linger in state,
    /// or a pane recreated after a mode round-trip (whose dedupe died with
    /// it) would replay the old jump.
    @State private var previewNavigation: PreviewNavigation?
    @State private var editorJump: EditorJump?

    /// The footer's counters and the Go menu's outline / notes, cached off
    /// the per-keystroke `body` path (see `DerivedText`).
    @State private var derived = DerivedText()

    /// Links the panes' scrolling in Split (identity-stable across
    /// renders; the panes register themselves on it).
    @State private var scrollSync = ScrollSync()

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
        /// The View-menu shortcut digit (⌘1 / ⌘2 / ⌘3), in `allCases`
        /// order.
        var commandKey: String {
            switch self {
            case .edit: return "1"
            case .split: return "2"
            case .preview: return "3"
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
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
            .background(Typewriter.paper.ignoresSafeArea())
            .frame(minWidth: 480, minHeight: 320)
            .fullScreenCapable()
            // Hand the frontmost document to the menu-bar commands so
            // File ▸ Print… / Share… act on it (see `DocumentCommands`).
            .focusedSceneValue(\.activeDocument,
                               ActiveDocument(text: document.text,
                                              title: baseName,
                                              fileURL: fileURL,
                                              dark: colorScheme == .dark))
            // …the mode switch, so the View-menu ⌘1/⌘2/⌘3 drive it…
            .focusedSceneValue(\.viewModeSelection,
                               ViewModeSelection(mode: effectiveMode,
                                                 select: { storedMode = $0.rawValue }))
            // …and the outline and notes, for the Go menu.
            .focusedSceneValue(\.documentNavigation,
                               DocumentNavigation(outline: derived.outline,
                                                  notes: derived.notes,
                                                  jumpToHeading: { jump(to: $0) },
                                                  jumpToNote: { jump(to: $0) }))
            // Recompute the derived values once per typing pause — the
            // task restarts (cancelling the sleeping one) on every change.
            .task(id: document.text) {
                derived = await derived.refreshed(from: document.text)
            }
    }

    /// The author's counters, book-workspace style: live words and
    /// characters, tucked under the panes.
    private var footer: some View {
        HStack {
            Spacer()
            Text("\(derived.words) words · \(derived.characters) characters")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(Typewriter.font(11))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Typewriter.paperSecondary)
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

    private var editorPane: some View {
        // Clear a performed jump out of state (guarded by id, in case a
        // newer request already replaced it): the pane's own dedupe dies
        // with the pane, so a request left in `@State` would replay into a
        // recreated editor after an Edit → Preview → Edit round-trip.
        MarkdownEditor(text: $document.text, jump: editorJump,
                       onJumpHandled: { handled in
                           if editorJump?.id == handled { editorJump = nil }
                       },
                       scrollSync: scrollSync)
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
                        navigation: previewNavigation,
                        onNavigationHandled: { handled in
                            if previewNavigation?.id == handled { previewNavigation = nil }
                        },
                        scrollSync: scrollSync)
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
    /// Internal: the book workspace's Notes menu shows the same previews.
    static func notePreview(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return "(empty note)" }
        guard collapsed.count > 50 else { return collapsed }
        return collapsed.prefix(50).trimmingCharacters(in: .whitespaces) + "…"
    }
}
