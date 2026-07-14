//
//  MarkdownEditor.swift
//  md
//
//  Created by nettrash on 29/06/2026.
//
//  The raw-Markdown editing pane, an `NSTextView` (inside a scroll view)
//  wrapped for SwiftUI. The macOS sibling of the iOS `UITextView` editor.
//
//  Why not SwiftUI's `TextEditor`? Two things this app needs are awkward
//  to get from it: full control of the typing surface — the American
//  Typewriter face, a clear paper background, and turning off the "smart"
//  quote / dash substitutions that would silently rewrite Markdown
//  punctuation (`"`, `--`, `...`); and a plain, undo-aware text view that
//  the standard Edit ▸ Undo / Redo menu drives natively.
//
//  An `NSTextView` gives all of that. Undo / Redo are intentionally *not*
//  re-exposed in the toolbar here (unlike iOS, which has no menu bar):
//  `allowsUndo = true` plus the responder chain means the system Edit
//  menu's ⌘Z / ⇧⌘Z work out of the box. Every keystroke flows back
//  through the `text` binding, which marks the `FileDocument` dirty and
//  drives the document architecture's autosave.
//
//  The editor also accepts one-shot caret jumps (`EditorJump`) from the
//  Contents / Notes toolbar menus: `DocumentView` bumps a request and the
//  coordinator puts the caret on the requested source line, scrolls it
//  into view and focuses the editor.
//

import SwiftUI
import AppKit

/// A one-shot "put the caret on this line" request from outside the editor
/// (the Contents / Notes toolbar menus). SwiftUI re-sends the same value on
/// every view update, so each request carries a fresh `id`: the coordinator
/// performs every `id` exactly once — which is also what lets two
/// consecutive jumps target the same line.
struct EditorJump: Equatable {
    let id: UUID
    /// 0-based source line, counted the same way `MarkdownParser` counts
    /// lines for `outline` / `notes`.
    let line: Int
}

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    /// Optional caret request; `nil` means "no jump requested".
    var jump: EditorJump? = nil
    /// Called (on the next runloop turn) once `jump` has been performed, so
    /// the owner can clear the request from its state. The coordinator's own
    /// dedupe (`lastJumpID`) dies with the pane — if a performed request
    /// lingered in the owner's `@State` across an Edit → Preview → Edit
    /// round-trip, the recreated coordinator would replay it and yank the
    /// caret (and first responder) back, unprompted.
    var onJumpHandled: ((UUID) -> Void)? = nil
    /// The undo stack the editor should use instead of the window's. A
    /// document window leaves this nil — its window's undo manager is the
    /// `NSDocument`'s, which is also how the document tracks its edited
    /// state. The book workspace passes one scoped to the article being
    /// edited, so ⌘Z can never replay one article's keystrokes into
    /// another after the selection moves on.
    var undoOverride: UndoManager? = nil
    /// The Split view's pane link (see `ScrollSync`): the editor reports
    /// its scroll fraction here and follows the preview's.
    var scrollSync: ScrollSync? = nil

    func makeNSView(context: Context) -> NSScrollView {
        // `scrollableTextView()` gives a vertically-resizable text view
        // already embedded in a configured scroll view — the standard
        // macOS editor scaffold.
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false

        // Typewriter face, ink text, accent caret.
        textView.font = Typewriter.editorFont()
        textView.textColor = Typewriter.inkNSColor
        textView.insertionPointColor = Typewriter.accentNSColor
        // Newly typed text inherits these too.
        textView.typingAttributes = [
            .font: Typewriter.editorFont(),
            .foregroundColor: Typewriter.inkNSColor
        ]

        // Paper shows through from the SwiftUI container behind the editor.
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false

        // This is Markdown *source*: keep punctuation literal so the smart
        // substitutions don't turn `"` into curly quotes or `--` into an
        // en-dash and corrupt the syntax.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        // Comfortable margins; flush the text to the inset's left edge.
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.lineFragmentPadding = 0

        textView.string = text
        context.coordinator.textView = textView

        // Report scrolling for the Split view's pane sync. The clip view's
        // bounds move on every scroll (user or programmatic); the
        // coordinator's flag tells the two apart.
        scrollView.contentView.postsBoundsChangedNotifications = true
        let coordinator = context.coordinator
        coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: nil) { [weak coordinator] _ in
                MainActor.assumeIsolated { coordinator?.editorScrolled() }
            }
        coordinator.registerScrollSync()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.registerScrollSync()
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only reassign on a genuine *external* change (revert, open, a
        // programmatic edit) — never on our own keystroke echo, which would
        // yank the caret to the end. Preserve the selection across the swap.
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            let location = min(selected.location, length)
            let len = min(selected.length, length - location)
            textView.setSelectedRange(NSRange(location: location, length: len))
        }

        // Perform a requested caret jump — exactly once per request id. The
        // actual move is deferred one runloop turn: a jump can arrive in the
        // very update that *creates* this view (a Notes jump switches a
        // preview-only window into Edit first), and until the text view is
        // in a window `scrollRangeToVisible` / `makeFirstResponder` are
        // no-ops.
        if let jump, context.coordinator.lastJumpID != jump.id {
            context.coordinator.lastJumpID = jump.id
            let coordinator = context.coordinator
            let onHandled = onJumpHandled
            DispatchQueue.main.async {
                coordinator.moveCaret(toLine: jump.line)
                // Report consumption only now, outside the view update —
                // mutating SwiftUI state mid-update is illegal — so the
                // owner can clear the one-shot request for good.
                onHandled?(jump.id)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?
        /// The last `EditorJump.id` already performed (see `updateNSView`).
        var lastJumpID: UUID?
        /// Observes the clip view's bounds for the scroll sync.
        var scrollObserver: NSObjectProtocol?
        /// True while a scroll relayed *from* the preview is being applied,
        /// so it isn't reported straight back (the feedback loop guard —
        /// clip-view notifications are synchronous, which is what makes a
        /// plain flag sufficient).
        private var applyingRemoteScroll = false

        init(_ parent: MarkdownEditor) { self.parent = parent }

        deinit {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        /// (Re-)hand the sync our "follow the preview" closure. Called
        /// from make and update: pane recreation (a mode round-trip, a
        /// book article switch) must always leave the *live* coordinator
        /// registered.
        @MainActor func registerScrollSync() {
            parent.scrollSync?.scrollEditor = { [weak self] fraction in
                self?.applyScrollFraction(fraction)
            }
        }

        /// The scrollable range's geometry: nil when there is nothing to
        /// scroll (content fits the viewport).
        @MainActor private func scrollGeometry() -> (scrollView: NSScrollView, maxOffset: CGFloat)? {
            guard let scrollView = textView?.enclosingScrollView else { return nil }
            let maxOffset = (scrollView.documentView?.frame.height ?? 0)
                - scrollView.contentView.bounds.height
            guard maxOffset > 0 else { return nil }
            return (scrollView, maxOffset)
        }

        /// A bounds change that isn't our own doing: report the fraction.
        @MainActor func editorScrolled() {
            guard !applyingRemoteScroll, parent.scrollSync != nil,
                  let (scrollView, maxOffset) = scrollGeometry() else { return }
            let fraction = scrollView.contentView.bounds.origin.y / maxOffset
            parent.scrollSync?.editorDidScroll(to: min(max(fraction, 0), 1))
        }

        /// Follow the preview to `fraction` of the scrollable range.
        @MainActor func applyScrollFraction(_ fraction: CGFloat) {
            guard let (scrollView, maxOffset) = scrollGeometry() else { return }
            applyingRemoteScroll = true
            let origin = NSPoint(x: scrollView.contentView.bounds.origin.x,
                                 y: min(max(fraction, 0), 1) * maxOffset)
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            applyingRemoteScroll = false
        }

        /// Push the text view's current contents back through the binding —
        /// this is what marks the document dirty → autosave.
        @MainActor func sync() {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
        }

        func textDidChange(_ notification: Notification) { sync() }

        /// The editor's undo stack: the owner's override when one was
        /// passed, else the window's — the same manager `NSTextView` would
        /// have resolved on its own, so document windows are unaffected.
        func undoManager(for view: NSTextView) -> UndoManager? {
            parent.undoOverride ?? view.window?.undoManager
        }

        /// Move the caret to the start of a 0-based source line, scroll it
        /// into view, and focus the editor so typing continues right there.
        @MainActor func moveCaret(toLine line: Int) {
            guard let textView else { return }
            let caret = NSRange(location: Self.offset(ofLine: line, in: textView.string),
                                length: 0)
            textView.setSelectedRange(caret)
            textView.scrollRangeToVisible(caret)
            textView.window?.makeFirstResponder(textView)
        }

        /// UTF-16 offset of the first character of `line` (0-based). Line
        /// breaks are counted exactly the way `MarkdownParser` normalises
        /// them — `\n`, `\r\n` and a bare `\r` each end one line — so parser
        /// line numbers land on the right spot even in a CRLF file.
        /// (`NSString.lineRange(for:)` is deliberately not used: it also
        /// breaks at U+2028 / U+2029, which the parser does not.)
        static func offset(ofLine line: Int, in string: String) -> Int {
            let ns = string as NSString
            var offset = 0
            var remaining = line
            var i = 0
            while remaining > 0, i < ns.length {
                let ch = ns.character(at: i)
                i += 1
                if ch == 0x0A {                               // \n
                    remaining -= 1; offset = i
                } else if ch == 0x0D {                        // \r or \r\n
                    if i < ns.length, ns.character(at: i) == 0x0A { i += 1 }
                    remaining -= 1; offset = i
                }
            }
            // Asked for a line past the end? Stay at the start of the last
            // line that exists — the closest sensible spot.
            return offset
        }
    }
}
