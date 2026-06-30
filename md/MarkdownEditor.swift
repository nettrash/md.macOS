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

import SwiftUI
import AppKit

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
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
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?

        init(_ parent: MarkdownEditor) { self.parent = parent }

        /// Push the text view's current contents back through the binding —
        /// this is what marks the document dirty → autosave.
        @MainActor func sync() {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
        }

        func textDidChange(_ notification: Notification) { sync() }
    }
}
