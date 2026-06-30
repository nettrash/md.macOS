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
//  switch (a native segmented control) and a share / print menu. Undo /
//  Redo aren't in the toolbar: macOS has a menu bar, so the standard
//  Edit ▸ Undo / Redo drive the editor's `NSTextView` natively.
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
    /// Per-window mode preference (SceneStorage, not AppStorage, so each
    /// document window keeps its own layout).
    @SceneStorage("md.viewMode") private var storedMode = Mode.split.rawValue

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
        MarkdownEditor(text: $document.text)
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
        ScrollView {
            MarkdownView(document.text)
                .padding(.horizontal)
                .padding(.vertical, 16)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
