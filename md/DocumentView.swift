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
//  The mode is also remembered *per file* (see `ViewMode.swift`): a document
//  reopens the way its author left it, and one they have never opened before
//  opens in Split, exactly as it always has on a Mac. Three rules about that
//  store, all easy to break from here. Only the RAW preference is ever
//  written to it — never `effectiveMode`'s width-coerced output, which would
//  destroy a Split the first time the same file was opened on a phone. Zen
//  (`md.zen` / `md.zenReading`) stays strictly per-window and out of it. And
//  only a *deliberate* layout choice — the View menu, ⌘1/⌘2/⌘3 — writes to
//  it at all: a **navigation nudge**, the mode a jump has to put on screen
//  for its destination to be visible, is transient (`navigationMode`) and
//  writes nothing.
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
    /// document window keeps its own layout). Seeded per file on open by
    /// `applyViewModeMemory`, and written only through `setMode`.
    @SceneStorage("md.viewMode") private var storedMode = Mode.split.rawValue

    /// What `applyViewModeMemory` last saw, in three states that matter:
    /// `nil` — it has never run for this window; `.some(nil)` — it ran on a
    /// document with no file yet (File ▸ New, an example); `.some(id)` — it
    /// ran on the file with that identity. The middle state is what makes
    /// ⌘S safe: a first save takes `fileURL` nil → real, and without it the
    /// hook would re-decide and drop a mid-write author into Preview.
    @State private var lastIdentity: String??

    /// True when this window's document was opened by the book navigator
    /// (Open in New Window, a double-click in the sidebar, or a click in
    /// the separate-windows mode). Book articles are exempt from the
    /// per-file memory both ways — they neither seed the mode from it nor
    /// record one into it. See `BookArticleOpens`.
    @State private var isBookArticle = false

    /// A **transient** navigation nudge: the mode a jump has put on screen
    /// so its destination is visible, or nil when nothing is nudging. It
    /// outranks the stored preference for *display* — see
    /// `ViewModeRule.displayedMode` — and for nothing else.
    ///
    /// Deliberately plain `@State` — not `@SceneStorage`, not the per-file
    /// memory, nothing that outlives this window's present look at this
    /// document. Picking a mode for real clears it and persists (`setMode`);
    /// opening a different document clears it (`applyViewModeMemory`).
    ///
    /// Why it exists at all: jumping to a note needs the editor on screen,
    /// which is a fact about *this glance*, not a preference. Before the
    /// per-file memory existed the mode was session-only, so a jump moved
    /// you and was never a preference — nothing was recorded because there
    /// was nowhere to record it. Routing the jump through the persisting
    /// setter quietly turned "I read one note" into "this file opens in
    /// Edit from now on"; the nudge is how the old behaviour is kept while
    /// the memory stays.
    @State private var navigationMode: Mode?

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

    /// Zen mode: the window goes full screen and shows one centred column of
    /// text and nothing else. Per-window (SceneStorage), so one window can be
    /// in Zen while another is not. `zenReading` is Zen's own two-state
    /// switch — false to write (the editor), true to read (the preview).
    @SceneStorage("md.zen") private var zenActive = false
    @SceneStorage("md.zenReading") private var zenReading = false
    /// Zen's controls (the write/read switch and the exit affordance) fade in
    /// on mouse movement and out again when the pointer rests, so a still
    /// screen is only the text. Shown once on entering, to teach them.
    @State private var zenControlsShown = true
    @State private var zenHideTask: Task<Void, Never>?

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

    /// The stored preference itself: uncoerced, and un-nudged — the value
    /// the per-file memory holds. Everything that *writes* a mode writes
    /// this one; see the note in `ViewMode.swift`. The Save-As migration in
    /// `applyViewModeMemory` reads it directly and must keep doing so: it
    /// carries the author's true preference onto the new file, and folding
    /// the nudge in here would immortalise a passing glance at a note.
    private var rawMode: Mode { Mode(rawValue: storedMode) ?? .split }

    /// The mode actually shown: a navigation nudge while one is in force,
    /// otherwise the stored preference. A Mac document window is always wide
    /// enough to offer all three modes, so nothing is ever coerced away here
    /// — it goes through the shared rule anyway so this window and the
    /// iPad's behave from one piece of code.
    private var effectiveMode: Mode {
        ViewModeRule.displayedMode(preferred: rawMode,
                                   navigation: navigationMode,
                                   isWide: true)
    }

    // MARK: - Per-file view-mode memory

    /// The single place a mode preference is written: the window's own
    /// storage, and the file's remembered mode alongside it. Always the RAW
    /// mode — routing `effectiveMode`'s output through here is the one way to
    /// corrupt the shared store (see `ViewMode.swift`). Zen's write/read
    /// switch deliberately does *not* come through here: it is a per-window
    /// state, not a view mode. Neither does a navigation nudge, which is the
    /// whole point of it — only a *deliberate* layout choice (the View menu,
    /// ⌘1/⌘2/⌘3) reaches this function, and choosing one both outranks and
    /// ends any nudge that was in force.
    private func setMode(_ mode: Mode) {
        navigationMode = nil
        storedMode = mode.rawValue
        // Book articles are exempt: the layout a writer picks while stepping
        // through a book is the book's, not something to record against each
        // chapter file (see `BookArticleOpens`).
        guard !isBookArticle, let identity = fileURL.map(ViewModeMemory.identity(for:)) else { return }
        ViewModeMemory.remember(mode, for: identity)
    }

    /// Decide (and record) the mode this window opens `url` in.
    ///
    /// Keyed on `fileURL` with `initial: true`, so it runs once when the
    /// window appears and again whenever the document gains or changes a file
    /// — Save, Save As, Rename, Move To. Three outcomes:
    ///
    /// - the identity is the one we already acted on: nothing to do (the
    ///   document was merely re-rendered, or saved back over itself);
    /// - we last ran on a document with no file and it now has one: **migrate**
    ///   — carry the author's current raw mode onto the new identity without
    ///   re-deciding. This is the ⌘S case, and re-deciding here would flip a
    ///   writer mid-sentence into Preview;
    /// - otherwise: apply the shared open rule and remember the answer.
    ///
    /// …unless the book navigator opened this document, in which case none
    /// of the three happens: an article keeps whatever mode the window is
    /// already in, and records nothing. The mark is claimed *before* the
    /// unchanged-identity return above, so it is never left lying about for
    /// the next open of the same file to pick up.
    ///
    /// Emptiness is read from the text, never from `fileURL == nil`: File ▸
    /// Examples opens an untitled document that already has content, and it
    /// should open like the document it is.
    private func applyViewModeMemory(for url: URL?) {
        let identity = url.map(ViewModeMemory.identity(for:))
        // Claimed before the unchanged-identity return below, so a mark is
        // never left behind for some later, ordinary open of the same file
        // to inherit. And once claimed it sticks: a Mac document window
        // holds one document for its whole life, so every later fire here
        // (Save As, a Finder rename, a Move To) is still that same article
        // the writer pulled out of the book.
        if url.map(BookArticleOpens.claimOpen) == true { isBookArticle = true }
        if isBookArticle {
            lastIdentity = .some(identity)
            return
        }
        if let last = lastIdentity, last == identity { return }
        let hadNoIdentity = lastIdentity == .some(String?.none)
        lastIdentity = .some(identity)

        if hadNoIdentity, let identity {
            // `rawMode`, never the displayed mode: the true preference is
            // what moves onto the new file. A navigation nudge in force is
            // left alone as well as unwritten — this is the same document
            // the author is looking at, one ⌘S later, and yanking them out
            // of the note they are writing would be the very thing the
            // migrate branch exists to prevent.
            ViewModeMemory.remember(rawMode, for: identity)
            return
        }
        // A different document from here on: any nudge belonged to the last
        // one and goes with it.
        navigationMode = nil
        let mode = ViewModeRule.openViewMode(
            remembered: identity.flatMap { ViewModeMemory.lookup($0) },
            isEmptyDocument: document.text.isEmpty,
            hasFileIdentity: identity != nil,
            isWide: true)                    // a Mac window always offers Split
        setMode(mode)
    }

    /// Base name used for export / print filenames and the print job.
    private var baseName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    var body: some View {
        Group {
            if zenActive {
                zenBody
            } else {
                VStack(spacing: 0) {
                    content
                    Divider()
                    footer
                }
                .frame(minWidth: 480, minHeight: 320)
            }
        }
            .background(Typewriter.paper.ignoresSafeArea())
            .fullScreenCapable()
            // Drive the window in and out of full screen with Zen, and drop
            // out of Zen if the user leaves full screen by other means.
            .background(ZenFullScreen(active: zenActive, onExit: { zenActive = false }))
            // Hand the frontmost document to the menu-bar commands so
            // File ▸ Print… / Share… act on it (see `DocumentCommands`).
            .focusedSceneValue(\.activeDocument,
                               ActiveDocument(text: document.text,
                                              title: baseName,
                                              fileURL: fileURL,
                                              dark: colorScheme == .dark))
            // …the mode switch, so the View-menu ⌘1/⌘2/⌘3 drive it. In Zen
            // the same toggles flip Zen's write/read state instead of the
            // windowed layout: Edit and Split write, Preview reads.
            .focusedSceneValue(\.viewModeSelection,
                               ViewModeSelection(
                                mode: zenActive ? (zenReading ? .preview : .edit) : effectiveMode,
                                select: { mode in
                                    if zenActive {
                                        zenReading = (mode == .preview)
                                    } else {
                                        setMode(mode)
                                    }
                                }))
            // …the Zen toggle, for View ▸ Zen Mode (⇧⌘↩)…
            .focusedSceneValue(\.zenMode,
                               ZenModeCommand(active: zenActive,
                                              toggle: { zenActive.toggle() }))
            // …and the outline and notes, for the Go menu.
            .focusedSceneValue(\.documentNavigation,
                               DocumentNavigation(outline: derived.outline,
                                                  notes: derived.notes,
                                                  jumpToHeading: { jump(to: $0) },
                                                  jumpToNote: { jump(to: $0) }))
            // Open the document in the mode its author left it in — and keep
            // following the file across Save / Save As / Rename / Move To,
            // which is exactly when `fileURL` changes.
            .onChange(of: fileURL, initial: true) { _, url in
                applyViewModeMemory(for: url)
            }
            // Recompute the derived values once per typing pause — the
            // task restarts (cancelling the sleeping one) on every change.
            .task(id: document.text) {
                derived = await derived.refreshed(from: document.text)
            }
            // Reveal the Zen controls briefly whenever Zen turns on, so they
            // are seen before they fade.
            .onChange(of: zenActive) { _, on in
                if on { revealZenControls() } else { zenHideTask?.cancel() }
            }
    }

    // MARK: - Zen mode

    /// The Zen layout: paper everywhere, and one centred column — two-thirds
    /// of the window wide, with a border of roughly four percent above and
    /// below — holding the editor (writing) or the preview (reading). The
    /// write/read switch and an exit control float at the top, fading with
    /// the pointer.
    private var zenBody: some View {
        GeometryReader { geo in
            Group {
                if zenReading {
                    previewPane
                } else {
                    editorPane
                }
            }
            .frame(width: geo.size.width * (2.0 / 3.0),
                   height: geo.size.height * 0.92)
            .frame(maxWidth: .infinity, maxHeight: .infinity)   // centre it on the paper
            .overlay(alignment: .top) { zenControls }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { revealZenControls() }
            }
        }
    }

    /// Zen's floating controls: a write/read switch and a way out, in a
    /// translucent capsule that fades unless the pointer is moving.
    private var zenControls: some View {
        HStack(spacing: 2) {
            zenSwitch(reading: false, symbol: Mode.edit.symbol, help: "Write")
            zenSwitch(reading: true, symbol: Mode.preview.symbol, help: "Read")
            Divider().frame(height: 14)
            Button {
                zenActive = false
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.plain)
            .help("Exit Zen Mode")
            .padding(.horizontal, 6)
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 10)
        .opacity(zenControlsShown ? 1 : 0)
        .allowsHitTesting(zenControlsShown)
        .animation(.easeInOut(duration: 0.3), value: zenControlsShown)
    }

    private func zenSwitch(reading: Bool, symbol: String, help: String) -> some View {
        Button {
            zenReading = reading
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(zenReading == reading ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Show the Zen controls, then fade them once the pointer has rested for
    /// a couple of seconds. Each call restarts the timer, so continuous
    /// movement keeps them up.
    private func revealZenControls() {
        zenControlsShown = true
        zenHideTask?.cancel()
        zenHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { zenControlsShown = false }
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
    /// editor — nudging preview-only mode aside first when necessary.
    ///
    /// The branch asks about the mode on **screen**, which is the right
    /// question: "is the editor visible?". What was wrong was the answer's
    /// side effect. This used to call `setMode`, so reading one note wrote
    /// `edit` into the file's remembered mode and a document its author kept
    /// in Preview opened in Edit ever after. A nudge shows the editor and
    /// records nothing, which is exactly how this behaved before the mode
    /// was remembered per file at all.
    private func jump(to note: NoteEntry) {
        // Assigned only when the rule asks for a nudge: writing its nil back
        // would clear the override the *previous* note jump put in force, and
        // bounce a reader stepping through notes back into Preview.
        if let nudge = ViewModeRule.navigationNudge(displayed: effectiveMode, wants: .edit) {
            navigationMode = nudge
        }
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

// MARK: - Zen full-screen driver

/// Keeps the hosting window's full-screen state in step with Zen mode.
/// Entering Zen takes the window full screen; leaving Zen brings it back.
/// And if the user leaves full screen by other means — the green button,
/// ⌃⌘F, the Escape the system offers — Zen is dropped too, via `onExit`, so
/// the two never disagree.
///
/// The `toggling` flag distinguishes a transition *we* asked for (whose
/// end-notification is expected and must not be read as the user leaving)
/// from one the user drove. `.fullScreenPrimary` is already on the window
/// (see `fullScreenCapable`), so `toggleFullScreen` is available.
private struct ZenFullScreen: NSViewRepresentable {
    let active: Bool
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onExit = onExit
        // The window isn't attached during the first update either — defer to
        // the next runloop turn, when the view has landed in its window.
        DispatchQueue.main.async {
            context.coordinator.sync(desired: active, window: view.window)
        }
    }

    final class Coordinator {
        var onExit: () -> Void
        private weak var observedWindow: NSWindow?
        private var toggling = false

        init(onExit: @escaping () -> Void) { self.onExit = onExit }

        func sync(desired: Bool, window: NSWindow?) {
            guard let window else { return }
            observe(window)
            let isFull = window.styleMask.contains(.fullScreen)
            guard desired != isFull, !toggling else { return }
            toggling = true
            window.toggleFullScreen(nil)
        }

        private func observe(_ window: NSWindow) {
            guard observedWindow !== window else { return }
            observedWindow = window
            let center = NotificationCenter.default
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                               object: window, queue: .main) { [weak self] _ in
                self?.toggling = false
            }
            center.addObserver(forName: NSWindow.didExitFullScreenNotification,
                               object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                if self.toggling {
                    // The exit we asked for finished.
                    self.toggling = false
                } else {
                    // The user left full screen while in Zen — leave Zen too.
                    self.onExit()
                }
            }
        }
    }
}
