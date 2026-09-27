//
//  SmartTextView.swift
//  md
//
//  Created by nettrash on 22/09/2026.
//
//  The editor's `NSTextView`: the thin AppKit shell around the typing rules
//  (`SmartTyping.swift`, the two pure functions) and the adapter decisions
//  (`SmartTypingAdapter.swift`, the word-insertion reduction and the
//  tracked-capital state machine). Everything that needs a text view is
//  here and nothing else is — specification §3.3 "macOS", §3.4, §3.5, §3.6.
//
//  Three responder / input-client entry points are overridden:
//
//  * `insertNewline(_:)` — Return. With Shift held (the event is read off
//    `NSApp.currentEvent`: Shift-Return has no binding of its own in
//    `StandardKeyBinding.dict` and falls through here), inside marked text,
//    or with the setting off, it is the system's plain newline. Otherwise
//    `SmartTyping.enter` decides, and its edit is applied through
//    `insertText(_:replacementRange:)` — one typing step, one undo step —
//    followed by the caret it asks for.
//  * `insertLineBreak(_:)` (Control-Return) and `insertParagraphSeparator(_:)`
//    — the system inserts U+2028 / U+2029 there, which md's parser does not
//    treat as a line end. Always a plain `"\n"`.
//  * `insertText(_:replacementRange:)` — every keystroke, dead-key commit,
//    accent-popover pick, predicted word and dictated phrase. Whatever the
//    system hands in, `String` or `NSAttributedString`, goes through the
//    word-insertion reduction; a word insertion is inserted as typed and
//    its first scalar then replaced by the capital `capitalize` returns, as
//    a **separate undo step** (§3.5): `breakUndoCoalescing()` on both sides
//    of the replacement, and the event's undo group split in two, so that
//    ⌘Z right after a capital restores the lowercase letter and keeps the
//    caret.
//
//  WHERE THE OVERRIDE LEARNS ABOUT EVERY EDIT (§3.4)
//  ------------------------------------------------
//  The override follows the last capital md produced through whatever
//  happens to the text — a Cut before it moves it, Backspace over it
//  removes it and arms the gesture where it stood — and most edits never
//  come through `insertText`: Backspace, forward delete, Cut, Paste, a
//  drop, Undo and Redo all edit the text storage directly. The one place
//  every edit passes through is the `NSTextStorage`, so the view is its
//  storage's delegate and reads each edit off
//  `textStorage(_:didProcessEditing:range:changeInLength:)`, after it
//  happened, into `CapitalOverride.edit`. Only the capital swap this file
//  makes itself is skipped there (`isApplyingOwnEdit`): it is not an
//  insertion, and `produced(at:capital:)` records it. The typed text
//  itself is observed like anything else; the transition it makes was
//  already made by `insertion(…)` before the edit, and the observation
//  changes nothing more. Being the storage's delegate reads; it never
//  edits, so undo grouping is exactly `NSTextView`'s.
//
//  Undo of a capital (§3.5) is the view's own text undo, which the storage
//  delegate sees as the edit that removed the capital: it arms the
//  override at `p`, and the restored letter is not re-judged (nothing
//  comes through `insertText`). What the undo group carries besides the
//  text edit is bookkeeping only: a closure that registers Redo's
//  counterpart, which tracks the capital again before Redo's text edit
//  puts it back — so the delegate sees the same scalar return to the same
//  offset and leaves the tracking alone (`registerCapitalUndone`,
//  `registerCapitalRedone`).
//
//  The same closures also put the caret back. The capital is applied as a
//  *replacement* — `insertText` over the one-scalar range of the letter —
//  and `NSTextView` undoes a replacement the way it undoes select-and-type:
//  the text it restores comes back *selected*. Measured in the running app
//  (a document window, ⌘Z right after `z` → `Z`): the `z` came back as a
//  one-character selection, and the next letter typed replaced it, so a
//  writer who undid a capital and kept typing lost the letter. A hosted
//  view with no window keeps a caret and never showed it. The undo closure
//  therefore notes where the caret belongs — after the restored letter —
//  and the redo closure after the restored capital; the caret is placed
//  when the undo manager reports the whole undo (or redo) done
//  (`NSUndoManagerDidUndoChange` / `DidRedoChange`), which is after the
//  text system has restored its selection. Not inside the closure: on undo
//  it would work, on redo the text edit runs *after* the closure and would
//  overwrite it.
//
//  The dead-key and popover cases (§3.3): a dead-key session (`´` + `e`)
//  commits through `insertText` with the marked text still in place and no
//  explicit range, so the marked range is the selection; the press-and-hold
//  accent popover replaces one scalar by one scalar with an explicit range.
//  Both are one-scalar insertions over a range, so `école` at a sentence
//  start becomes `École`. Neither range is a selection the writer made, so
//  neither is the select-and-retype of §3.4: the pick over the `E` md just
//  made goes through `capitalize` again and md produces `É` — the tracked
//  capital, replaced. A pick that replaces a *lowercase* letter — one the
//  rule declined, or one the override let stand — keeps it (`é`). A CJK
//  composition also commits here, as a scalar without case, which the pure
//  function declines.
//
//  Settings are read from `UserDefaults` at the keystroke (`TypingSettings`),
//  so View ▸ Typing takes effect in every open editor at once; `defaults` is
//  a property only so the tests can hand in a store of their own.
//

import AppKit

final class SmartTextView: NSTextView, NSTextStorageDelegate {

    /// Where the two typing toggles are read from. `.standard` in the app;
    /// the tests substitute a suite of their own.
    var defaults: UserDefaults = .standard

    /// §3.4 — the tracked capital and the delete-and-retype override.
    /// Read-only outside; the tests inspect it.
    private(set) var capitalOverride = CapitalOverride()

    /// Set while this file swaps a letter for its capital: the storage
    /// delegate leaves that edit to `applyCapital`, which records it.
    private var isApplyingOwnEdit = false

    /// Where the caret belongs once the undo (or redo) of a capital's step
    /// has finished — set by the step's closures, consumed when the undo
    /// manager reports the undo done. See the header.
    private var caretAfterUndoRedo: Int?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        observeTextStorage()
    }

    /// The variant that builds the text network itself (`scrollableTextView()`
    /// and the tests come through here); it chains to the designated one,
    /// so the observer is installed either way.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observeTextStorage()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeTextStorage()
    }

    /// Every edit to the text, whoever makes it, passes through the
    /// storage; the override's bookkeeping reads them there (§3.4). AppKit
    /// leaves this delegate to the app (a test pins that).
    private func observeTextStorage() {
        textStorage?.delegate = self
        // The end of an undo or a redo, whichever manager it ran on — the
        // window's, the document's or the book's per-article one; the
        // handler checks it is this view's. Selector-based, so AppKit
        // unregisters the observer when the view goes away.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(undoManagerDidUndoOrRedo(_:)),
                           name: .NSUndoManagerDidUndoChange, object: nil)
        center.addObserver(self, selector: #selector(undoManagerDidUndoOrRedo(_:)),
                           name: .NSUndoManagerDidRedoChange, object: nil)
    }

    /// An undo or redo finished: if it was a capital's step, the text
    /// system has just restored the letter (or the capital) selected — put
    /// a caret after it instead (§3.5 "keeps the caret").
    @objc private func undoManagerDidUndoOrRedo(_ notification: Notification) {
        guard let caret = caretAfterUndoRedo else { return }
        caretAfterUndoRedo = nil
        guard let manager = notification.object as? UndoManager, manager === undoManager else { return }
        let length = (string as NSString).length
        setSelectedRange(NSRange(location: min(caret, length), length: 0))
    }

    /// A wholesale replacement (`updateNSView` after a revert or reload; the
    /// book workspace also recreates the view per article, which resets the
    /// whole object) is an external replacement: the tracked capital and
    /// the override both go (§3.4). `MarkdownEditor.replaceWholeText`
    /// calls this straight after the edit.
    ///
    /// It is deliberately a method and not a `string` property override.
    /// Overriding `string` in Swift — with a `didSet`, or with explicit
    /// accessors that call `super` — stops AppKit invalidating the cached
    /// match ranges `NSTextFinder` holds for this client, and the find bar
    /// then works on text that is gone: ⌘G finds nothing, Replace All
    /// rewrites at the stale offsets, and when the new text is shorter it
    /// throws `NSRangeException` out of `NSMutableRLEArray` and takes the
    /// app with it. Measured on this AppKit, in a debug build, against a
    /// plain `NSTextView` as the control.
    func clearCapitalTracking() {
        capitalOverride.clear()
    }

    // MARK: - Return (§1, §3.6)

    override func insertNewline(_ sender: Any?) {
        if NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) == true
            || hasMarkedText()
            || !TypingSettings.continueLists(in: defaults) {
            super.insertNewline(sender)
            return
        }
        let selection = selectedRange()
        guard let edit = SmartTyping.enter(string, selectionStart: selection.location,
                                           selectionEnd: NSMaxRange(selection)) else {
            super.insertNewline(sender)
            return
        }
        // One typing step, exactly as a key would insert it — and one undo
        // step of its own (§3.5), not folded into the typing run around
        // it, so ⌘Z right after Return takes back exactly what Return did
        // (the marker it added, or the empty item it removed). The edit's
        // own caret may sit inside the replacement (a table row's first
        // cell), so it is placed explicitly afterwards.
        breakUndoCoalescing()
        insertText(edit.replacement, replacementRange: NSRange(location: edit.location, length: edit.length))
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: edit.caret, length: 0))
    }

    /// Control-Return. Never U+2028.
    override func insertLineBreak(_ sender: Any?) {
        insertText("\n", replacementRange: selectedRange())
    }

    /// Never U+2029 either — the parser ends lines at LF, CR LF and CR only.
    override func insertParagraphSeparator(_ sender: Any?) {
        insertText("\n", replacementRange: selectedRange())
    }

    // MARK: - Letters (§2, §3.3, §3.4, §3.5)

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let insertion = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        // The range this insertion replaces, per NSTextInputClient: an
        // explicit range wins; without one, the marked text if any (a
        // dead-key session ending), else the selection. Only the last is
        // a selection the writer made.
        let target: NSRange
        let explicitRange = replacementRange.location != NSNotFound
        let writerSelected: Bool
        if explicitRange {
            target = replacementRange
            writerSelected = false
        } else if hasMarkedText() {
            target = markedRange()
            writerSelected = false
        } else {
            target = selectedRange()
            writerSelected = true
        }

        let wordInsertion = SmartTypingAdapter.wordInsertionLeadLength(insertion) != nil
        // §3.4's independent rule first: a single lowercase letter typed
        // over its own capital is as typed, override or no override. It is
        // decided without the state machine; the edit it makes is observed
        // by the storage delegate like any other, which is what arms the
        // override when the capital it replaced was the tracked one.
        let retypesOwnCapital = writerSelected && wordInsertion
            && SmartTypingAdapter.retypesOwnCapital(text: self.string,
                                                    selectionStart: target.location,
                                                    selectionEnd: NSMaxRange(target),
                                                    insertion: insertion)
        // Then the override, on the text as it still is: is this the
        // retype it is armed for — or the word typed over a selection that
        // takes the tracked capital with it?
        let retyped = !retypesOwnCapital
            && capitalOverride.insertion(at: target.location,
                                         selectionLength: writerSelected ? target.length : 0,
                                         wordInsertion: wordInsertion)
        // The popover pick over a lowercase letter keeps it (§3.3): the
        // letter stood lowercase because the rule declined it or because
        // the override was honoured, and the pick must not undo either.
        let keepsLowercase = explicitRange
            && SmartTypingAdapter.replacesOneLowercaseScalar(text: self.string,
                                                             selectionStart: target.location,
                                                             selectionEnd: NSMaxRange(target),
                                                             insertion: insertion)
        var decision: SmartTypingAdapter.Decision?
        if wordInsertion, !retypesOwnCapital, !retyped, !keepsLowercase,
           TypingSettings.capitalizeSentences(in: defaults) {
            decision = SmartTypingAdapter.capital(text: self.string,
                                                  selectionStart: target.location,
                                                  selectionEnd: NSMaxRange(target),
                                                  insertion: insertion)
        }

        // As typed, coalesced into the typing run like any keystroke. The
        // storage delegate sees it land.
        super.insertText(string, replacementRange: replacementRange)

        guard let decision else { return }
        applyCapital(decision, at: target.location, insertionLength: insertion.utf16.count)
    }

    /// Replace the first scalar of the insertion just made at `location`
    /// with its capital, as an undo step of its own (§3.5), and track it
    /// (§3.4).
    private func applyCapital(_ decision: SmartTypingAdapter.Decision, at location: Int,
                              insertionLength: Int) {
        breakUndoCoalescing()
        let undoManager = allowsUndo ? undoManager : nil
        // The letter and its capital were made in one event, which the undo
        // manager would otherwise fold into one group: close that group
        // here and open the next, so ⌘Z peels the capital off first. (The
        // event's end closes the group opened here exactly as it would have
        // closed the one it opened itself; a caller grouping by hand closes
        // it with its own `endUndoGrouping()` — the count is unchanged.)
        if let undoManager, undoManager.groupingLevel == 1 {
            undoManager.endUndoGrouping()
            undoManager.beginUndoGrouping()
        }
        let capital = Array(decision.capital.utf16)
        // Registered before the text edit so that it runs after that edit's
        // undo (see the header).
        if let undoManager, undoManager.isUndoRegistrationEnabled {
            registerCapitalUndone(with: undoManager, at: location, capital: capital,
                                  leadLength: decision.leadLength, insertionLength: insertionLength)
        }
        isApplyingOwnEdit = true
        super.insertText(decision.capital, replacementRange: NSRange(location: location, length: decision.leadLength))
        isApplyingOwnEdit = false
        breakUndoCoalescing()
        // The caret goes to the end of the whole insertion — the same place
        // for a single letter, past the rest of the word for a word.
        let end = location + capital.count + insertionLength - decision.leadLength
        setSelectedRange(NSRange(location: end, length: 0))
        capitalOverride.produced(at: location, capital: capital)
    }

    // MARK: - Undo bookkeeping (§3.5)

    /// The undo side of a capital's step. When it runs, the step's text
    /// edit has already put the lowercase letter back — selected, which is
    /// how `NSTextView` undoes a replacement — and the storage delegate has
    /// armed the override at `location` (§3.4); what is left is to give
    /// Redo its counterpart and to note where the caret goes: where it was
    /// before the capital, at the end of the insertion as typed — after
    /// the letter, or after the whole word of a word insertion.
    private func registerCapitalUndone(with undoManager: UndoManager, at location: Int,
                                       capital: [UInt16], leadLength: Int, insertionLength: Int) {
        undoManager.registerUndo(withTarget: self) { view in
            view.caretAfterUndoRedo = location + insertionLength
            guard let undoManager = view.undoManager else { return }
            view.registerCapitalRedone(with: undoManager, at: location, capital: capital,
                                       leadLength: leadLength, insertionLength: insertionLength)
        }
    }

    /// The redo side: Redo is about to put the capital back (its text edit
    /// runs after this closure), so it is md's capital once more — tracked
    /// at `location` before the delegate sees the same scalar return to
    /// the same offset. Then the undo side is registered again, and the
    /// caret noted for where `applyCapital` left it: the end of the whole
    /// insertion with its capital in place.
    private func registerCapitalRedone(with undoManager: UndoManager, at location: Int,
                                       capital: [UInt16], leadLength: Int, insertionLength: Int) {
        undoManager.registerUndo(withTarget: self) { view in
            view.capitalOverride.produced(at: location, capital: capital)
            view.caretAfterUndoRedo = location + capital.count + insertionLength - leadLength
            guard let undoManager = view.undoManager else { return }
            view.registerCapitalUndone(with: undoManager, at: location, capital: capital,
                                       leadLength: leadLength, insertionLength: insertionLength)
        }
    }

    // MARK: - Every edit, read off the text storage (§3.4)

    /// The bookkeeping for whatever changed the characters — a keystroke,
    /// Backspace, forward delete, Cut, Paste, a drop, Undo, Redo, the
    /// Return edit. The edit is reported on the text *after* it:
    /// `editedRange` is the new text's extent, `delta` the change in
    /// length, so the original range began at `editedRange.location` and
    /// was `editedRange.length - delta` units long.
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isApplyingOwnEdit else { return }
        let original = NSRange(location: editedRange.location, length: editedRange.length - delta)
        capitalOverride.edit(replacing: original, insertedLength: editedRange.length,
                             textAfter: textStorage.mutableString)
    }
}
