//
//  BookWorkspace.swift
//  md
//
//  Created by nettrash on 13/07/2026.
//
//  The writing half of the book window (see `BookNavigator` for the window
//  itself and the structure sidebar). Selecting an article in the sidebar
//  edits it *in place* — the article opens in the detail pane with the same
//  Edit / Split / Preview panes as a document window — so the writer keeps
//  the whole book in view while working, and the window's native full
//  screen becomes a distraction-free writing mode.
//
//  In-place editing lives outside the document architecture (`NSDocument`
//  owns document *windows*; the book pane deliberately isn't one), so this
//  file supplies the pieces the architecture would otherwise provide:
//
//  `BookArticleSession` — one selected article's editing state. It reads
//  and round-trips the file through the same `PlainTextCodec` as
//  `MarkdownDocument`, autosaves a debounced second after typing stops,
//  and defends the file the way a good Mac citizen must: writes go through
//  `NSFileCoordinator` with the session registered as the file's
//  `NSFilePresenter` (external coordinated writes reload a clean session
//  and flag a dirty one as conflicted instead of clobbering either side); a
//  staleness check inside the write block (modification date + size)
//  catches uncoordinated writers; sudden termination is disabled while
//  edits are unsaved so the terminate-time flush is actually delivered;
//  and if the article is (or becomes) open in a real document window, the
//  session steps aside — the document owns the file, the detail pane shows
//  a handoff notice — rather than fighting NSDocument's autosave with
//  last-writer-wins. The session holds the book root's security scope for
//  its whole life, so a Close Book in another window can't revoke access
//  out from under a pending save.
//
//  `BookArticleEditor` — the detail pane: the panes themselves, plus a
//  footer with the author's word / character count (and, only when
//  something is actually wrong, the save-failure or conflict notice with
//  its recovery buttons — routine autosave is silent).
//

import SwiftUI
import AppKit

// MARK: - Word count

/// The author-facing counters in the editor footer.
enum WritingStats {
    /// Locale-aware word count (what "words" means to a writer, not a
    /// whitespace split — "it's" is one word, "—" is none).
    static func words(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex...,
                                 options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }
}

/// Everything the window chrome derives from the document text — the
/// footer's counters and the Go menu's outline and notes — computed as one
/// bundle, off the main thread, once per typing pause (each owner drives
/// it from a `.task(id: text)`, whose restart-on-change is the debounce).
/// Deriving these inline in `body` would re-scan the entire text on every
/// keystroke, and a book-length document costs real milliseconds per scan.
struct DerivedText: Equatable {
    var words = 0
    var characters = 0
    var outline: [OutlineEntry] = []
    var notes: [NoteEntry] = []
    /// False only before the first computation — the owner's task skips
    /// the debounce then, so a fresh window's footer and Go menu fill
    /// immediately instead of flashing empty.
    var computed = false

    /// One full-text scan, away from the main thread (`text` is a value —
    /// nothing shared, nothing to race).
    static func compute(from text: String) async -> DerivedText {
        await Task.detached {
            DerivedText(words: WritingStats.words(in: text),
                        characters: text.count,
                        outline: MarkdownParser.outline(text),
                        notes: MarkdownParser.notes(text),
                        computed: true)
        }.value
    }

    /// The debounced recompute every owner runs from `.task(id: text)`:
    /// immediate on first fill, coalesced to one scan per typing pause
    /// after (the restarted task cancels the sleeping one).
    func refreshed(from text: String) async -> DerivedText {
        if computed {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return self }
        }
        return await Self.compute(from: text)
    }
}

// MARK: - Flush gate (book output ↔ the in-place editor)

/// Ask the in-place editor — wherever it lives — to save before the book
/// is read from disk. `BookOutput` posts one synchronously; the article
/// session flushes in its observer and flips `vetoed` when the save
/// failed, so the output action stops rather than shipping a stale page.
/// A class, because the answer travels back through the notification's
/// object. No book window this launch → no observer → nothing unsaved →
/// the gate stays open, which is exactly right.
final class BookFlushGate {
    static let request = Notification.Name("md.bookFlushRequest")
    var vetoed = false
}

// MARK: - File presenter shim

/// The session's `NSFilePresenter`. A separate object because presenter
/// callbacks arrive on a private queue while the session is main-actor —
/// this shim owns the thread-safe `presentedItemURL` and bounces each
/// event to the session on the main actor. Deliberately tiny: all policy
/// lives in the session.
private final class ArticleFilePresenter: NSObject, NSFilePresenter {
    private let lock = NSLock()
    private var url: URL?
    weak var session: BookArticleSession?

    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    var presentedItemURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return url
    }

    func present(_ url: URL?) {
        lock.lock(); defer { lock.unlock() }
        self.url = url
    }

    func presentedItemDidChange() {
        Task { @MainActor [weak session] in session?.presentedFileChanged() }
    }

    func presentedItemDidMove(to newURL: URL) {
        present(newURL)
        Task { @MainActor [weak session] in session?.presentedFileMoved(to: newURL) }
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        Task { @MainActor [weak session] in session?.presentedFileDeleted() }
        completionHandler(nil)
    }
}

// MARK: - Session

/// The editing state of the one article currently open in the book
/// window's detail pane. See the file header for the safety story.
@MainActor
final class BookArticleSession: NSObject, ObservableObject {

    /// What the detail pane should show.
    enum Stage: Equatable {
        /// Nothing selected (or the book is empty).
        case empty
        /// The article is open here, editable.
        case editing(URL)
        /// The article is open in its own document window — that window
        /// owns the file; the pane shows a handoff notice.
        case handoff(URL)
        /// The article could not be read.
        case unreadable(URL)
    }

    @Published private(set) var stage: Stage = .empty
    /// The article's text while `.editing`. Views must route edits through
    /// `edit(_:)` — assigning here directly would bypass dirty tracking.
    @Published var text = ""
    /// The file changed on disk under unsaved local edits (or vanished).
    /// Autosave is suspended; the footer offers Reload / Keep My Version.
    @Published private(set) var conflicted = false
    /// The last save failure, shown until a save succeeds. The session
    /// stays dirty, so Retry (or the next keystroke's autosave) can heal it.
    @Published private(set) var saveErrorText: String?

    /// Undo stack scoped to the current article (passed to
    /// `MarkdownEditor.undoOverride`); replaced on every selection change
    /// so ⌘Z can never replay another article's keystrokes.
    private(set) var undoManager = UndoManager()

    private(set) var dirty = false
    private var encoding: String.Encoding = .utf8
    /// On-disk stamp (modification date, size) as of the last read/write —
    /// what the write-time staleness check compares against.
    private var diskStamp: (date: Date, size: Int)?

    /// The book root whose security scope the session holds; `holdsScope`
    /// is false for the tests' plain temp folders.
    private var root: URL?
    private var holdsScope = false

    private let presenter = ArticleFilePresenter()
    private var presenterRegistered = false
    private var pendingSave: DispatchWorkItem?
    private var suddenTerminationDisabled = false
    private var observers: [NSObjectProtocol] = []
    /// How long after the last keystroke the autosave fires.
    static let autosaveDelay: TimeInterval = 1.0

    override init() {
        super.init()
        presenter.session = self
        // Both notifications are posted on the main thread, so the handlers
        // may assume the main actor — and must, for willTerminate: anything
        // scheduled asynchronously would never run before the process exits.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.terminateFlush() }
            })
        // A window becoming key is the natural moment ownership can have
        // changed hands: a document window just opened over the selected
        // article (hand the file off) or just closed (reclaim it).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.recheckOwnership() }
            })
        // A book output action (share / export / print the whole book) is
        // about to read the files: save the buffer first, and veto the
        // action if the save fails — the compile must ship the page the
        // writer is looking at, or nothing. Posted synchronously, so the
        // flush completes before the post returns.
        observers.append(NotificationCenter.default.addObserver(
            forName: BookFlushGate.request, object: nil, queue: nil) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, !self.flushNow() else { return }
                    (note.object as? BookFlushGate)?.vetoed = true
                }
            })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if presenterRegistered { NSFileCoordinator.removeFilePresenter(presenter) }
        if suddenTerminationDisabled { ProcessInfo.processInfo.enableSuddenTermination() }
    }

    // MARK: Book lifecycle (scope)

    /// Resolve the stored bookmark and hold the book root's security scope
    /// for the session's lifetime — so no other window's action (Close
    /// Book removes the bookmark) can revoke file access between an edit
    /// and its save. Balanced by `closeBook`.
    func openBook() {
        closeBook()
        root = BookLibrary.beginAccess()
        holdsScope = root != nil
    }

    /// Test seam: run against a plain folder with no sandbox scope to hold.
    func openBook(unscopedRoot: URL) {
        closeBook()
        root = unscopedRoot
        holdsScope = false
    }

    /// Final flush, then release the held scope. A failed flush here still
    /// detaches — the writer explicitly closed the book — but is reported,
    /// never swallowed.
    func closeBook() {
        detach(reportFailure: true)
        if holdsScope, let root { BookLibrary.endAccess(root) }
        root = nil
        holdsScope = false
    }

    // MARK: Selection

    /// The URL being edited in place, when there is one.
    var editingURL: URL? {
        if case .editing(let url) = stage { return url }
        return nil
    }

    /// The article's display name — titles the preview, print job and
    /// menu-bar share actions.
    var title: String {
        switch stage {
        case .editing(let url), .handoff(let url), .unreadable(let url):
            return BookLibrary.displayName(url.lastPathComponent)
        case .empty:
            return ""
        }
    }

    /// Move the session to `url` (nil deselects): flush the current
    /// article, then either load the new one or step aside if a document
    /// window owns it. Returns false — leaving the current article in
    /// place — when the flush fails; the caller reverts its selection so
    /// no unsaved text is ever abandoned silently.
    func select(_ url: URL?) -> Bool {
        let target = url?.standardizedFileURL
        if case .editing(let current) = stage, current == target { return true }
        guard flushNow() else { return false }
        detach(reportFailure: false)
        guard let target else { return true }
        if documentOwning(target) != nil {
            stage = .handoff(target)
            return true
        }
        load(target)
        return true
    }

    /// Detach unconditionally (Close Book, window closing): the flush is
    /// attempted, and a failure — the write refused, or an unresolved
    /// conflict — parks the buffer in a rescue copy and says so, instead
    /// of discarding keystrokes behind an alert with no way out.
    private func detach(reportFailure: Bool) {
        if !flushNow() && reportFailure, case .editing(let url) = stage, dirty {
            let name = BookLibrary.displayName(url.lastPathComponent)
            if let rescued = writeRescueCopy(for: url) {
                BookLibrary.presentError(
                    "Could not save \u{201C}\(name)\u{201D}",
                    informative: "Your text was kept as \u{201C}\(rescued.lastPathComponent)\u{201D} in the same folder.")
            } else {
                BookLibrary.presentError(
                    "Could not save \u{201C}\(name)\u{201D}",
                    informative: saveErrorText ?? "The article could not be written.")
            }
        }
        pendingSave?.cancel()
        pendingSave = nil
        if presenterRegistered {
            NSFileCoordinator.removeFilePresenter(presenter)
            presenterRegistered = false
        }
        presenter.present(nil)
        undoManager = UndoManager()
        text = ""
        stage = .empty
        conflicted = false
        saveErrorText = nil
        diskStamp = nil
        setDirty(false)
    }

    /// Read `url` into the session and start presenting it.
    private func load(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let decoded = PlainTextCodec.decode(data) else {
            stage = .unreadable(url)
            return
        }
        text = decoded.text
        encoding = decoded.encoding
        diskStamp = Self.stamp(at: url)
        undoManager = UndoManager()
        stage = .editing(url)
        conflicted = false
        saveErrorText = nil
        setDirty(false)
        presenter.present(url)
        NSFileCoordinator.addFilePresenter(presenter)
        presenterRegistered = true
    }

    // MARK: Editing

    /// The one write path for keystrokes: mark dirty and re-arm the
    /// debounced autosave. While conflicted the autosave stays suspended —
    /// the writer must first choose Reload or Keep My Version.
    func edit(_ newText: String) {
        guard case .editing = stage, text != newText else { return }
        text = newText
        setDirty(true)
        guard !conflicted else { return }
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autosaveDelay, execute: work)
    }

    /// Sudden termination stays disabled exactly while edits are unsaved —
    /// what makes the `willTerminate` flush reliable: with the counter
    /// bumped, ⌘Q and log-out go through the full AppKit terminate
    /// sequence instead of killing the process outright.
    private func setDirty(_ newValue: Bool) {
        guard dirty != newValue else { return }
        dirty = newValue
        if newValue, !suddenTerminationDisabled {
            ProcessInfo.processInfo.disableSuddenTermination()
            suddenTerminationDisabled = true
        } else if !newValue, suddenTerminationDisabled {
            ProcessInfo.processInfo.enableSuddenTermination()
            suddenTerminationDisabled = false
        }
    }

    // MARK: Saving

    /// Write the buffer to disk now, if there is anything unsaved.
    /// Coordinated (default) saves exclude our own presenter and bail out —
    /// flagging `conflicted` — when the file on disk is no longer the one
    /// we read. Returns true when nothing needed saving or the write
    /// landed.
    @discardableResult
    func flushNow(coordinated: Bool = true) -> Bool {
        guard case .editing(let url) = stage, dirty else { return true }
        // A document window may have opened this article mid-session (Open
        // Recent, Finder). Save our text first — an unedited document
        // auto-reverts to the coordinated write — then step aside.
        let owner = documentOwning(url)
        pendingSave?.cancel()
        pendingSave = nil

        let (data, usedEncoding) = PlainTextCodec.encode(text, preferred: encoding)
        var succeeded = false
        var failure: String?
        var stale = false

        let write: (URL) -> Void = { [self] target in
            if let expected = diskStamp, Self.stamp(at: target) ?? (.distantPast, -1) != expected {
                stale = true
                return
            }
            do {
                try data.write(to: target)
                diskStamp = Self.stamp(at: target)
                succeeded = true
            } catch {
                failure = error.localizedDescription
            }
        }

        if coordinated {
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: presenter)
                .coordinate(writingItemAt: url, options: [], error: &coordinationError) { write($0) }
            if let coordinationError { failure = coordinationError.localizedDescription }
        } else {
            // The terminate-time path: the process is exiting *now*; a
            // coordinated write could block on an unresponsive presenter
            // (an iCloud file provider, say) and forfeit the save entirely.
            write(url)
        }

        if stale {
            conflicted = true
            return false
        }
        if succeeded {
            encoding = usedEncoding
            saveErrorText = nil
            setDirty(false)
            if owner != nil { stage = .handoff(url) }
            return true
        }
        saveErrorText = failure ?? "The article could not be written."
        return false
    }

    private func terminateFlush() {
        // The regular write can be refused right as the app exits — the
        // buffer is conflicted, the file vanished, the disk is full. That
        // must not cost the keystrokes: park them in a rescue copy next to
        // the article. (Sudden termination was disabled the moment the
        // buffer went dirty, which is why this code runs at all.)
        if !flushNow(coordinated: false), case .editing(let url) = stage, dirty {
            _ = writeRescueCopy(for: url)
        }
    }

    /// Last-resort save when the regular write cannot land: the buffer
    /// goes to a fresh "<name> (rescued).md" sibling — never overwriting
    /// anything — so no keystroke is ever silently discarded. Returns the
    /// rescue file's URL, nil only when even that write failed. Internal
    /// for the tests; callers are the terminate-time flush and the
    /// reporting detach.
    func writeRescueCopy(for url: URL) -> URL? {
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "md" : url.pathExtension
        let (data, _) = PlainTextCodec.encode(text, preferred: encoding)
        for attempt in 1...100 {
            let name = attempt == 1 ? "\(stem) (rescued)" : "\(stem) (rescued \(attempt))"
            let candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
            guard !FileManager.default.fileExists(atPath: candidate.path) else { continue }
            return (try? data.write(to: candidate)) != nil ? candidate : nil
        }
        return nil
    }

    // MARK: Conflicts

    /// "Keep My Version": the writer looked at the conflict and chose the
    /// buffer — write it out unconditionally (no staleness check here; the
    /// point is to overwrite whatever is on disk).
    func resolveConflictKeepingMine() {
        guard case .editing(let url) = stage else { return }
        conflicted = false
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: presenter)
            .coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
                let (data, usedEncoding) = PlainTextCodec.encode(text, preferred: encoding)
                do {
                    try data.write(to: target)
                    encoding = usedEncoding
                    diskStamp = Self.stamp(at: target)
                    saveErrorText = nil
                    setDirty(false)
                } catch {
                    saveErrorText = error.localizedDescription
                }
            }
        if let coordinationError { saveErrorText = coordinationError.localizedDescription }
    }

    /// "Reload from Disk": discard the buffer in favor of what's on disk.
    /// Clearing the dirty flag *first* is what makes the detach's flush a
    /// no-op — writing the buffer is exactly what must not happen here.
    func resolveConflictReloading() {
        guard case .editing(let url) = stage else { return }
        setDirty(false)
        detach(reportFailure: false)
        load(url)
    }

    // MARK: Ownership (NSDocument windows)

    /// The open document editing `url`, if any — matched on standardized
    /// paths, since the same file can be reached under different URL
    /// spellings.
    private func documentOwning(_ url: URL) -> NSDocument? {
        let path = url.standardizedFileURL.path
        return NSDocumentController.shared.documents.first {
            $0.fileURL?.standardizedFileURL.path == path
        }
    }

    /// Re-evaluate who owns the selected article (runs when any window
    /// becomes key). Editing + a document appeared → save and hand off;
    /// handoff + the document closed → reclaim the file here.
    func recheckOwnership() {
        switch stage {
        case .editing(let url):
            if documentOwning(url) != nil {
                // Hand off only once the buffer is safe: a dirty flush sets
                // .handoff itself; a clean session steps aside directly. A
                // *failed* flush stays put — the buffer must remain visible
                // (with its error notice) rather than vanish behind the
                // handoff pane.
                if flushNow(), case .editing = stage { stage = .handoff(url) }
            }
        case .handoff(let url):
            if documentOwning(url) == nil {
                detach(reportFailure: false)
                load(url)
            }
        case .empty, .unreadable:
            break
        }
    }

    /// Bring the owning document window to the front (the handoff pane's
    /// button).
    func showOwningWindow() {
        guard case .handoff(let url) = stage else { return }
        documentOwning(url)?.showWindows()
    }

    /// The workspace is about to open the current article in a separate
    /// window: save, then step into handoff *before* the document opens so
    /// there is never a moment with two writers.
    func handOffForExternalOpen() -> Bool {
        guard case .editing(let url) = stage else { return true }
        guard flushNow() else { return false }
        detach(reportFailure: false)
        stage = .handoff(url)
        return true
    }

    // MARK: File presenter events (already bounced to the main actor)

    /// Another writer changed the file through coordination. Clean session:
    /// silently follow the disk. Dirty session: keep both versions intact —
    /// buffer in memory, theirs on disk — suspend autosave and let the
    /// writer choose.
    func presentedFileChanged() {
        guard case .editing(let url) = stage else { return }
        // Attribute-only events (a Finder tag, permissions) land here too.
        // Only a moved content stamp is a real change — a conflict banner
        // over identical bytes would invite a pointless, text-discarding
        // Reload.
        if let current = Self.stamp(at: url), let expected = diskStamp, current == expected {
            return
        }
        if dirty {
            conflicted = true
            pendingSave?.cancel()
            pendingSave = nil
        } else if let data = try? Data(contentsOf: url),
                  let decoded = PlainTextCodec.decode(data) {
            text = decoded.text
            encoding = decoded.encoding
            diskStamp = Self.stamp(at: url)
        }
    }

    func presentedFileMoved(to newURL: URL) {
        guard case .editing = stage else { return }
        stage = .editing(newURL.standardizedFileURL)
    }

    /// The file is being deleted. Letting go quietly would throw away any
    /// unsaved keystrokes, so a dirty buffer stays on screen as a conflict
    /// ("Keep My Version" recreates the file); a clean one just detaches.
    func presentedFileDeleted() {
        guard case .editing = stage else { return }
        if dirty {
            conflicted = true
            pendingSave?.cancel()
            pendingSave = nil
        } else {
            detach(reportFailure: false)
        }
    }

    // MARK: Disk stamps

    /// (modification date, size) of the file right now — read through
    /// `FileManager` (never cached, unlike `URL.resourceValues`).
    private static func stamp(at url: URL) -> (date: Date, size: Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int else { return nil }
        return (date, size)
    }
}

// MARK: - Detail pane

/// The editing pane for the selected article: the same Edit / Split /
/// Preview panes as a document window, over the session's buffer, with the
/// author's counters in a footer. The surrounding toolbar (mode switch,
/// article navigation, Contents / Notes) lives in `BookNavigator`, which
/// owns the workspace state the toolbar needs.
struct BookArticleEditor: View {
    @ObservedObject var session: BookArticleSession
    /// The workspace's cached counters for the footer — one shared scan
    /// per typing pause instead of a fresh one per keystroke here.
    let derived: DerivedText
    /// One-shot navigation requests, owned by the workspace (whose toolbar
    /// menus bump them) and consumed here exactly once by id.
    @Binding var previewNavigation: PreviewNavigation?
    @Binding var editorJump: EditorJump?
    @AppStorage("md.bookViewMode") private var storedMode = DocumentView.Mode.split.rawValue

    /// Links the panes' scrolling in Split, exactly as in a document
    /// window (identity-stable; the panes register themselves on it).
    @State private var scrollSync = ScrollSync()

    private var mode: DocumentView.Mode { .init(rawValue: storedMode) ?? .split }

    /// Edits flow through `session.edit`, never straight into the
    /// published property — that is what arms the autosave.
    private var textBinding: Binding<String> {
        Binding(get: { session.text }, set: { session.edit($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            panes
            Divider()
            footer
        }
    }

    @ViewBuilder
    private var panes: some View {
        switch mode {
        case .edit:
            editorPane
        case .preview:
            previewPane
        case .split:
            // Same responsive split as a document window: side by side
            // with room, stacked when the window is dragged narrow.
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
        // `.id(editingURL)` gives every article a fresh NSTextView (clean
        // caret, scroll and first-responder state); the session's per-
        // article undo manager keeps ⌘Z scoped to this article even so.
        MarkdownEditor(text: textBinding, jump: editorJump,
                       onJumpHandled: { handled in
                           if editorJump?.id == handled { editorJump = nil }
                       },
                       undoOverride: session.undoManager,
                       scrollSync: scrollSync)
            .id(session.editingURL)
            .overlay(alignment: .topLeading) {
                if session.text.isEmpty {
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
        // The article URL is the document token: switching articles is a
        // fresh page load, not a debounced reload that would flash the
        // previous article and inherit its scroll position.
        MarkdownWebView(text: session.text, title: session.title,
                        navigation: previewNavigation,
                        onNavigationHandled: { handled in
                            if previewNavigation?.id == handled { previewNavigation = nil }
                        },
                        documentToken: session.editingURL,
                        scrollSync: scrollSync)
    }

    /// Words and characters for the author; save trouble only when there
    /// is trouble — a healthy autosave has no ticker.
    private var footer: some View {
        HStack(spacing: 12) {
            if session.conflicted {
                Label("The file changed on disk.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Reload from Disk") { session.resolveConflictReloading() }
                Button("Keep My Version") { session.resolveConflictKeepingMine() }
            } else if let saveError = session.saveErrorText {
                Label("Couldn\u{2019}t save — \(saveError)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Button("Retry") { session.flushNow() }
            }
            Spacer()
            Text("\(derived.words) words · \(derived.characters) characters")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(Typewriter.font(11))
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Typewriter.paperSecondary)
    }
}
