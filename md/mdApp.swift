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
//  The menu bar is the app's whole chrome — document windows carry no
//  toolbar. File ▸ Print… (⌘P) and the Share commands act on the frontmost
//  window through the `ActiveDocument` focused value it publishes; View ▸
//  Edit / Split / Preview (⌘1/⌘2/⌘3) drive its mode switch; Edit ▸ Typing
//  holds the two app-wide typing rules (continue lists and tables,
//  capitalize sentences — see `SmartTextView`); and the Go menu walks the
//  book's articles (⌃⌘↑/↓) and the frontmost document's headings and
//  private notes.
//
//  A second, auxiliary `Window` scene hosts the book window (writer mode,
//  see `BookNavigator`): one app-wide window, opened on demand via
//  File ▸ New Book… / Open Book… / Show Book (⇧⌘B).
//
//  File ▸ Examples lists the sample documents bundled with the app (see
//  `ExampleLibrary`); each opens as a fresh untitled document, and the
//  submenu's Example Book… item unpacks a ready-made book folder.
//

import SwiftUI
import AppKit

@main
struct mdApp: App {
    init() {
        #if DEBUG
        // The command-line observation harness (see `LaunchDiagnostics`):
        // inert unless launched with `-mdDiagCommands <file>`, and not
        // compiled into a Release build at all.
        LaunchDiagnostics.install()
        #endif
    }

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

        // The book window (writer mode) lives in its own single auxiliary
        // window shared by the whole app: a book spans many documents, so
        // it is deliberately not per-document UI. It is a full writing
        // workspace — structure sidebar plus an in-place editing pane (see
        // `BookNavigator` / `BookWorkspace`) — hence a working default
        // size, not a palette's; its native full screen is the
        // distraction-free writing mode.
        Window("Book", id: BookLibrary.windowID) {
            BookNavigator()
        }
        .defaultSize(width: 1000, height: 700)
        // Never the answer to a file md cannot open. SwiftUI hands an open
        // request the document group declines — a `.dot` file, or a
        // PlantUML spelling another app's declaration has left unassociated
        // — to the next scene that will take an external event, and a
        // `Window` takes them all by default: the book window popped up,
        // empty, in place of any word about the file. Declining every
        // external event here leaves the request to the document
        // architecture, which says what it could not open.
        .handlesExternalEvents(matching: [])
    }
}

// MARK: - Full screen capability

/// Marks the hosting window as a full-screen citizen. SwiftUI does not put
/// `.fullScreenPrimary` on the windows it creates here, which left the
/// system's View ▸ Enter Full Screen item permanently disabled and the
/// green button only zooming — verified against the running app. This
/// grafts the capability on as soon as the view lands in its window; the
/// system then supplies the whole feature (the menu item, the green
/// button, fn-F) on its own.
private struct FullScreenCapability: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Not attached to a window yet during make — defer one turn.
        DispatchQueue.main.async {
            view.window?.collectionBehavior.insert(.fullScreenPrimary)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.window?.collectionBehavior.insert(.fullScreenPrimary)
    }
}

extension View {
    /// The hosting window can go full screen (the green button, View ▸
    /// Enter Full Screen, fn-F). Applied to both window types: full screen
    /// is the book workspace's distraction-free writing mode, and a
    /// document window deserves it no less.
    func fullScreenCapable() -> some View {
        background(FullScreenCapability())
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

// MARK: - Frontmost view mode, for the View menu

/// The Edit / Split / Preview switch of the frontmost editing surface — a
/// document window or the book window's writing pane — published via
/// `focusedSceneValue` so the View-menu ⌘1/⌘2/⌘3 commands drive whichever
/// is in front. Equality is the mode alone: the closures just write the
/// publisher's own storage, and comparing them is neither possible nor
/// needed.
struct ViewModeSelection: Equatable {
    var mode: DocumentView.Mode
    let select: (DocumentView.Mode) -> Void
    /// Bring the editing pane on screen *without* recording a layout
    /// preference — the **navigation nudge** (`ViewModeRule.navigationNudge`)
    /// the Go ▸ Notes jump already uses, because a note is only visible in
    /// the source. Edit ▸ Find is the same situation: a match lives in the
    /// source too, so ⌘F in a preview-only window nudges the editor back
    /// rather than doing nothing at all. Transient, exactly like the jump's
    /// — choosing a mode for real ends it, and nothing is written to the
    /// per-file (or the book's) remembered layout.
    let showEditor: () -> Void
    static func == (a: Self, b: Self) -> Bool { a.mode == b.mode }
}

private struct ViewModeSelectionKey: FocusedValueKey {
    typealias Value = ViewModeSelection
}

extension FocusedValues {
    var viewModeSelection: ViewModeSelection? {
        get { self[ViewModeSelectionKey.self] }
        set { self[ViewModeSelectionKey.self] = newValue }
    }
}

/// The frontmost document window's Zen mode — full-screen, one centred
/// column, nothing else — for the View-menu toggle. `active` drives the
/// menu item's checkmark; `toggle` flips it. Published only by a document
/// window (not the book workspace), so the item is disabled elsewhere.
struct ZenModeCommand: Equatable {
    var active: Bool
    let toggle: () -> Void
    static func == (a: Self, b: Self) -> Bool { a.active == b.active }
}

private struct ZenModeCommandKey: FocusedValueKey {
    typealias Value = ZenModeCommand
}

extension FocusedValues {
    var zenMode: ZenModeCommand? {
        get { self[ZenModeCommandKey.self] }
        set { self[ZenModeCommandKey.self] = newValue }
    }
}

// MARK: - Document outline & notes, for the Go menu

// The parser's entry types live in the file shared verbatim with the iOS
// app, so their Equatable conformances (which only this platform's focused
// values need) are grafted on here — written out by hand, because synthesis
// is only available in the type's own file.
extension OutlineEntry: Equatable {
    static func == (a: OutlineEntry, b: OutlineEntry) -> Bool {
        a.level == b.level && a.text == b.text && a.slug == b.slug && a.line == b.line
    }
}

extension NoteEntry: Equatable {
    static func == (a: NoteEntry, b: NoteEntry) -> Bool {
        a.text == b.text && a.line == b.line
    }
}

/// The frontmost editing surface's headings and private notes, plus the
/// jumps that navigate to them — what the Go menu is made of. Published by
/// document windows and by the book window's writing pane. Equality is the
/// content: the closures just aim the publisher's own panes.
struct DocumentNavigation: Equatable {
    var outline: [OutlineEntry]
    var notes: [NoteEntry]
    let jumpToHeading: (OutlineEntry) -> Void
    let jumpToNote: (NoteEntry) -> Void
    static func == (a: Self, b: Self) -> Bool {
        a.outline == b.outline && a.notes == b.notes
    }
}

private struct DocumentNavigationKey: FocusedValueKey {
    typealias Value = DocumentNavigation
}

extension FocusedValues {
    var documentNavigation: DocumentNavigation? {
        get { self[DocumentNavigationKey.self] }
        set { self[DocumentNavigationKey.self] = newValue }
    }
}

// MARK: - Book article stepper, for the menu bar

/// Previous / Next Article over the book's reading order, published by the
/// book window so the ⌃⌘↑ / ⌃⌘↓ menu commands work while the writer's
/// hands stay on the keyboard — a toolbar-only shortcut would lose the
/// key-equivalent race against the focused text view. Equality is the two
/// can-flags: they are what the menu items' enabled state hangs on.
struct BookArticleStepper: Equatable {
    var canPrevious: Bool
    var canNext: Bool
    let previous: () -> Void
    let next: () -> Void
    static func == (a: Self, b: Self) -> Bool {
        a.canPrevious == b.canPrevious && a.canNext == b.canNext
    }
}

private struct BookArticleStepperKey: FocusedValueKey {
    typealias Value = BookArticleStepper
}

extension FocusedValues {
    var bookArticleStepper: BookArticleStepper? {
        get { self[BookArticleStepperKey.self] }
        set { self[BookArticleStepperKey.self] = newValue }
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
    /// The frontmost editing surface's mode switch (document window or the
    /// book's writing pane) — drives the View-menu ⌘1/⌘2/⌘3.
    @FocusedValue(\.viewModeSelection) private var viewMode
    /// The frontmost document window's Zen mode toggle (View ▸ Zen Mode).
    @FocusedValue(\.zenMode) private var zenMode
    /// …and its outline and notes — the Go menu's content.
    @FocusedValue(\.documentNavigation) private var navigation
    /// The book window's Previous / Next Article actions (⌃⌘↑ / ⌃⌘↓).
    @FocusedValue(\.bookArticleStepper) private var articleStepper
    /// Whether a book is open — the Close Book command's enabled state.
    @AppStorage(BookLibrary.bookmarkKey) private var bookBookmark = ""
    /// The trim size every PDF export from this menu paginates to — the
    /// document's and (sharing the same app-wide `md.pdfPageSize` key the book
    /// window's picker reads) the book compile's. Stored as the stable
    /// `PageSize.id`; `PageSize.named` maps it back and defaults to A4.
    @AppStorage("md.pdfPageSize") private var pdfPageSizeID = PageSize.a4.id
    /// The two typing rules (Edit ▸ Typing), app-wide and on by default.
    /// Every open editor reads the same keys at the keystroke
    /// (`TypingSettings`), so flipping one here takes effect at once in
    /// every window, document or book.
    @AppStorage(TypingSettings.continueListsKey) private var continueLists = true
    @AppStorage(TypingSettings.capitalizeSentencesKey) private var capitalizeSentences = true
    /// Opening scenes is an app-level action the environment provides even
    /// inside menu commands — how the book commands reach their window.
    @Environment(\.openWindow) private var openWindow
    /// …and closing them — how Close Book takes the book window down.
    @Environment(\.dismissWindow) private var dismissWindow
    /// Creating documents is likewise an environment action — how the
    /// Examples menu opens an example as a fresh untitled document.
    @Environment(\.newDocument) private var newDocument

    /// Send one `NSTextFinder` action down the responder chain exactly as an
    /// AppKit Find menu item does: the action is `performTextFinderAction:`
    /// and the sender's `tag` carries which of the actions it is. A detached
    /// `NSMenuItem` is that sender — nothing ever shows it, it is only the
    /// tag's carrier. `to: nil` lets the key window's first responder answer,
    /// so whichever text view has focus is the one that searches — including
    /// a text field the writer happens to be typing in, which is what every
    /// Mac app's Find menu does.
    ///
    /// When nothing answers, the action is not dropped: a window showing the
    /// editing pane has an editor whether or not the writer has clicked into
    /// it yet, and ⌘F that does nothing until you click the text would be a
    /// small daily annoyance. The frontmost window's editor is given the
    /// keyboard — which is where the find bar's own field wants it — and the
    /// action.
    ///
    /// A window with no editing pane at all — Preview only, or Zen reading —
    /// has no editor to find in, and `showEditor` is how it grows one: the
    /// same navigation nudge the Go ▸ Notes jump uses, since a match lives in
    /// the source exactly as a note does. The nudge only sets SwiftUI state,
    /// so the text view does not exist yet when it returns; the action is
    /// delivered a moment later instead, as soon as the pane is there, and
    /// gives up if no editor ever appears. A window md publishes no mode for
    /// at all (a sheet, a panel, another app's) passes no `showEditor`, and
    /// there the action really does stop.
    static func performFinderAction(_ action: NSTextFinder.Action,
                                    showEditor: (() -> Void)? = nil) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        if NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)),
                            to: nil, from: sender) { return }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if deliverFinderAction(sender, to: window) { return }
        guard let showEditor else { return }
        showEditor()
        deliverFinderAction(sender, to: window, whenTheEditorAppears: 20)
    }

    /// Hand one Find action to `window`'s editing pane, focusing it first.
    /// False — and nothing done — when that window has no editing pane.
    @discardableResult
    static func deliverFinderAction(_ sender: NSMenuItem, to window: NSWindow?) -> Bool {
        guard let window, let editor = firstEditor(in: window.contentView) else { return false }
        window.makeFirstResponder(editor)
        editor.performTextFinderAction(sender)
        return true
    }

    /// How long to wait between tries for the nudged pane to appear.
    ///
    /// Deliberately a short *wait* and not a plain `async` hop. Queued
    /// blocks can all run back to back inside one runloop pass, ahead of
    /// SwiftUI's own update and display: measured against Zen's read/write
    /// switch, a dozen consecutive hops drained before the editor existed
    /// and the find bar never opened at all.
    static let retryInterval: TimeInterval = 0.05

    /// The same delivery, retried until the pane the nudge asked for has
    /// been built and put in the window — `attempts` tries, one every
    /// `retryInterval`, so a window that never grows an editor (the writer
    /// moved on, the nudge landed nowhere) stops instead of spinning. In
    /// practice the first try finds it.
    static func deliverFinderAction(_ sender: NSMenuItem, to window: NSWindow?,
                                    whenTheEditorAppears attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) {
            if deliverFinderAction(sender, to: window) { return }
            deliverFinderAction(sender, to: window, whenTheEditorAppears: attempts - 1)
        }
    }

    /// The editing pane inside a view tree, depth first. Deliberately typed
    /// to md's own `SmartTextView` rather than to `NSTextView`: a visible
    /// find bar puts *its* search field's field editor — also an
    /// `NSTextView` — into the same tree, and searching for the base class
    /// could hand the find bar itself back instead of the document.
    static func firstEditor(in view: NSView?) -> SmartTextView? {
        guard let view else { return nil }
        if let editor = view as? SmartTextView { return editor }
        for subview in view.subviews {
            if let found = firstEditor(in: subview) { return found }
        }
        return nil
    }

    /// What every Edit ▸ Find row does: the action, plus the frontmost
    /// editing surface's way of putting its editor on screen when it is
    /// showing only the preview. `viewMode` is nil when the frontmost window
    /// is not one of md's editing surfaces, and then there is nothing to
    /// nudge.
    private func find(_ action: NSTextFinder.Action) {
        Self.performFinderAction(action, showEditor: viewMode?.showEditor)
    }

    var body: some Commands {
        // Examples — example documents, plus a ready-made sample book. They
        // need no open document, and stay in the File menu beside New.
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
        }

        // Writer mode gathered into its own top-level Book menu: opening and
        // showing a book, and — once one is open — sharing, printing and
        // exporting the whole thing. A book is app-wide (it outlives any one
        // document window), so these are keyed off whether a book is open
        // (`bookBookmark`), not the frontmost document. New / Open / Show
        // stay enabled — they are how a book comes to be open in the first
        // place; everything that acts on an open book is disabled until one
        // is. `Export Book` collects the formats into one submenu, mirroring
        // the document `Export` menu below.
        CommandMenu("Book") {
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
            Button("Close Book") {
                // Forget the bookmark and take the book window down with it.
                BookLibrary.closeBook()
                dismissWindow(id: BookLibrary.windowID)
            }
            .disabled(bookBookmark.isEmpty)

            Divider()

            Button("Share Book as PDF") {
                BookOutput.sharePDF(pageSize: PageSize.named(pdfPageSizeID))
            }
            .disabled(bookBookmark.isEmpty)
            Button("Print Book…") {
                BookOutput.printBook()
            }
            .disabled(bookBookmark.isEmpty)
            Menu("Export Book") {
                Button("PDF…") {
                    BookOutput.exportPDF(pageSize: PageSize.named(pdfPageSizeID))
                }
                Button("EPUB…") {
                    BookOutput.exportEPUB()
                }
                Button("LaTeX…") {
                    BookOutput.exportLaTeX()
                }
            }
            .disabled(bookBookmark.isEmpty)
        }

        // Edit ▸ Find, and Edit ▸ Typing — both after Cut / Copy / Paste /
        // Select All, where the system's own text-editing rows live.
        //
        // The Find rows are md's, not the system's: SwiftUI builds no Find
        // submenu at all (its Edit menu goes Undo, Redo, Cut, Copy, Paste,
        // Delete, Select All and then straight on to AutoFill and
        // Dictation), and on macOS ⌘F is a *menu* key equivalent, not a
        // text-view key binding — with no menu row there is no way into the
        // find bar the editor is configured for. Each row does exactly what
        // an AppKit Find menu item does: send `performTextFinderAction:`
        // down the responder chain with an `NSTextFinder.Action` in the
        // sender's tag, which the frontmost editor's `NSTextView` (document
        // window or book workspace) answers by showing its find bar and
        // running the search. Matching is `NSTextFinder`'s own — ordinal,
        // case-insensitive, wrapping, no regular expressions — which is the
        // rule every md edition shares.
        //
        // The rows are never disabled: whether they have anywhere to go
        // depends on the first responder, which changes without SwiftUI
        // rebuilding the menu, so a computed enabled state would go stale.
        // They do not need to be, either — an md editing surface always has
        // somewhere to send them, because a window showing only the preview
        // nudges its editor back first (`performFinderAction`'s `showEditor`).
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") { find(.showFindInterface) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find and Replace…") { find(.showReplaceInterface) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Find Next") { find(.nextMatch) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { find(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Use Selection for Find") { find(.setSearchString) }
                    .keyboardShortcut("e", modifiers: .command)
            }
        }

        // Edit ▸ Typing — the two typing rules. Toggles, so each wears a
        // checkmark when on; they are settings, not window actions, so they
        // are never disabled.
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Typing") {
                Toggle("Continue Lists and Tables", isOn: $continueLists)
                Toggle("Capitalize Sentences", isOn: $capitalizeSentences)
            }
        }

        // The frontmost window's Edit / Split / Preview, with the
        // shortcuts a writer flips modes with all day. Toggles so the
        // current mode wears a checkmark.
        CommandGroup(before: .sidebar) {
            ForEach(DocumentView.Mode.allCases) { mode in
                Toggle(mode.label, isOn: Binding(
                    get: { viewMode?.mode == mode },
                    set: { _ in viewMode?.select(mode) }
                ))
                .keyboardShortcut(KeyEquivalent(Character(mode.commandKey)), modifiers: .command)
                .disabled(viewMode == nil)
            }
            // Zen mode — the whole window becomes one centred column of text,
            // full screen, with nothing else. In Zen the Edit / Preview
            // toggles above (⌘1 / ⌘3) switch between writing and reading; ⌘2
            // (Split) folds to writing, since a single column has no second
            // pane. Document-only (the book workspace publishes no zenMode).
            Toggle("Zen Mode", isOn: Binding(
                get: { zenMode?.active ?? false },
                set: { _ in zenMode?.toggle() }
            ))
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(zenMode == nil)
            Divider()
        }

        // Navigation, gathered in the Mac's traditional Go menu: through
        // the book's articles, and within the frontmost document. Menu
        // commands, not toolbar shortcuts: the menu bar's key-equivalent
        // dispatch wins even while the editor's text view has focus, and
        // ⌃⌘↑/↓ is a chord neither the text view nor the system claims.
        CommandMenu("Go") {
            Button("Previous Article") {
                articleStepper?.previous()
            }
            .keyboardShortcut(.upArrow, modifiers: [.control, .command])
            .disabled(articleStepper?.canPrevious != true)
            Button("Next Article") {
                articleStepper?.next()
            }
            .keyboardShortcut(.downArrow, modifiers: [.control, .command])
            .disabled(articleStepper?.canNext != true)
            Divider()
            // Contents — jump to any heading; two spaces of indent per
            // level mirror the document's hierarchy inside the flat menu.
            Menu("Contents") {
                ForEach(navigation?.outline ?? [], id: \.line) { entry in
                    Button(String(repeating: "  ", count: max(0, entry.level - 1)) + entry.text) {
                        navigation?.jumpToHeading(entry)
                    }
                }
            }
            .disabled(navigation?.outline.isEmpty != false)
            // Notes — the writer's private `<!-- note: … -->` comments.
            Menu("Notes") {
                ForEach(navigation?.notes ?? [], id: \.line) { note in
                    Button(DocumentView.notePreview(note.text)) {
                        navigation?.jumpToNote(note)
                    }
                }
            }
            .disabled(navigation?.notes.isEmpty != false)
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

            // Sharing the frontmost document, gathered into one Share submenu:
            // its raw source, or the rendered document as a PDF. The whole
            // submenu is disabled when no document is frontmost.
            Menu("Share") {
                Button("Source…") {
                    if let document {
                        DocumentExport.shareSource(fileURL: document.fileURL,
                                                   text: document.text,
                                                   title: document.title)
                    }
                }
                Button("Rendered PDF…") {
                    if let document {
                        Task { await DocumentExport.sharePDF(source: document.text,
                                                             title: document.title,
                                                             dark: document.dark,
                                                             pageSize: PageSize.named(pdfPageSizeID)) }
                    }
                }
            }
            .disabled(document == nil)

            // Exporting the frontmost document, gathered into one Export
            // submenu — every format md writes, then a single diagram, then
            // the page size the PDF paths paginate to. The format buttons are
            // disabled without a document, and the diagram submenu without a
            // diagram; the page-size Picker stays enabled (it is a setting,
            // and it also governs the book's PDF compile in the Book menu), so
            // the Export menu itself is never disabled and the size stays
            // reachable.
            Menu("Export") {
                Button("PDF…") {
                    if let document {
                        Task { await DocumentExport.exportPDF(source: document.text,
                                                              title: document.title,
                                                              dark: document.dark,
                                                              pageSize: PageSize.named(pdfPageSizeID)) }
                    }
                }
                .disabled(document == nil)

                // One self-contained .html — the rendered page with its
                // diagrams and formulas baked in, opening anywhere with no
                // engines beside it.
                Button("HTML…") {
                    if let document {
                        Task { await DocumentExport.exportHTML(source: document.text,
                                                               title: document.title,
                                                               dark: document.dark) }
                    }
                }
                .disabled(document == nil)

                // The document as a single-unit EPUB (see
                // DocumentExport.exportDocumentEPUB): its title comes from the
                // front-matter `title:` or the file name, so `document.title`
                // (the editor's base name) is the fallback. No `dark:` — a
                // reflowing book owns its own theme.
                Button("EPUB…") {
                    if let document {
                        Task { await DocumentExport.exportDocumentEPUB(source: document.text,
                                                                       fileName: document.title) }
                    }
                }
                .disabled(document == nil)

                // The one export that keeps the mathematics editable: every
                // other path turns a formula into a picture or into KaTeX
                // markup, while the .tex hands back the `$…$` the author wrote.
                Button("LaTeX…") {
                    if let document {
                        Task { await DocumentExport.exportLaTeX(source: document.text,
                                                                title: document.title) }
                    }
                }
                .disabled(document == nil)

                // The document as a `.textbundle` (text.md + info.json +
                // assets/). `fileURL` is passed so referenced local images
                // beside the saved document can be copied into assets/.
                Button("TextBundle…") {
                    if let document {
                        Task { await DocumentExport.exportTextBundle(source: document.text,
                                                                     fileURL: document.fileURL,
                                                                     title: document.title) }
                    }
                }
                .disabled(document == nil)

                Divider()

                // One diagram → one standalone .svg. A submenu lists the
                // document's diagram blocks (by engine and a snippet of the
                // source); math is not here — KaTeX renders it as HTML+CSS,
                // not SVG, so there is no vector to export. Disabled when the
                // document has no diagrams (which also covers no document,
                // since `diagrams` is then empty). Parsed fresh each menu
                // build, the same cheap line scan the Go menu already pays.
                let diagrams = document.map { DiagramSVG.diagrams(inSource: $0.text) } ?? []
                Menu("Diagram as SVG") {
                    ForEach(diagrams, id: \.ordinal) { diagram in
                        Button(diagram.menuTitle) {
                            if let document {
                                Task { await DocumentExport.exportDiagramSVG(
                                    source: document.text, title: document.title, diagram: diagram) }
                            }
                        }
                    }
                }
                .disabled(diagrams.isEmpty)

                Divider()

                // The trim size both PDF paths paginate to — this document's
                // and the book's — remembered across launches. A Picker in a
                // menu renders as a submenu of checkable sizes.
                Picker("PDF Page Size", selection: $pdfPageSizeID) {
                    ForEach(PageSize.all) { size in
                        Text(size.label).tag(size.id)
                    }
                }
            }
        }
    }
}
