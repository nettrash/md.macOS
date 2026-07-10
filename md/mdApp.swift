//
//  mdApp.swift
//  md
//
//  Created by nettrash on 29/06/2026.
//
//  A document-based Markdown editor + live previewer for macOS. The whole
//  app is a single `DocumentGroup` over `MarkdownDocument`: on macOS that
//  is a real `NSDocument`-backed document app, so the system gives us the
//  document window, open / save / autosave, iCloud Drive, File ▸ New, and —
//  natively and correctly — the title-bar proxy menu's Rename, Move To and
//  Duplicate. (This is exactly what a Mac Catalyst `DocumentGroup` could
//  not do, which is why the Mac build is a dedicated native target rather
//  than a Catalyst port of the iOS app.)
//
//  The menu bar adds first-class File ▸ Print… (⌘P) and Share commands that
//  act on the frontmost document window, routed through the
//  `ActiveDocument` focused value the window publishes.
//
//  A second, auxiliary `Window` scene hosts the book navigator (writer
//  mode, see `BookNavigator`): one app-wide window, opened on demand via
//  File ▸ New Book… / Open Book… / Show Book (⇧⌘B) or the Book toolbar
//  menu.
//
//  File ▸ Examples lists the sample documents bundled with the app (see
//  `ExampleLibrary`); each opens as a fresh untitled document, and the
//  submenu's Example Book… item unpacks a ready-made book folder.
//

import SwiftUI
import AppKit

@main
struct mdApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            // Pass the file URL only so exports / the print job can be named
            // after the document and the source file can be shared directly.
            // The title bar (filename, folder, rename) is managed natively
            // by DocumentGroup.
            DocumentView(document: file.$document, fileURL: file.fileURL)
        }
        .defaultSize(width: 900, height: 640)
        .commands { DocumentCommands() }

        // The book navigator (writer mode) lives in its own single
        // auxiliary window shared by the whole app: a book spans many
        // documents, so it is deliberately not per-document UI.
        Window("Book", id: BookLibrary.windowID) {
            BookNavigator()
        }
        .defaultSize(width: 320, height: 520)
    }
}

// MARK: - Frontmost document, for the menu bar

/// A snapshot of the frontmost document window, published via
/// `focusedSceneValue` so the menu-bar commands can act on it. Captures
/// everything the export actions need — including the current appearance,
/// so a printed / shared PDF matches what's on screen.
struct ActiveDocument: Equatable {
    let text: String
    let title: String
    let fileURL: URL?
    let dark: Bool
}

private struct ActiveDocumentKey: FocusedValueKey {
    typealias Value = ActiveDocument
}

extension FocusedValues {
    var activeDocument: ActiveDocument? {
        get { self[ActiveDocumentKey.self] }
        set { self[ActiveDocumentKey.self] = newValue }
    }
}

// MARK: - Bundled examples

/// The sample documents shipped in the app bundle (the `Examples` folder
/// reference — see also `BookLibrary.unpackExampleBook` for the book it
/// carries). Each example opens as a fresh untitled document, so the reader
/// can edit freely and save the result anywhere — or just close it.
enum ExampleLibrary {

    /// One bundled example file. Identity is the bundle URL.
    struct Example: Identifiable {
        let url: URL
        var id: URL { url }
        /// Display name: the file name without its extension or its
        /// ordering prefix ("01-Welcome" → "Welcome"). The number fixes
        /// the menu order — the files list by name — but is noise to read.
        var name: String {
            let base = url.deletingPathExtension().lastPathComponent
            let digits = base.prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty, base[digits.endIndex...].first == "-" else { return base }
            let rest = base[base.index(after: digits.endIndex)...]
            return rest.isEmpty ? base : String(rest)
        }
    }

    /// The example files at the top level of the bundled folder, in menu
    /// order (by file name — see `Example.name`). The example book's
    /// articles live in a subfolder and deliberately aren't listed here:
    /// the book unpacks whole via Example Book….
    static var all: [Example] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "md",
                                    subdirectory: "Examples") ?? []
        return urls
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(Example.init)
    }

    /// Open `example` as a new untitled document, pre-filled with the
    /// example's text. `newDocument` is the environment's document-creation
    /// action, passed in because only views and commands can read it.
    @MainActor
    static func open(_ example: Example, using newDocument: NewDocumentAction) {
        // A bundled resource only fails to read on a corrupt install;
        // there is nothing sensible to report, so fail quietly.
        guard let text = try? String(contentsOf: example.url, encoding: .utf8) else { return }
        // Snapshot the open documents first, so the one the action creates
        // can be recognised below.
        let before = Set(NSDocumentController.shared.documents.map(ObjectIdentifier.init))
        newDocument(MarkdownDocument(text: text))
        // The text arrived at init time, bypassing the editing path that
        // bumps the change count — and an untitled window that doesn't
        // count as edited would close without ever offering to save the
        // example. Nudge the new document once it is registered (the next
        // run-loop turn).
        DispatchQueue.main.async {
            for document in NSDocumentController.shared.documents
            where document.fileURL == nil && !before.contains(ObjectIdentifier(document)) {
                document.updateChangeCount(.changeDone)
            }
        }
    }
}

/// File-menu commands that mirror the toolbar's share / print menu, so they
/// also have keyboard shortcuts and a home in the menu bar. They operate on
/// whichever document window is frontmost (`activeDocument`), and are
/// disabled when no document window has focus.
struct DocumentCommands: Commands {
    @FocusedValue(\.activeDocument) private var document
    /// Opening scenes is an app-level action the environment provides even
    /// inside menu commands — how the book commands reach their window.
    @Environment(\.openWindow) private var openWindow
    /// Creating documents is likewise an environment action — how the
    /// Examples menu opens an example as a fresh untitled document.
    @Environment(\.newDocument) private var newDocument
    /// The app-wide PDF layout preference (see `PDFLayout`), mirrored in
    /// the share toolbar menu.
    @AppStorage(PDFLayout.storageKey) private var pdfLayout = PDFLayout.single.rawValue

    var body: some Commands {
        // Writer mode: the book commands are app-wide — a book outlives any
        // one document window — so unlike the share / print commands below
        // they are *not* tied to `activeDocument` and are never disabled.
        // The same goes for the examples: they need no open document.
        CommandGroup(after: .newItem) {
            Menu("Examples") {
                ForEach(ExampleLibrary.all) { example in
                    Button(example.name) {
                        ExampleLibrary.open(example, using: newDocument)
                    }
                }
                Divider()
                Button("Example Book…") {
                    if BookLibrary.unpackExampleBook() { openWindow(id: BookLibrary.windowID) }
                }
            }
            Divider()
            Button("New Book…") {
                if BookLibrary.newBook() { openWindow(id: BookLibrary.windowID) }
            }
            Button("Open Book…") {
                if BookLibrary.chooseBook() { openWindow(id: BookLibrary.windowID) }
            }
            Button("Show Book") {
                openWindow(id: BookLibrary.windowID)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
        }

        // Replace the default (view-printing) Print item with one that
        // prints the themed, rendered document.
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                if let document {
                    Task { await DocumentExport.print(source: document.text,
                                                      title: document.title,
                                                      dark: document.dark) }
                }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(document == nil)
        }

        CommandGroup(after: .saveItem) {
            Divider()
            Button("Share Source…") {
                if let document {
                    DocumentExport.shareSource(fileURL: document.fileURL,
                                               text: document.text,
                                               title: document.title)
                }
            }
            .disabled(document == nil)

            Button("Share Rendered PDF…") {
                if let document {
                    Task { await DocumentExport.sharePDF(source: document.text,
                                                         title: document.title,
                                                         dark: document.dark) }
                }
            }
            .disabled(document == nil)

            Button("Export as PDF…") {
                if let document {
                    Task { await DocumentExport.exportPDF(source: document.text,
                                                          title: document.title,
                                                          dark: document.dark) }
                }
            }
            .disabled(document == nil)

            Divider()
            // An app-wide setting rather than a per-document command, but
            // it lives here, next to the PDF actions it shapes.
            Picker("PDF Layout", selection: $pdfLayout) {
                ForEach(PDFLayout.allCases) { layout in
                    Text(layout.label).tag(layout.rawValue)
                }
            }
        }
    }
}
