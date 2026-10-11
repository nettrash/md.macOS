//
//  EditorFormatting.swift
//  md
//
//  The formatting commands on the Mac: the Format menu's rows and chords, the
//  setting for the typed wrap, and the one way an edit is applied to the
//  editor so that it is a single Undo step.
//
//  The rewriting itself is `MarkdownFormatting` (the same file as md for iPad
//  and iPhone, pinned by the family's `formatting-vectors.json`); this file
//  only carries it to an `NSTextView`.
//

import AppKit
import SwiftUI

/// The typed wrap's setting — Edit ▸ Typing ▸ Wrap Selection When Typing
/// * _ ` $ — under the same `UserDefaults` key every md app uses. Absent
/// means on.
enum FormattingSettings {
    static let wrapSelectionKey = "md.wrapSelection"

    static func wrapSelection(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: wrapSelectionKey) as? Bool ?? true
    }
}

/// The Format menu: every command, its title and its chord, in the menu's
/// order. One table, so the menu and the test that pins it against the
/// family's chords (md.win `docs/formatting.md` §5) read the same rows.
///
/// Two chords are Apple's own rather than the Windows table translated:
/// headings on ⌥⌘1–6 (decided 2026-10-10), and Quote on ⌘' — ⇧⌘Q is Log
/// Out in the Apple menu, which the system resolves before any app item.
enum FormatMenu {

    struct Row {
        let op: MarkdownFormatting.Op
        let title: String
        let key: KeyEquivalent
        let modifiers: EventModifiers
    }

    static let inline: [Row] = [
        Row(op: .bold, title: "Bold", key: "b", modifiers: .command),
        Row(op: .italic, title: "Italic", key: "i", modifiers: .command),
        Row(op: .code, title: "Code", key: "c", modifiers: [.command, .shift]),
        Row(op: .strikethrough, title: "Strikethrough", key: "x", modifiers: [.command, .shift]),
        Row(op: .link, title: "Link", key: "k", modifiers: .command),
    ]

    static let headings: [Row] = [
        Row(op: .heading1, title: "Heading 1", key: "1", modifiers: [.command, .option]),
        Row(op: .heading2, title: "Heading 2", key: "2", modifiers: [.command, .option]),
        Row(op: .heading3, title: "Heading 3", key: "3", modifiers: [.command, .option]),
        Row(op: .heading4, title: "Heading 4", key: "4", modifiers: [.command, .option]),
        Row(op: .heading5, title: "Heading 5", key: "5", modifiers: [.command, .option]),
        Row(op: .heading6, title: "Heading 6", key: "6", modifiers: [.command, .option]),
    ]

    static let blocks: [Row] = [
        Row(op: .bulletList, title: "Bullet List", key: "l", modifiers: [.command, .shift]),
        Row(op: .taskList, title: "Task List", key: "t", modifiers: [.command, .shift]),
        Row(op: .quote, title: "Quote", key: "'", modifiers: .command),
    ]

    static let indentation: [Row] = [
        Row(op: .indent, title: "Indent", key: "]", modifiers: .command),
        Row(op: .outdent, title: "Outdent", key: "[", modifiers: .command),
    ]

    static var all: [Row] { inline + headings + blocks + indentation }

    /// Run a command on the frontmost window's editor: the first responder
    /// when it is md's editor, else the window's editing pane. Nothing when
    /// the window shows no editor — there is no text on screen to format.
    @MainActor static func perform(_ op: MarkdownFormatting.Op) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let editor = (window.firstResponder as? SmartTextView) ?? DocumentCommands.firstEditor(in: window.contentView)
        guard let editor else { return }
        if window.firstResponder !== editor { window.makeFirstResponder(editor) }
        editor.applyFormatting(op)
    }
}

extension NSTextView {

    /// One formatting command over the selection, as one Undo step.
    func applyFormatting(_ op: MarkdownFormatting.Op) {
        guard !hasMarkedText() else { return }
        let selection = selectedRange()
        guard let edit = MarkdownFormatting.format(string, selectionStart: selection.location,
                                                   selectionEnd: NSMaxRange(selection), op: op) else { return }
        apply(edit, actionName: "Format")
    }

    /// The typed wrap, when it applies: `*`, `_`, a backtick or `$` typed
    /// over a selection, with the setting on. True when it wrapped.
    func wrapTypedIfEnabled(_ typed: String, defaults: UserDefaults = .standard) -> Bool {
        guard FormattingSettings.wrapSelection(in: defaults), !hasMarkedText() else { return false }
        let selection = selectedRange()
        guard selection.length > 0, let edit = MarkdownFormatting.wrapTyped(string, selectionStart: selection.location,
                                                      selectionEnd: NSMaxRange(selection), typed: typed) else { return false }
        apply(edit, actionName: "Typing")
        return true
    }

    /// Apply an edit the way `NSTextView` wants a programmatic change made —
    /// asked, replaced, announced — so it lands on the undo stack as one
    /// step and the document's binding hears of it like any keystroke.
    func apply(_ edit: MarkdownFormatting.Edit, actionName: String) {
        let range = NSRange(location: edit.start, length: edit.end - edit.start)
        // The group opens first: `shouldChangeText` is where the text view
        // registers its undo, and both must land in the one step.
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.setActionName(actionName)
            undoManager?.endUndoGrouping()
        }
        guard shouldChangeText(in: range, replacementString: edit.text) else { return }
        // A command is not the writer deleting the capital md just made: an
        // edit that takes it along (`Word` → `**Word**`) would arm the
        // delete-and-retype override (§3.4) where the word began, and the
        // next word typed there would skip the sentence rule. Only an
        // override this edit armed is dropped; one already armed, or a
        // capital the edit merely moves, is left as it was.
        let smart = self as? SmartTextView
        let wasArmed = smart?.capitalOverride.isArmed ?? false
        textStorage?.replaceCharacters(in: range, with: edit.text)
        if let smart, !wasArmed, smart.capitalOverride.isArmed { smart.clearCapitalTracking() }
        didChangeText()
        let selection = NSRange(location: edit.selectionStart, length: edit.selectionEnd - edit.selectionStart)
        setSelectedRange(selection)
        scrollRangeToVisible(selection)
    }
}
