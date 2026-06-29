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

import SwiftUI

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

/// File-menu commands that mirror the toolbar's share / print menu, so they
/// also have keyboard shortcuts and a home in the menu bar. They operate on
/// whichever document window is frontmost (`activeDocument`), and are
/// disabled when no document window has focus.
struct DocumentCommands: Commands {
    @FocusedValue(\.activeDocument) private var document

    var body: some Commands {
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
        }
    }
}
