//
//  SmartTextViewTests.swift
//  mdTests
//
//  The macOS typing adapter: the pure decisions in `SmartTypingAdapter.swift`
//  (the word-insertion reduction, the tracked-capital state machine, the
//  settings) and the `SmartTextView` shell around them, hosted off-screen —
//  an `NSTextView` needs no window to take `insertText`, `insertNewline`,
//  `deleteBackward`, `cut` or an undo manager.
//
//  The rules themselves are `SmartTyping.swift`'s and are pinned by the
//  1350 shared vectors in `SmartTypingTests.swift`; nothing here re-asserts
//  a rule. What is asserted is the glue the specification's §3 leaves to
//  each platform: which insertions reach `capitalize` and as what, how the
//  capital and the Return edit land in the view, that each is the undo step
//  §3.5 promises, that the delete-and-retype override (§3.4) behaves —
//  the eight consequences the amended rule lists are each a hosted test
//  here (`testConsequence1…8`), and the state machine behind them is
//  pinned on its own — that Control-Return never inserts U+2028, and that
//  the two toggles are honoured at the very next keystroke.
//
//  Every string comparison goes through UTF-16 units: a Swift `String`
//  compares by canonical equivalence, which would let an NFD `É` pass for
//  the NFC one the rules produce.
//
//  UNDO, AND WHAT THIS FILE CANNOT SHOW
//  ------------------------------------
//  In the running app the undo manager opens a group at an event's first
//  registration and the event's end closes it. A hosted test runs *inside*
//  one event and never finishes one, so no run-loop spin here closes a
//  group; the undo tests therefore drive a manager with `groupsByEvent`
//  off and open and close one group per keystroke themselves. That shows
//  the two steps a capital makes and what Undo restores, but not
//  `NSTextView`'s coalescing of a typing run across events (a closed group
//  ends a run). The by-event behaviour — one ⌘Z peels the capital, the
//  next removes the whole run it was typed into, Return is a step of its
//  own — was verified by driving `SmartTextView` with posted key events
//  through a real `NSApplication.run` loop (the `liveapp` probe in the
//  work log), which is the only faithful harness for it.
//

import XCTest
import AppKit
import SwiftUI
@testable import md

final class SmartTextViewTests: XCTestCase {

    // MARK: - Fixtures

    /// A defaults store of its own per test, so nothing here reads or
    /// disturbs the real app's Edit ▸ Typing toggles.
    private func makeDefaults() throws -> UserDefaults {
        let name = "md.typing.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// An off-screen editor with its own settings store (both rules on
    /// unless told otherwise) and no undo manager unless a host is set.
    /// Replace the whole of a fixture's text the way the app does — a
    /// revert, a "Reload from Disk", a book article switch — through
    /// `MarkdownEditor.replaceWholeText`, which is also what clears the
    /// tracked capital and the armed override (§3.4). Plain `string`
    /// assignment deliberately no longer clears anything: overriding
    /// `string` on an `NSTextView` is what left `NSTextFinder` holding
    /// stale match ranges (see `SmartTextView.clearCapitalTracking`), so
    /// the bookkeeping moved to the replacement itself.
    private func reload(_ view: SmartTextView, to text: String) {
        MarkdownEditor.replaceWholeText(of: view, with: text)
    }

    private func makeView(continueLists: Bool = true, capitalize: Bool = true) throws -> SmartTextView {
        let view = SmartTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.isRichText = false
        let defaults = try makeDefaults()
        defaults.set(continueLists, forKey: TypingSettings.continueListsKey)
        defaults.set(capitalize, forKey: TypingSettings.capitalizeSentencesKey)
        view.defaults = defaults
        return view
    }

    /// The delegate `MarkdownEditor`'s coordinator plays in the app: it
    /// hands the view its undo manager (a window's, or the book's
    /// per-article one).
    private final class UndoHost: NSObject, NSTextViewDelegate {
        let undoManager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
    }

    private let noRange = NSRange(location: NSNotFound, length: 0)

    private func units(_ s: String) -> [UInt16] { Array(s.utf16) }

    /// One keystroke's worth of undo grouping. In the running app the undo
    /// manager opens a group at the first registration of an event and the
    /// event's end closes it; a hosted test never finishes an event of its
    /// own (it runs inside one), so the test plays the event loop: a group
    /// around each keystroke, closed after it — which is also what closes
    /// the second group `SmartTextView` opens for the capital.
    private func keystroke(_ host: UndoHost, _ body: () -> Void) {
        host.undoManager.beginUndoGrouping()
        body()
        while host.undoManager.groupingLevel > 0 { host.undoManager.endUndoGrouping() }
    }

    /// An undo manager driven as `keystroke` needs it: groups opened by the
    /// test, never by the run loop.
    private func makeHost() -> UndoHost {
        let host = UndoHost()
        host.undoManager.groupsByEvent = false
        return host
    }

    /// Type `text` as one `insertText` call over the selection.
    private func type(_ text: String, into view: SmartTextView) {
        view.insertText(text, replacementRange: noRange)
    }

    /// `cut(nil)` writes to the general pasteboard — the machine's
    /// clipboard. Snapshot it and put it back on teardown, every item and
    /// every type, so a test run leaves the clipboard as it found it.
    private func preservingGeneralPasteboard() {
        let pasteboard = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var byType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { byType[type] = data }
            }
            return byType
        }
        addTeardownBlock {
            pasteboard.clearContents()
            let items: [NSPasteboardItem] = saved.map { byType in
                let item = NSPasteboardItem()
                for (type, data) in byType { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    /// A paste or a drop as `NSTextView` lands it: through the
    /// `shouldChangeText` / storage / `didChangeText` protocol, never
    /// through `insertText`.
    private func pasteLike(_ text: String, over range: NSRange, into view: SmartTextView) throws {
        XCTAssertTrue(view.shouldChangeText(in: range, replacementString: text))
        try XCTUnwrap(view.textStorage).replaceCharacters(in: range, with: text)
        view.didChangeText()
    }


    // MARK: - Word-insertion reduction (§3.3)

    func testWordInsertionLeadLength() {
        // Word insertions: a letter, a word, a word with one trailing space,
        // an accented letter, a supplementary-plane letter (two units).
        XCTAssertEqual(SmartTypingAdapter.wordInsertionLeadLength("h"), 1)
        XCTAssertEqual(SmartTypingAdapter.wordInsertionLeadLength("hello"), 1)
        XCTAssertEqual(SmartTypingAdapter.wordInsertionLeadLength("hello "), 1)
        XCTAssertEqual(SmartTypingAdapter.wordInsertionLeadLength("école"), 1)
        XCTAssertEqual(SmartTypingAdapter.wordInsertionLeadLength("\u{10428}x"), 2)   // DESERET SMALL LETTER LONG I
        XCTAssertEqual(SmartTypingAdapter.wordInsertionLeadLength("don't"), 1)
        XCTAssertEqual(SmartTypingAdapter.wordInsertionLeadLength("x."), 1)

        // Not word insertions.
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength(""))
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("Hello"), "uppercase lead")
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("1st"), "digit lead")
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("\u{0301}a"), "mark lead")
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("\u{1F600}x"), "symbol lead")
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("hello world"), "an inner space")
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("hello  "), "two trailing spaces")
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("hello\t"), "a trailing TAB is not SP")
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("hello\u{00A0}"), "NBSP is WS19, not SP")
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("a\u{200B}b"), "ZWSP is WS19")
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("hello\n"), "a line terminator")
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("hello\r"), "a line terminator")
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("https://a.b"), "a URL")
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("www.nettrash.me"), "a bare host")
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("nettrash@nettrash.me"), "an address")
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("~/Documents/x"), "a path")
        XCTAssertNil(SmartTypingAdapter.wordInsertionLeadLength("a/b"), "a slash anywhere")
        // A Swift `String` cannot hold a lone surrogate half; the unit walk
        // underneath still has to decline one (a scalar of no class).
        XCTAssertNil(SmartTypingAdapter.firstScalar(of: [0xD83D], at: 0), "a lone high half")
        XCTAssertNil(SmartTypingAdapter.firstScalar(of: [0xDE00], at: 0), "a lone low half")
        XCTAssertNil(SmartTypingAdapter.firstScalar(of: [0xD83D, 0x0061], at: 0), "a high half before a letter")
        // U+2028 and U+2029 are ordinary units to the rules (§0.1), so a
        // word carrying one is still a word insertion; the lead decides.
        XCTAssertEqual(SmartTypingAdapter.wordInsertionLeadLength("a\u{2028}"), 1)
    }

    func testUpperIsTheSpecificationsMapping() {
        // The adapter's `upper` must be the same guarded one-scalar mapping
        // `capitalize` applies. On an empty document rule A always applies,
        // so `capitalize("", 0, 0, typed)` *is* `upper(typed)` or nil.
        let sample: [Unicode.Scalar] = ["h", "é", "ß", "µ", "ǆ", "ı", "ﬁ", "ა", "ᾳ", "\u{10428}", "1", "A", "ж", "ω"]
        for scalar in sample {
            let typed = String(scalar)
            let expected = SmartTyping.capitalize("", selectionStart: 0, selectionEnd: 0, typed: typed)
            let actual = SmartTypingAdapter.upper(scalar).map { String($0) }
            XCTAssertEqual(actual.map(units), expected.map(units), "upper(\(typed))")
        }
        XCTAssertEqual(SmartTypingAdapter.upper("h"), "H")
        XCTAssertEqual(SmartTypingAdapter.upper("\u{10428}"), "\u{10400}")
        XCTAssertNil(SmartTypingAdapter.upper("ß"), "full mapping is two scalars")
        XCTAssertNil(SmartTypingAdapter.upper("µ"), "MICRO SIGN is excluded")
        XCTAssertNil(SmartTypingAdapter.upper("ა"), "Georgian is excluded")
        XCTAssertNil(SmartTypingAdapter.upper("ᾳ"), "ypogegrammeni is excluded")
    }

    // MARK: - The tracked-capital state machine (§3.4)

    private func after(_ text: String) -> NSString { text as NSString }

    func testProducedCapitalIsTrackedAndEditsAroundItMoveIt() {
        var override = CapitalOverride()
        XCTAssertFalse(override.tracksCapital)
        XCTAssertFalse(override.isArmed)

        // "Say md" typed: the capital sits at 4.
        override.produced(at: 4, capital: units("M"))
        XCTAssertTrue(override.tracksCapital(at: 4))
        XCTAssertFalse(override.tracksCapital(at: 5))
        XCTAssertFalse(override.isArmed)

        // An edit after the capital changes nothing: "Say Md" → "Say Md is".
        override.edit(replacing: NSRange(location: 5, length: 0), insertedLength: 3, textAfter: after("Say Md is"))
        XCTAssertTrue(override.tracksCapital(at: 4))
        // A deletion right after it neither: the `d` goes.
        override.edit(replacing: NSRange(location: 5, length: 1), insertedLength: 0, textAfter: after("Say M is"))
        XCTAssertTrue(override.tracksCapital(at: 4))

        // An insertion before it shifts it by the inserted length …
        override.edit(replacing: NSRange(location: 0, length: 0), insertedLength: 2, textAfter: after("- Say M is"))
        XCTAssertTrue(override.tracksCapital(at: 6))
        // … a deletion before it shifts it back — one ending exactly at
        // `p` included …
        override.edit(replacing: NSRange(location: 5, length: 1), insertedLength: 0, textAfter: after("- SayM is"))
        XCTAssertTrue(override.tracksCapital(at: 5))
        // … a replacement before it by its length delta …
        override.edit(replacing: NSRange(location: 0, length: 2), insertedLength: 5, textAfter: after("1.   SayM is"))
        XCTAssertTrue(override.tracksCapital(at: 8))
        // … and an insertion AT `p` puts the capital after the new text
        // (consequence 5: the caret before the `M`, a letter typed).
        override.edit(replacing: NSRange(location: 8, length: 0), insertedLength: 1, textAfter: after("1.   SayaM is"))
        XCTAssertTrue(override.tracksCapital(at: 9))
        XCTAssertFalse(override.isArmed)

        // A new capital replaces the tracked one; the old one is forgotten,
        // not armed.
        override.produced(at: 8, capital: units("A"))
        XCTAssertTrue(override.tracksCapital(at: 8))
        XCTAssertFalse(override.isArmed)

        // A two-unit capital is tracked whole.
        override.produced(at: 0, capital: units("\u{10400}"))
        override.edit(replacing: NSRange(location: 2, length: 0), insertedLength: 1, textAfter: after("\u{10400}x"))
        XCTAssertTrue(override.tracksCapital(at: 0))
        override.edit(replacing: NSRange(location: 0, length: 2), insertedLength: 0, textAfter: after("x"))
        XCTAssertFalse(override.tracksCapital)
        XCTAssertTrue(override.isArmed(at: 0))
    }

    func testRemovingTheCapitalArmsTheOverrideWhereTheEditBegan() {
        var override = CapitalOverride()

        // Backspace over it: armed at `p`.
        override.produced(at: 4, capital: units("M"))
        override.edit(replacing: NSRange(location: 4, length: 1), insertedLength: 0, textAfter: after("Say "))
        XCTAssertFalse(override.tracksCapital)
        XCTAssertTrue(override.isArmed(at: 4))

        // A deletion reaching back over it from before: armed at the
        // deletion's start, not at `p`.
        override.produced(at: 4, capital: units("M"))
        override.edit(replacing: NSRange(location: 2, length: 4), insertedLength: 0, textAfter: after("Sa"))
        XCTAssertTrue(override.isArmed(at: 2))

        // A replacement covering it: armed at the replacement's start
        // (select the word and type: consequence 4's edit).
        override.produced(at: 4, capital: units("M"))
        override.edit(replacing: NSRange(location: 4, length: 2), insertedLength: 2, textAfter: after("Say md"))
        XCTAssertTrue(override.isArmed(at: 4))

        // Undo that restores the lowercase letter is such a replacement
        // (consequence 6): armed at `p`.
        override.produced(at: 0, capital: units("M"))
        override.edit(replacing: NSRange(location: 0, length: 1), insertedLength: 1, textAfter: after("m"))
        XCTAssertTrue(override.isArmed(at: 0))
        XCTAssertFalse(override.tracksCapital)

        // Unless the inserted text puts the same capital back at the same
        // offset (Redo does): still tracked, nothing armed.
        override.produced(at: 0, capital: units("M"))
        override.edit(replacing: NSRange(location: 0, length: 1), insertedLength: 1, textAfter: after("M"))
        XCTAssertTrue(override.tracksCapital(at: 0))
        XCTAssertFalse(override.isArmed)
        // A replacement of the whole word that keeps the capital in place
        // is not a removal either.
        override.edit(replacing: NSRange(location: 0, length: 1), insertedLength: 5, textAfter: after("Mello"))
        XCTAssertTrue(override.tracksCapital(at: 0))
        // But a deletion that happens to leave the same letter at `p`
        // removed the capital: nothing was put back.
        override.produced(at: 0, capital: units("M"))
        override.edit(replacing: NSRange(location: 0, length: 1), insertedLength: 0, textAfter: after("M"))
        XCTAssertTrue(override.isArmed(at: 0))
        // And a replacement that puts the capital back at another offset
        // removed it too.
        override.produced(at: 1, capital: units("M"))
        override.edit(replacing: NSRange(location: 0, length: 2), insertedLength: 1, textAfter: after("M"))
        XCTAssertTrue(override.isArmed(at: 0))

        // A two-unit capital: a range that splits it removes it (the text
        // after is then a lone high half and an `x`, which no `String`
        // literal can spell: built unit by unit).
        override.produced(at: 0, capital: units("\u{10400}"))
        let split: [unichar] = [0xD801, 0x0078]
        override.edit(replacing: NSRange(location: 1, length: 1), insertedLength: 1,
                      textAfter: NSString(characters: split, length: split.count))
        XCTAssertTrue(override.isArmed(at: 1))
    }

    func testWhileArmedDeletionsMoveItInsertionsElsewhereClearIt() {
        var override = CapitalOverride()
        override.produced(at: 6, capital: units("M"))
        override.edit(replacing: NSRange(location: 6, length: 1), insertedLength: 0, textAfter: after("Done. "))
        XCTAssertTrue(override.isArmed(at: 6))

        // A deletion before `q` shifts it (consequence 7's cut) …
        override.edit(replacing: NSRange(location: 0, length: 5), insertedLength: 0, textAfter: after(" "))
        XCTAssertTrue(override.isArmed(at: 1))
        // … one ending exactly at `q` too …
        override.edit(replacing: NSRange(location: 0, length: 1), insertedLength: 0, textAfter: after(""))
        XCTAssertTrue(override.isArmed(at: 0))
        // … one after `q` changes nothing …
        override.produced(at: 6, capital: units("M"))
        override.edit(replacing: NSRange(location: 6, length: 1), insertedLength: 0, textAfter: after("Done. x"))
        override.edit(replacing: NSRange(location: 6, length: 1), insertedLength: 0, textAfter: after("Done. "))
        XCTAssertTrue(override.isArmed(at: 6))
        // … and one covering `q` moves it to the deletion's start.
        override.edit(replacing: NSRange(location: 4, length: 2), insertedLength: 0, textAfter: after("Done"))
        XCTAssertTrue(override.isArmed(at: 4))

        // An insertion at `q` that is not the retype (a bracket, a paste,
        // Redo of a typing run) leaves it armed; one anywhere else clears.
        override.edit(replacing: NSRange(location: 4, length: 0), insertedLength: 1, textAfter: after("Done("))
        XCTAssertTrue(override.isArmed(at: 4))
        override.edit(replacing: NSRange(location: 0, length: 0), insertedLength: 2, textAfter: after("- Done("))
        XCTAssertFalse(override.isArmed)
        XCTAssertEqual(override, CapitalOverride())
        // A replacement elsewhere is an insertion elsewhere.
        override.produced(at: 4, capital: units("M"))
        override.edit(replacing: NSRange(location: 4, length: 1), insertedLength: 0, textAfter: after("Say "))
        override.edit(replacing: NSRange(location: 0, length: 3), insertedLength: 3, textAfter: after("Tell "))
        XCTAssertFalse(override.isArmed)

        // An external replacement clears whatever there is.
        override.produced(at: 2, capital: units("M"))
        override.clear()
        XCTAssertEqual(override, CapitalOverride())
        override.produced(at: 2, capital: units("M"))
        override.edit(replacing: NSRange(location: 2, length: 1), insertedLength: 0, textAfter: after("xx"))
        override.clear()
        XCTAssertEqual(override, CapitalOverride())

        // Nothing tracked, nothing armed: edits are no-ops.
        override.edit(replacing: NSRange(location: 0, length: 3), insertedLength: 1, textAfter: after("x"))
        XCTAssertEqual(override, CapitalOverride())
    }

    func testTheRetypeIsAWordInsertionAtTheArmedOffset() {
        var override = CapitalOverride()
        override.produced(at: 4, capital: units("M"))
        override.edit(replacing: NSRange(location: 4, length: 1), insertedLength: 0, textAfter: after("Say "))
        XCTAssertTrue(override.isArmed(at: 4))

        // A non-word insertion at `q` (a bracket, a space, a newline) is
        // not the retype and leaves it armed.
        XCTAssertFalse(override.insertion(at: 4, selectionLength: 0, wordInsertion: false))
        XCTAssertTrue(override.isArmed(at: 4))
        // An insertion anywhere else clears it, word or not.
        XCTAssertFalse(override.insertion(at: 9, selectionLength: 0, wordInsertion: false))
        XCTAssertFalse(override.isArmed)
        override.produced(at: 4, capital: units("M"))
        override.edit(replacing: NSRange(location: 4, length: 1), insertedLength: 0, textAfter: after("Say "))
        XCTAssertFalse(override.insertion(at: 0, selectionLength: 0, wordInsertion: true))
        XCTAssertFalse(override.isArmed)
        // The gesture: a word insertion at `q` goes in as typed and spends
        // the override.
        override.produced(at: 4, capital: units("M"))
        override.edit(replacing: NSRange(location: 4, length: 1), insertedLength: 0, textAfter: after("Say "))
        XCTAssertTrue(override.insertion(at: 4, selectionLength: 0, wordInsertion: true))
        XCTAssertEqual(override, CapitalOverride())
        // The word's own edit, observed afterwards, changes nothing more.
        override.edit(replacing: NSRange(location: 4, length: 0), insertedLength: 2, textAfter: after("Say md"))
        XCTAssertEqual(override, CapitalOverride())

        // A word insertion while a capital stands, from a collapsed caret:
        // ordinary typing, wherever the caret is — in front of the capital
        // included (consequence 5).
        override.produced(at: 4, capital: units("M"))
        XCTAssertFalse(override.insertion(at: 4, selectionLength: 0, wordInsertion: true))
        XCTAssertFalse(override.insertion(at: 5, selectionLength: 0, wordInsertion: true))
        XCTAssertTrue(override.tracksCapital(at: 4))
        XCTAssertFalse(override.isArmed)

        // A word insertion over a selection the writer made that covers the
        // tracked capital: the edit removes it and arms the override at the
        // selection's start, where the word lands — the retype (consequence
        // 4), spent at once.
        XCTAssertTrue(override.insertion(at: 4, selectionLength: 2, wordInsertion: true))
        XCTAssertEqual(override, CapitalOverride())
        override.produced(at: 4, capital: units("M"))
        XCTAssertTrue(override.insertion(at: 0, selectionLength: 6, wordInsertion: true), "a selection reaching back over it")
        XCTAssertEqual(override, CapitalOverride())
        // A selection that stops short of the capital, or starts after it,
        // does not touch it.
        override.produced(at: 4, capital: units("M"))
        XCTAssertFalse(override.insertion(at: 0, selectionLength: 4, wordInsertion: true))
        XCTAssertFalse(override.insertion(at: 5, selectionLength: 2, wordInsertion: true))
        XCTAssertTrue(override.tracksCapital(at: 4))
        // A non-word insertion over such a selection is not the retype; the
        // edit will arm the override (`edit`), and the paste at `q` leaves
        // it armed.
        XCTAssertFalse(override.insertion(at: 4, selectionLength: 2, wordInsertion: false))
        XCTAssertTrue(override.tracksCapital(at: 4))
        // A range the system chose (reported as length 0) over the capital
        // is judged by the edit alone: the accent popover's pick over the
        // `E` md just made goes through `capitalize` again.
        XCTAssertFalse(override.insertion(at: 4, selectionLength: 0, wordInsertion: true))
        XCTAssertTrue(override.tracksCapital(at: 4))

        // Producing a capital while armed (the popover: its pick removed
        // the `E`, then md made the `É`) clears the override.
        override.edit(replacing: NSRange(location: 4, length: 1), insertedLength: 1, textAfter: after("Say é"))
        XCTAssertTrue(override.isArmed(at: 4))
        override.produced(at: 4, capital: units("É"))
        XCTAssertTrue(override.tracksCapital(at: 4))
        XCTAssertFalse(override.isArmed)

        // Nothing armed, nothing tracked: insertions are no-ops.
        override.clear()
        XCTAssertFalse(override.insertion(at: 3, selectionLength: 0, wordInsertion: true))
        XCTAssertFalse(override.insertion(at: 3, selectionLength: 2, wordInsertion: true))
        XCTAssertEqual(override, CapitalOverride())
    }

    func testTheEightConsequencesOnTheStateMachine() {
        // The same eight sequences the hosted tests below drive through
        // `SmartTextView`, here as the transitions alone. `wordAt` is what
        // the view asks before a word insertion; `edit` what the storage
        // delegate reports after every edit; `produced` what the view
        // records when `capitalize` said yes.
        func wordAt(_ o: inout CapitalOverride, _ start: Int, selecting length: Int = 0) -> Bool {
            o.insertion(at: start, selectionLength: length, wordInsertion: true)
        }
        var o = CapitalOverride()

        // (1) "md" → "Md"; ⌫ ⌫; "md" → "md".
        XCTAssertFalse(wordAt(&o, 0)); o.produced(at: 0, capital: units("M"))
        XCTAssertFalse(wordAt(&o, 1)); o.edit(replacing: NSRange(location: 1, length: 0), insertedLength: 1, textAfter: after("Md"))
        o.edit(replacing: NSRange(location: 1, length: 1), insertedLength: 0, textAfter: after("M"))
        o.edit(replacing: NSRange(location: 0, length: 1), insertedLength: 0, textAfter: after(""))
        XCTAssertTrue(o.isArmed(at: 0))
        XCTAssertTrue(wordAt(&o, 0), "(1) the retype")
        XCTAssertFalse(wordAt(&o, 1))
        XCTAssertEqual(o, CapitalOverride())

        // (2) "iOS" → "IOS"; ⌫ ⌫ ⌫; "iOS" → "iOS".
        o = CapitalOverride()
        XCTAssertFalse(wordAt(&o, 0)); o.produced(at: 0, capital: units("I"))
        o.edit(replacing: NSRange(location: 1, length: 0), insertedLength: 1, textAfter: after("IO"))
        o.edit(replacing: NSRange(location: 2, length: 0), insertedLength: 1, textAfter: after("IOS"))
        o.edit(replacing: NSRange(location: 2, length: 1), insertedLength: 0, textAfter: after("IO"))
        o.edit(replacing: NSRange(location: 1, length: 1), insertedLength: 0, textAfter: after("I"))
        o.edit(replacing: NSRange(location: 0, length: 1), insertedLength: 0, textAfter: after(""))
        XCTAssertTrue(wordAt(&o, 0), "(2) the retype")

        // (3) "Md is"; five ⌫; "md is" → "md is".
        o = CapitalOverride()
        XCTAssertFalse(wordAt(&o, 0)); o.produced(at: 0, capital: units("M"))
        for (i, t) in ["Md", "Md ", "Md i", "Md is"].enumerated() {
            o.edit(replacing: NSRange(location: i + 1, length: 0), insertedLength: 1, textAfter: after(t))
        }
        for (i, t) in ["Md i", "Md ", "Md", "M", ""].enumerated() {
            o.edit(replacing: NSRange(location: 4 - i, length: 1), insertedLength: 0, textAfter: after(t))
        }
        XCTAssertTrue(o.isArmed(at: 0))
        XCTAssertTrue(wordAt(&o, 0), "(3) the retype")

        // (4) "Md" selected, "md" typed → "md".
        o = CapitalOverride()
        o.produced(at: 0, capital: units("M"))
        o.edit(replacing: NSRange(location: 1, length: 0), insertedLength: 1, textAfter: after("Md"))
        XCTAssertTrue(wordAt(&o, 0, selecting: 2), "(4) the word over its own capital")
        o.edit(replacing: NSRange(location: 0, length: 2), insertedLength: 2, textAfter: after("md"))
        XCTAssertEqual(o, CapitalOverride())

        // (5) after "Md", the caret before the M, "a" typed → "AMd": the
        // capital was not deleted, it shifts; then md's new capital
        // replaces it.
        o = CapitalOverride()
        o.produced(at: 0, capital: units("M"))
        o.edit(replacing: NSRange(location: 1, length: 0), insertedLength: 1, textAfter: after("Md"))
        XCTAssertFalse(wordAt(&o, 0), "(5) not the retype: the capital stands")
        o.edit(replacing: NSRange(location: 0, length: 0), insertedLength: 1, textAfter: after("aMd"))
        XCTAssertTrue(o.tracksCapital(at: 1))
        XCTAssertFalse(o.isArmed)
        o.produced(at: 0, capital: units("A"))
        XCTAssertTrue(o.tracksCapital(at: 0))

        // (6) "m" → "M"; Undo → "m" (the edit that removed the capital:
        // armed at p, the letter not re-judged); "d" → "md".
        o = CapitalOverride()
        XCTAssertFalse(wordAt(&o, 0)); o.produced(at: 0, capital: units("M"))
        o.edit(replacing: NSRange(location: 0, length: 1), insertedLength: 1, textAfter: after("m"))
        XCTAssertTrue(o.isArmed(at: 0), "(6) Undo armed it")
        XCTAssertFalse(wordAt(&o, 1), "(6) the d is typed elsewhere")
        XCTAssertEqual(o, CapitalOverride())

        // (7) "Xxx. " then "m" → "Xxx. M"; cut "Xxx. "; ⌫ the M; "m" → "m".
        o = CapitalOverride()
        o.produced(at: 0, capital: units("X"))
        for (i, t) in ["Xx", "Xxx", "Xxx.", "Xxx. "].enumerated() {
            o.edit(replacing: NSRange(location: i + 1, length: 0), insertedLength: 1, textAfter: after(t))
        }
        XCTAssertFalse(wordAt(&o, 5)); o.produced(at: 5, capital: units("M"))
        o.edit(replacing: NSRange(location: 0, length: 5), insertedLength: 0, textAfter: after("M"))
        XCTAssertTrue(o.tracksCapital(at: 0), "(7) the tracking survived the cut")
        o.edit(replacing: NSRange(location: 0, length: 1), insertedLength: 0, textAfter: after(""))
        XCTAssertTrue(o.isArmed(at: 0))
        XCTAssertTrue(wordAt(&o, 0), "(7) the retype")

        // (8) "m" → "M", "d" → "Md", ⌫ the d, "d" → "Md": the capital
        // still stands; nothing armed.
        o = CapitalOverride()
        o.produced(at: 0, capital: units("M"))
        o.edit(replacing: NSRange(location: 1, length: 0), insertedLength: 1, textAfter: after("Md"))
        o.edit(replacing: NSRange(location: 1, length: 1), insertedLength: 0, textAfter: after("M"))
        XCTAssertTrue(o.tracksCapital(at: 0))
        XCTAssertFalse(o.isArmed)
        XCTAssertFalse(wordAt(&o, 1), "(8) ordinary typing")
        XCTAssertTrue(o.tracksCapital(at: 0))
    }

    // MARK: - The decision (§3.3 + §3.4 + §2)

    func testCapitalDecisionAtALineStart() {
        let decision = SmartTypingAdapter.capital(text: "", selectionStart: 0, selectionEnd: 0,
                                                  insertion: "h")
        XCTAssertEqual(decision, .init(leadLength: 1, capital: "H"))

        // A word: the lead is still one scalar, the capital one letter.
        let word = SmartTypingAdapter.capital(text: "Done. ", selectionStart: 6, selectionEnd: 6,
                                              insertion: "next")
        XCTAssertEqual(word, .init(leadLength: 1, capital: "N"))

        // A supplementary-plane letter: a two-unit lead.
        let deseret = SmartTypingAdapter.capital(text: "", selectionStart: 0, selectionEnd: 0,
                                                 insertion: "\u{10428}")
        XCTAssertEqual(deseret, .init(leadLength: 2, capital: "\u{10400}"))

        // A backwards selection is normalised (§0.9).
        let backwards = SmartTypingAdapter.capital(text: "abc", selectionStart: 3, selectionEnd: 0,
                                                   insertion: "x")
        XCTAssertEqual(backwards, .init(leadLength: 1, capital: "X"))
    }

    func testCapitalDecisionDeclines() {
        // Mid-sentence, in a fence, after a URL token: the rules say no.
        XCTAssertNil(SmartTypingAdapter.capital(text: "hello ", selectionStart: 6, selectionEnd: 6,
                                                insertion: "w"))
        XCTAssertNil(SmartTypingAdapter.capital(text: "```\n", selectionStart: 4, selectionEnd: 4,
                                                insertion: "h"))
        // Not word insertions: never even asked.
        XCTAssertNil(SmartTypingAdapter.capital(text: "", selectionStart: 0, selectionEnd: 0,
                                                insertion: "hello world"))
        XCTAssertNil(SmartTypingAdapter.capital(text: "", selectionStart: 0, selectionEnd: 0,
                                                insertion: "https://nettrash.me"))
        XCTAssertNil(SmartTypingAdapter.capital(text: "", selectionStart: 0, selectionEnd: 0,
                                                insertion: "@nettrash"))
        XCTAssertNil(SmartTypingAdapter.capital(text: "", selectionStart: 0, selectionEnd: 0,
                                                insertion: "\n"))
        // An invalid selection is the pure function's nil (§0.9).
        XCTAssertNil(SmartTypingAdapter.capital(text: "ab", selectionStart: 0, selectionEnd: 3,
                                                insertion: "h"))
    }

    func testSelectAndRetypeIsAlwaysAsTyped() {
        // Independent of the override: `H` selected, `h` typed → `h`.
        XCTAssertNil(SmartTypingAdapter.capital(text: "Hello", selectionStart: 0, selectionEnd: 1,
                                                insertion: "h"))
        XCTAssertTrue(SmartTypingAdapter.retypesOwnCapital(text: "Hello", selectionStart: 0, selectionEnd: 1,
                                                           insertion: "h"))
        XCTAssertTrue(SmartTypingAdapter.retypesOwnCapital(text: "Hello", selectionStart: 1, selectionEnd: 0,
                                                           insertion: "h"))
        XCTAssertFalse(SmartTypingAdapter.retypesOwnCapital(text: "Hello", selectionStart: 0, selectionEnd: 1,
                                                            insertion: "x"))
        XCTAssertFalse(SmartTypingAdapter.retypesOwnCapital(text: "Hello", selectionStart: 0, selectionEnd: 2,
                                                            insertion: "h"))
        XCTAssertFalse(SmartTypingAdapter.retypesOwnCapital(text: "Hello", selectionStart: 0, selectionEnd: 1,
                                                            insertion: "hi"))
        XCTAssertFalse(SmartTypingAdapter.retypesOwnCapital(text: "hello", selectionStart: 0, selectionEnd: 1,
                                                            insertion: "h"), "a lowercase letter selected")
        XCTAssertFalse(SmartTypingAdapter.retypesOwnCapital(text: "Hello", selectionStart: 0, selectionEnd: 0,
                                                            insertion: "h"), "nothing selected")
        XCTAssertTrue(SmartTypingAdapter.retypesOwnCapital(text: "\u{10400}", selectionStart: 0, selectionEnd: 2,
                                                           insertion: "\u{10428}"))
        XCTAssertNil(SmartTypingAdapter.capital(text: "Hello", selectionStart: 1, selectionEnd: 0,
                                                insertion: "h"))
        // A different letter over the capital is a fresh line start: capitalized.
        XCTAssertEqual(SmartTypingAdapter.capital(text: "Hello", selectionStart: 0, selectionEnd: 1,
                                                  insertion: "x"),
                       .init(leadLength: 1, capital: "X"))
        // The selection must be exactly that one scalar.
        XCTAssertEqual(SmartTypingAdapter.capital(text: "Hello", selectionStart: 0, selectionEnd: 2,
                                                  insertion: "h"),
                       .init(leadLength: 1, capital: "H"))
        // A whole word typed over the capital is not the gesture.
        XCTAssertEqual(SmartTypingAdapter.capital(text: "Hello", selectionStart: 0, selectionEnd: 1,
                                                  insertion: "hi"),
                       .init(leadLength: 1, capital: "H"))
        // Two-unit scalars compare as scalars.
        XCTAssertNil(SmartTypingAdapter.capital(text: "\u{10400}", selectionStart: 0, selectionEnd: 2,
                                                insertion: "\u{10428}"))
    }

    // MARK: - Settings (§3.1)

    func testTypingSettingsDefaultOnAndReadLive() throws {
        let defaults = try makeDefaults()
        XCTAssertTrue(TypingSettings.continueLists(in: defaults), "absent means on")
        XCTAssertTrue(TypingSettings.capitalizeSentences(in: defaults))
        defaults.set(false, forKey: TypingSettings.continueListsKey)
        XCTAssertFalse(TypingSettings.continueLists(in: defaults))
        XCTAssertTrue(TypingSettings.capitalizeSentences(in: defaults))
        defaults.set(false, forKey: TypingSettings.capitalizeSentencesKey)
        defaults.set(true, forKey: TypingSettings.continueListsKey)
        XCTAssertTrue(TypingSettings.continueLists(in: defaults))
        XCTAssertFalse(TypingSettings.capitalizeSentences(in: defaults))
        XCTAssertEqual(TypingSettings.continueListsKey, "md.continueLists")
        XCTAssertEqual(TypingSettings.capitalizeSentencesKey, "md.capitalizeSentences")
    }

    // MARK: - The view: Return (§1, §3.3, §3.5)

    func testScrollableTextViewBuildsTheSubclass() throws {
        // `MarkdownEditor` relies on the class method instantiating the
        // subclass with the standard scaffold configuration.
        let scrollView = SmartTextView.scrollableTextView()
        let view = try XCTUnwrap(scrollView.documentView as? SmartTextView)
        XCTAssertTrue(view.isVerticallyResizable)
        XCTAssertFalse(view.isHorizontallyResizable)
        XCTAssertTrue(view.textContainer?.widthTracksTextView ?? false)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        // Every edit is read off the text storage (§3.4): the view is its
        // storage's delegate, built either way.
        XCTAssertTrue(view.textStorage?.delegate === view)
        let plain = try makeView()
        XCTAssertTrue(plain.textStorage?.delegate === plain)
    }

    func testReturnContinuesAList() throws {
        let view = try makeView()
        type("- item", into: view)
        view.insertNewline(nil)
        XCTAssertEqual(units(view.string), units("- item\n- "))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 9, length: 0))
    }

    func testReturnAppliesThePureFunctionsEdit() throws {
        // The view must apply whatever `enter` returns exactly: location,
        // length, replacement and caret — over a selection too.
        let cases: [(text: String, selection: NSRange)] = [
            ("- ", NSRange(location: 2, length: 0)),                        // empty item: exit
            ("1. one", NSRange(location: 6, length: 0)),                    // numbering
            ("- [ ] task", NSRange(location: 10, length: 0)),               // checklist
            ("> quoted", NSRange(location: 8, length: 0)),                  // quote
            ("- a\n  - b\n  - ", NSRange(location: 14, length: 0)),         // nested empty: outdent
            ("| a | b |\n|---|---|\n| 1 | 2 |", NSRange(location: 28, length: 0)), // table row
            ("- one two", NSRange(location: 5, length: 4)),                 // a selection is deleted
            ("plain", NSRange(location: 5, length: 0)),                     // nil: a plain newline
        ]
        for c in cases {
            let view = try makeView()
            reload(view, to: c.text)
            view.setSelectedRange(c.selection)
            let expected: (text: [UInt16], caret: Int)
            if let edit = SmartTyping.enter(c.text, selectionStart: c.selection.location,
                                            selectionEnd: NSMaxRange(c.selection)) {
                var u = units(c.text)
                u.replaceSubrange(edit.location..<(edit.location + edit.length), with: units(edit.replacement))
                expected = (u, edit.caret)
            } else {
                var u = units(c.text)
                u.replaceSubrange(c.selection.location..<NSMaxRange(c.selection), with: units("\n"))
                expected = (u, c.selection.location + 1)
            }
            view.insertNewline(nil)
            XCTAssertEqual(units(view.string), expected.text, c.text.debugDescription)
            XCTAssertEqual(view.selectedRange(), NSRange(location: expected.caret, length: 0), c.text.debugDescription)
        }
    }

    func testReturnWithTheSettingOffIsAPlainNewline() throws {
        let view = try makeView(continueLists: false)
        type("- item", into: view)
        view.insertNewline(nil)
        XCTAssertEqual(units(view.string), units("- item\n"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 7, length: 0))

        // Flipped on mid-session: the very next Return continues.
        view.defaults.set(true, forKey: TypingSettings.continueListsKey)
        type("- again", into: view)
        view.insertNewline(nil)
        XCTAssertEqual(units(view.string), units("- item\n- again\n- "))
    }

    func testReturnIsOneUndoStep() throws {
        let view = try makeView()
        let host = makeHost()
        view.delegate = host
        view.allowsUndo = true
        reload(view, to: "- item")                       // programmatic: not on the undo stack
        view.setSelectedRange(NSRange(location: 6, length: 0))
        keystroke(host) { view.insertNewline(nil) }
        XCTAssertEqual(units(view.string), units("- item\n- "))
        XCTAssertTrue(host.undoManager.canUndo)
        host.undoManager.undo()
        XCTAssertEqual(units(view.string), units("- item"), "one ⌘Z takes the whole edit back")
        XCTAssertFalse(host.undoManager.canUndo)
        host.undoManager.redo()
        XCTAssertEqual(units(view.string), units("- item\n- "))
    }

    func testControlReturnInsertsALineFeedNeverU2028() throws {
        let view = try makeView()
        type("- item", into: view)
        view.insertLineBreak(nil)
        XCTAssertEqual(units(view.string), units("- item\n"))
        XCTAssertFalse(view.string.utf16.contains(0x2028))
        view.insertParagraphSeparator(nil)
        XCTAssertEqual(units(view.string), units("- item\n\n"))
        XCTAssertFalse(view.string.utf16.contains(0x2029))
        // Not a Return: the list is not continued either way.
        XCTAssertEqual(view.selectedRange(), NSRange(location: 8, length: 0))
    }

    // MARK: - The view: letters (§2, §3.3)

    func testFirstLetterIsCapitalized() throws {
        let view = try makeView()
        type("h", into: view)
        XCTAssertEqual(units(view.string), units("H"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0))
        XCTAssertFalse(view.capitalOverride.isArmed)

        type("i", into: view)
        type(".", into: view)
        type(" ", into: view)
        type("t", into: view)
        XCTAssertEqual(units(view.string), units("Hi. T"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 0))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 4), "the last capital is the tracked one")
    }

    func testAnAttributedInsertionIsHandledLikeAString() throws {
        let view = try makeView()
        view.insertText(NSAttributedString(string: "h"), replacementRange: noRange)
        XCTAssertEqual(units(view.string), units("H"))
    }

    func testWordInsertionCapitalizesItsFirstScalar() throws {
        let view = try makeView()
        type("hello", into: view)
        XCTAssertEqual(units(view.string), units("Hello"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 0), "caret after the whole word")
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0))

        // A trailing space (predictive text) is part of the word insertion.
        reload(view, to: "")
        type("hello ", into: view)
        XCTAssertEqual(units(view.string), units("Hello "))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 0))

        // Phrases, URLs and handles go in unchanged.
        for phrase in ["hello world", "https://nettrash.me", "www.nettrash.me", "@nettrash", "~/Documents/x"] {
            reload(view, to: "")
            type(phrase, into: view)
            XCTAssertEqual(units(view.string), units(phrase), phrase)
            XCTAssertEqual(view.capitalOverride, CapitalOverride(), phrase)
        }
    }

    func testNoCapitalInsideAFence() throws {
        let view = try makeView()
        reload(view, to: "```\n")
        view.setSelectedRange(NSRange(location: 4, length: 0))
        type("h", into: view)
        XCTAssertEqual(units(view.string), units("```\nh"))
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
    }

    func testCapitalizationWithTheSettingOffAndBackOn() throws {
        let view = try makeView(capitalize: false)
        type("h", into: view)
        XCTAssertEqual(units(view.string), units("h"))
        XCTAssertEqual(view.capitalOverride, CapitalOverride())

        // Flipped on mid-session: the very next letter obeys.
        view.defaults.set(true, forKey: TypingSettings.capitalizeSentencesKey)
        type("\n", into: view)
        type("i", into: view)
        XCTAssertEqual(units(view.string), units("h\nI"))

        // And off again.
        view.defaults.set(false, forKey: TypingSettings.capitalizeSentencesKey)
        type("\n", into: view)
        type("j", into: view)
        XCTAssertEqual(units(view.string), units("h\nI\nj"))
    }

    func testDeadKeyCommitIsCapitalized() throws {
        // Option-e then e on a US keyboard: the accent sits as marked text
        // and the composed letter is committed with no explicit range.
        let view = try makeView()
        view.setMarkedText("\u{00B4}", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        XCTAssertTrue(view.hasMarkedText())
        view.insertText("é", replacementRange: noRange)
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(units(view.string), units("É"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0))

        type("c", into: view)
        type("o", into: view)
        XCTAssertEqual(units(view.string), units("Éco"))
    }

    func testCJKCompositionCommitIsUntouched() throws {
        let view = try makeView()
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        view.insertText("か", replacementRange: noRange)
        XCTAssertEqual(units(view.string), units("か"))
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
    }

    func testAccentPopoverReplacementIsCapitalized() throws {
        // The press-and-hold popover always follows a key: the letter is
        // inserted first — and capitalized by md where the rule applies —
        // then the pick replaces that one scalar over an *explicit* range.
        // Over the capital md just made and still tracked, nothing was
        // selected by the writer: the pick is not the select-and-retype
        // gesture, it goes through `capitalize` with that range as the
        // selection, so `école` at a line start becomes `École` (§3.3).
        // The pick's edit removed the `E` (which arms the override for a
        // moment) and md's `É` replaced it as the tracked capital, which
        // clears it again: tracked at 0, nothing armed.
        let view = try makeView()
        type("e", into: view)
        XCTAssertEqual(units(view.string), units("E"))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0))
        view.insertText("é", replacementRange: NSRange(location: 0, length: 1))
        XCTAssertEqual(units(view.string), units("É"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0), "the new capital is the tracked one")
        XCTAssertFalse(view.capitalOverride.isArmed)
        for letter in ["c", "o", "l", "e"] { type(letter, into: view) }
        XCTAssertEqual(units(view.string), units("École"))

        // The same typed in front of existing text, and after a sentence end.
        reload(view, to: "cole")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        type("e", into: view)
        XCTAssertEqual(units(view.string), units("Ecole"))
        view.insertText("é", replacementRange: NSRange(location: 0, length: 1))
        XCTAssertEqual(units(view.string), units("École"))

        reload(view, to: "Done. ")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        type("e", into: view)
        XCTAssertEqual(units(view.string), units("Done. E"))
        view.insertText("é", replacementRange: NSRange(location: 6, length: 1))
        XCTAssertEqual(units(view.string), units("Done. É"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 7, length: 0))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 6))
        XCTAssertFalse(view.capitalOverride.isArmed)

        // Mid-sentence the letter stayed lowercase, and so does the pick.
        reload(view, to: "Caf")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        type("e", into: view)
        XCTAssertEqual(units(view.string), units("Cafe"))
        view.insertText("é", replacementRange: NSRange(location: 3, length: 1))
        XCTAssertEqual(units(view.string), units("Café"))
        XCTAssertEqual(view.capitalOverride, CapitalOverride())

        // A longer replacement over the same explicit range (a completion
        // re-inserting the word from the capital's slot) is judged the
        // same way: the capital stands, so it is not the gesture, and the
        // word is capitalized — not inserted as typed.
        reload(view, to: "")
        type("h", into: view)
        XCTAssertEqual(units(view.string), units("H"))
        view.insertText("hello", replacementRange: NSRange(location: 0, length: 1))
        XCTAssertEqual(units(view.string), units("Hello"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 0))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0))
        XCTAssertFalse(view.capitalOverride.isArmed)
    }

    func testAccentPopoverAfterTheOverrideKeepsTheLowercase() throws {
        // The writer chose the lowercase: `e` → `E`, Backspace, `e` — the
        // override honoured, `e` as typed — and then held the key and
        // picked `é`. The scalar the pick replaces is a lowercase letter,
        // so the pick goes in as typed: `é`, not `É`, and nothing is armed.
        let view = try makeView()
        type("e", into: view)
        XCTAssertEqual(units(view.string), units("E"))
        view.deleteBackward(nil)
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0))
        type("e", into: view)
        XCTAssertEqual(units(view.string), units("e"))
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
        view.insertText("é", replacementRange: NSRange(location: 0, length: 1))
        XCTAssertEqual(units(view.string), units("é"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
        for letter in ["c", "o", "l", "e"] { type(letter, into: view) }
        XCTAssertEqual(units(view.string), units("école"))

        // After a sentence end too.
        reload(view, to: "Done. ")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        type("e", into: view)
        view.deleteBackward(nil)
        type("e", into: view)
        XCTAssertEqual(units(view.string), units("Done. e"))
        view.insertText("é", replacementRange: NSRange(location: 6, length: 1))
        XCTAssertEqual(units(view.string), units("Done. é"))
        XCTAssertEqual(view.capitalOverride, CapitalOverride())

        // Select-and-retype (the target *is* the selection) is untouched:
        // `E` selected, `e` typed → `e` — §3.4's independent rule; and
        // since that edit removed the tracked capital, the override is
        // armed there, so the pick over the `e` keeps it too.
        reload(view, to: "")
        type("e", into: view)
        view.setSelectedRange(NSRange(location: 0, length: 1))
        type("e", into: view)
        XCTAssertEqual(units(view.string), units("e"))
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0))
        view.insertText("é", replacementRange: NSRange(location: 0, length: 1))
        XCTAssertEqual(units(view.string), units("é"))
    }

    func testReplacingOneLowercaseScalarIsDetectedAsSuch() {
        // The pure test behind the popover rule: one scalar inserted over
        // exactly one lowercase-letter scalar.
        XCTAssertTrue(SmartTypingAdapter.replacesOneLowercaseScalar(text: "e", selectionStart: 0, selectionEnd: 1, insertion: "é"))
        XCTAssertTrue(SmartTypingAdapter.replacesOneLowercaseScalar(text: "Cafe", selectionStart: 4, selectionEnd: 3, insertion: "é"),
                      "either selection order")
        XCTAssertTrue(SmartTypingAdapter.replacesOneLowercaseScalar(text: "\u{10428}", selectionStart: 0, selectionEnd: 2, insertion: "\u{10429}"),
                      "a two-unit lowercase scalar")
        XCTAssertFalse(SmartTypingAdapter.replacesOneLowercaseScalar(text: "E", selectionStart: 0, selectionEnd: 1, insertion: "é"),
                       "the replaced scalar is a capital")
        XCTAssertFalse(SmartTypingAdapter.replacesOneLowercaseScalar(text: "e", selectionStart: 0, selectionEnd: 0, insertion: "é"),
                       "nothing replaced")
        XCTAssertFalse(SmartTypingAdapter.replacesOneLowercaseScalar(text: "ec", selectionStart: 0, selectionEnd: 2, insertion: "é"),
                       "two scalars replaced")
        XCTAssertFalse(SmartTypingAdapter.replacesOneLowercaseScalar(text: "e", selectionStart: 0, selectionEnd: 1, insertion: "éc"),
                       "two scalars inserted")
        XCTAssertFalse(SmartTypingAdapter.replacesOneLowercaseScalar(text: "1", selectionStart: 0, selectionEnd: 1, insertion: "é"),
                       "a digit replaced")
        XCTAssertFalse(SmartTypingAdapter.replacesOneLowercaseScalar(text: "\u{10428}", selectionStart: 0, selectionEnd: 1, insertion: "é"),
                       "a range splitting a surrogate pair")
        XCTAssertFalse(SmartTypingAdapter.replacesOneLowercaseScalar(text: "e", selectionStart: 0, selectionEnd: 2, insertion: "é"),
                       "a range past the end")
        XCTAssertFalse(SmartTypingAdapter.replacesOneLowercaseScalar(text: "e", selectionStart: 0, selectionEnd: 1, insertion: ""))
    }

    // MARK: - The view: override and undo (§3.4, §3.5)

    func testBackspaceAndRetypeKeepsTheLowercase() throws {
        let view = try makeView()
        reload(view, to: "Done. ")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        type("m", into: view)
        XCTAssertEqual(units(view.string), units("Done. M"))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 6))
        XCTAssertFalse(view.capitalOverride.isArmed)
        // Backspace over the capital arms the override at its slot; caret
        // moves change nothing.
        view.deleteBackward(nil)
        XCTAssertEqual(units(view.string), units("Done. "))
        XCTAssertTrue(view.capitalOverride.isArmed(at: 6))
        XCTAssertFalse(view.capitalOverride.tracksCapital)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertTrue(view.capitalOverride.isArmed(at: 6))
        // Retyped at q: as typed, and the override is spent.
        type("m", into: view)
        XCTAssertEqual(units(view.string), units("Done. m"))
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
        type("d", into: view)
        type(" ", into: view)
        type("i", into: view)
        type("s", into: view)
        XCTAssertEqual(units(view.string), units("Done. md is"))

        // A letter typed in front of a capital that still stands is not
        // the gesture: the capital is not deleted, and the rule decides.
        reload(view, to: "")
        type("m", into: view)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        type("x", into: view)
        XCTAssertEqual(units(view.string), units("XM"))
    }

    func testTheGesturesThatKeepABrandNameLowercase() throws {
        // What the README and the CHANGELOG promise: delete the capital md
        // wrote and type the letter again; it stays lowercase — however
        // much was typed after the capital in the meantime (§3.4 amended:
        // the capital is tracked until an edit removes it, and that edit
        // arms the override where it began).
        let view = try makeView()
        let phrase = ["m", "d", " ", "i", "s"]
        for letter in phrase { type(letter, into: view) }
        XCTAssertEqual(units(view.string), units("Md is"))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0), "typing on keeps the capital tracked")
        XCTAssertFalse(view.capitalOverride.isArmed)
        for _ in phrase { view.deleteBackward(nil) }
        XCTAssertEqual(units(view.string), units(""))
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0), "the last Backspace removed the capital")
        for letter in phrase { type(letter, into: view) }
        XCTAssertEqual(units(view.string), units("md is"), "the retype, honoured")

        // Gesture 1 — Backspace over the capital before typing on, then retype.
        reload(view, to: "")
        type("m", into: view)
        XCTAssertEqual(units(view.string), units("M"))
        view.deleteBackward(nil)
        for letter in phrase { type(letter, into: view) }
        XCTAssertEqual(units(view.string), units("md is"))

        // Gesture 2 — select the capital and retype it, at any time.
        reload(view, to: "")
        for letter in phrase { type(letter, into: view) }
        XCTAssertEqual(units(view.string), units("Md is"))
        view.setSelectedRange(NSRange(location: 0, length: 1))
        type("m", into: view)
        XCTAssertEqual(units(view.string), units("md is"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        // The independent rule's edit removed the tracked capital: armed.
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0))

        reload(view, to: "")
        for letter in ["i", "O", "S"] { type(letter, into: view) }
        XCTAssertEqual(units(view.string), units("IOS"))
        view.setSelectedRange(NSRange(location: 0, length: 1))
        type("i", into: view)
        XCTAssertEqual(units(view.string), units("iOS"))

        // Gesture 3 — ⌘Z right after the capital: see
        // testUndoRestoresTheLowercaseLetterAndArmsTheOverride.
    }

    func testSelectAndRetypeInTheView() throws {
        let view = try makeView()
        type("m", into: view)
        type("d", into: view)
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0))
        XCTAssertFalse(view.capitalOverride.isArmed)
        // Select the capital and type its lowercase over it: the rule that
        // needs no override — and whose edit, removing the tracked
        // capital, arms it (§3.4's independent rule).
        view.setSelectedRange(NSRange(location: 0, length: 1))
        type("m", into: view)
        XCTAssertEqual(units(view.string), units("md"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0))
        XCTAssertFalse(view.capitalOverride.tracksCapital)
        // Armed there, a delete-and-retype at the same slot stays lowercase.
        view.deleteBackward(nil)
        type("m", into: view)
        XCTAssertEqual(units(view.string), units("md"))
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
        // Select the whole word from p and retype: as typed, and spent.
        reload(view, to: "")
        type("m", into: view)
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0))
        view.setSelectedRange(NSRange(location: 0, length: 1))
        type("md", into: view)
        XCTAssertEqual(units(view.string), units("md"))
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
        // A selected capital that is not md's (typed with Shift): the
        // independent rule still applies; there is nothing to arm.
        reload(view, to: "")
        type("H", into: view)
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
        view.setSelectedRange(NSRange(location: 0, length: 1))
        type("h", into: view)
        XCTAssertEqual(units(view.string), units("h"))
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
    }

    func testAnInsertionElsewhereClearsTheArmedOverride() throws {
        let view = try makeView()
        reload(view, to: "Done. ")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        type("m", into: view)
        XCTAssertEqual(units(view.string), units("Done. M"))
        // Typing on does not touch the tracked capital (it is after it) …
        type(" ", into: view)
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 6))
        XCTAssertFalse(view.capitalOverride.isArmed)
        // … and deleting back over it arms the override.
        view.deleteBackward(nil)
        view.deleteBackward(nil)
        XCTAssertEqual(units(view.string), units("Done. "))
        XCTAssertTrue(view.capitalOverride.isArmed(at: 6))
        // An insertion anywhere else clears it: the retype is over.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        type("x", into: view)
        XCTAssertEqual(units(view.string), units("XDone. "))
        XCTAssertFalse(view.capitalOverride.isArmed)
        view.setSelectedRange(NSRange(location: 7, length: 0))
        type("m", into: view)
        XCTAssertEqual(units(view.string), units("XDone. M"), "no override left to honour")

        // A paste or drop lands through the storage, not `insertText`; the
        // storage delegate sees it all the same: an insertion elsewhere
        // clears, a deletion never does, and a paste at `q` leaves it
        // armed (it is not a word insertion).
        view.deleteBackward(nil)
        XCTAssertTrue(view.capitalOverride.isArmed(at: 7))
        try pasteLike("", over: NSRange(location: 6, length: 1), into: view)
        XCTAssertEqual(units(view.string), units("XDone."))
        XCTAssertTrue(view.capitalOverride.isArmed(at: 6), "a deletion moves it, never clears it")
        try pasteLike("pasted", over: NSRange(location: 6, length: 0), into: view)
        XCTAssertTrue(view.capitalOverride.isArmed(at: 6), "a paste at q is not the retype; still armed")
        try pasteLike("pasted", over: NSRange(location: 0, length: 0), into: view)
        XCTAssertFalse(view.capitalOverride.isArmed)
        // With a capital tracked, a paste before it moves it; one over it
        // removes it and arms the override where the paste began.
        reload(view, to: "")
        type("m", into: view)
        try pasteLike("- ", over: NSRange(location: 0, length: 0), into: view)
        XCTAssertEqual(units(view.string), units("- M"))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 2))
        try pasteLike("xx", over: NSRange(location: 1, length: 2), into: view)
        XCTAssertEqual(units(view.string), units("-xx"))
        XCTAssertTrue(view.capitalOverride.isArmed(at: 1))
    }

    func testAnExternalReplacementClearsTheOverride() throws {
        let view = try makeView()
        type("m", into: view)
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0))
        reload(view, to: "m")                            // revert / reload / article switch
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
        view.setSelectedRange(NSRange(location: 0, length: 1))
        type("x", into: view)
        XCTAssertEqual(units(view.string), units("X"))
        // Armed, then replaced from outside: cleared too.
        view.deleteBackward(nil)
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0))
        reload(view, to: "x")
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
    }

    func testUndoRestoresTheLowercaseLetterAndArmsTheOverride() throws {
        let view = try makeView()
        let host = makeHost()
        view.delegate = host
        view.allowsUndo = true

        keystroke(host) { type("m", into: view) }
        keystroke(host) { type("d", into: view) }
        XCTAssertEqual(units(view.string), units("Md"))
        XCTAssertEqual(host.undoManager.groupingLevel, 0)

        host.undoManager.undo()
        XCTAssertEqual(units(view.string), units("M"), "the second letter was its own typing run")

        host.undoManager.undo()
        XCTAssertEqual(units(view.string), units("m"), "⌘Z after a capital restores the lowercase letter")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0), "and keeps the caret")
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0), "and arms the override: the edit removed the capital")
        XCTAssertFalse(view.capitalOverride.tracksCapital)

        host.undoManager.undo()
        XCTAssertEqual(units(view.string), units(""))
        XCTAssertFalse(host.undoManager.canUndo)
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0), "a deletion covering q keeps it armed at its start")

        host.undoManager.redo()
        XCTAssertEqual(units(view.string), units("m"))
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0), "a redone typing run at q is not the retype")
        host.undoManager.redo()
        XCTAssertEqual(units(view.string), units("M"))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0), "Redo puts md's capital back: tracked again")
        XCTAssertFalse(view.capitalOverride.isArmed)
        host.undoManager.redo()
        XCTAssertEqual(units(view.string), units("Md"))
        XCTAssertFalse(host.undoManager.canRedo)
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0))

        // The override armed by undo is honoured: back to `m`, delete it,
        // retype it — lowercase.
        host.undoManager.undo()
        host.undoManager.undo()
        XCTAssertEqual(units(view.string), units("m"))
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0))
        keystroke(host) { view.deleteBackward(nil) }
        keystroke(host) { type("m", into: view) }
        XCTAssertEqual(units(view.string), units("m"))
    }

    /// The same undo in the editor *as the app builds it*, in a window
    /// that is on screen and key. A capital is applied as a replacement of
    /// the letter, and `NSTextView` undoes a replacement in a live window
    /// the way it undoes select-and-type: the restored text comes back
    /// selected. Measured in the running app: ⌘Z after `m` → `M` left `m`
    /// selected, and the next letter typed replaced it — a writer who undid
    /// the capital and typed on lost the letter. The bare off-screen view
    /// above never showed it, which is why this one is hosted in a key
    /// window with the app's own scroll view. After undo the caret sits
    /// after the letter; after redo, after the capital.
    func testUndoOfACapitalInAKeyWindowLeavesACaretAfterTheLetter() throws {
        let scrollView = MarkdownEditor.makeScrollView()
        let view = try XCTUnwrap(scrollView.documentView as? SmartTextView)
        let defaults = try makeDefaults()
        defaults.set(true, forKey: TypingSettings.continueListsKey)
        defaults.set(true, forKey: TypingSettings.capitalizeSentencesKey)
        view.defaults = defaults
        let host = makeHost()
        view.delegate = host
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = scrollView
        addTeardownBlock { window.close() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        /// A real key press, the way the app receives one: `keyDown` →
        /// `interpretKeyEvents` → `insertText`. Typing through `keyDown` is
        /// what sets up `NSTextView`'s own typing state, which the direct
        /// `insertText` calls above never do.
        func press(_ character: String, keyCode: UInt16) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: character, charactersIgnoringModifiers: character,
                                         isARepeat: false, keyCode: keyCode)!
            keystroke(host) { view.keyDown(with: event) }
        }

        press("m", keyCode: 46)
        XCTAssertEqual(units(view.string), units("M"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))

        host.undoManager.undo()
        XCTAssertEqual(units(view.string), units("m"), "⌘Z takes just the capital back")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0),
                       "the restored letter must not come back selected — typing on would replace it")

        host.undoManager.redo()
        XCTAssertEqual(units(view.string), units("M"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0),
                       "after redo the caret is after the capital, not on it")

        host.undoManager.undo()
        XCTAssertEqual(units(view.string), units("m"))
        press("d", keyCode: 2)
        XCTAssertEqual(units(view.string), units("md"), "typing on after the undo keeps the letter")
    }

    func testUndoOfAWordInsertionRestoresTheWord() throws {
        let view = try makeView()
        let host = makeHost()
        view.delegate = host
        view.allowsUndo = true
        keystroke(host) { type("hello", into: view) }
        XCTAssertEqual(units(view.string), units("Hello"))
        host.undoManager.undo()
        XCTAssertEqual(units(view.string), units("hello"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 0),
                       "the selection from before the capital, after the word")
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0))
        host.undoManager.undo()
        XCTAssertEqual(units(view.string), units(""))
    }

    // MARK: - The eight consequences of the amended §3.4, hosted

    func testConsequence1DeleteBothLettersAndRetypeTheWord() throws {
        let view = try makeView()
        type("m", into: view)
        type("d", into: view)
        XCTAssertEqual(units(view.string), units("Md"))
        view.deleteBackward(nil)
        view.deleteBackward(nil)
        XCTAssertEqual(units(view.string), units(""))
        type("m", into: view)
        type("d", into: view)
        XCTAssertEqual(units(view.string), units("md"))
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
    }

    func testConsequence2DeleteAllThreeLettersAndRetypeIOS() throws {
        let view = try makeView()
        for letter in ["i", "O", "S"] { type(letter, into: view) }
        XCTAssertEqual(units(view.string), units("IOS"))
        for _ in 0..<3 { view.deleteBackward(nil) }
        XCTAssertEqual(units(view.string), units(""))
        for letter in ["i", "O", "S"] { type(letter, into: view) }
        XCTAssertEqual(units(view.string), units("iOS"))
    }

    func testConsequence3DeleteFiveKeystrokesAndRetypeThePhrase() throws {
        let view = try makeView()
        let phrase = ["m", "d", " ", "i", "s"]
        for letter in phrase { type(letter, into: view) }
        XCTAssertEqual(units(view.string), units("Md is"))
        for _ in phrase { view.deleteBackward(nil) }
        XCTAssertEqual(units(view.string), units(""))
        for letter in phrase { type(letter, into: view) }
        XCTAssertEqual(units(view.string), units("md is"))
    }

    func testConsequence4SelectTheWholeWordAndRetypeIt() throws {
        let view = try makeView()
        type("m", into: view)
        type("d", into: view)
        XCTAssertEqual(units(view.string), units("Md"))
        view.setSelectedRange(NSRange(location: 0, length: 2))
        type("md", into: view)
        XCTAssertEqual(units(view.string), units("md"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
        // Letter by letter over the selection too: the first letter is the
        // retype, the second is typed after it.
        reload(view, to: "")
        type("m", into: view)
        type("d", into: view)
        view.setSelectedRange(NSRange(location: 0, length: 2))
        type("m", into: view)
        type("d", into: view)
        XCTAssertEqual(units(view.string), units("md"))
    }

    func testConsequence5ALetterTypedBeforeTheCapitalDoesNotDeleteIt() throws {
        let view = try makeView()
        type("m", into: view)
        type("d", into: view)
        XCTAssertEqual(units(view.string), units("Md"))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        type("a", into: view)
        XCTAssertEqual(units(view.string), units("AMd"))
        // md's new capital is the tracked one; the M is forgotten, not
        // armed: deleting it and retyping it capitalizes again … 
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0))
        XCTAssertFalse(view.capitalOverride.isArmed)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.deleteBackward(nil)
        XCTAssertEqual(units(view.string), units("Ad"))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0))
        // … while deleting the A arms the override there.
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.deleteBackward(nil)
        XCTAssertEqual(units(view.string), units("d"))
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0))
        type("a", into: view)
        XCTAssertEqual(units(view.string), units("ad"))

        // The shift itself, with a letter md declines in front of the
        // capital: the tracked capital moves to p + 1 and a delete-and-
        // retype there is still honoured.
        reload(view, to: "Hi.")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        type(" ", into: view)
        type("m", into: view)
        XCTAssertEqual(units(view.string), units("Hi. M"))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 4))
        view.setSelectedRange(NSRange(location: 3, length: 0))
        type("a", into: view)
        XCTAssertEqual(units(view.string), units("Hi.a M"))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 5), "shifted with the text")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.deleteBackward(nil)
        XCTAssertTrue(view.capitalOverride.isArmed(at: 5))
        type("m", into: view)
        XCTAssertEqual(units(view.string), units("Hi.a m"))
    }

    func testConsequence6UndoRestoresTheLetterAndTypingOnKeepsIt() throws {
        // Hosted with the test's own event grouping (see the header): the
        // capital is its own undo step, Undo restores the lowercase letter
        // — the edit that removed the capital, so the override is armed at
        // p and the letter is not re-judged — and `d` typed after it is an
        // insertion elsewhere, which clears the override and is typed as
        // the rule decides, mid-word.
        let view = try makeView()
        let host = makeHost()
        view.delegate = host
        view.allowsUndo = true
        keystroke(host) { type("m", into: view) }
        XCTAssertEqual(units(view.string), units("M"))
        host.undoManager.undo()
        XCTAssertEqual(units(view.string), units("m"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0))
        keystroke(host) { type("d", into: view) }
        XCTAssertEqual(units(view.string), units("md"))
        XCTAssertEqual(view.capitalOverride, CapitalOverride())
        // And the other way the writer may go on: Undo, then delete the
        // restored letter and retype it — still lowercase.
        reload(view, to: "")
        keystroke(host) { type("m", into: view) }
        host.undoManager.undo()
        XCTAssertEqual(units(view.string), units("m"))
        keystroke(host) { view.deleteBackward(nil) }
        keystroke(host) { type("m", into: view) }
        XCTAssertEqual(units(view.string), units("m"))
    }

    func testConsequence7ACutBeforeTheCapitalMovesTheTracking() throws {
        preservingGeneralPasteboard()
        let view = try makeView()
        for letter in ["x", "x", "x", ".", " "] { type(letter, into: view) }
        type("m", into: view)
        XCTAssertEqual(units(view.string), units("Xxx. M"))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 5))
        // Select and cut everything before the capital.
        view.setSelectedRange(NSRange(location: 0, length: 5))
        view.cut(nil)
        XCTAssertEqual(units(view.string), units("M"), "cut removed the selection")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string).map(units), units("Xxx. "),
                       "and put it on the clipboard")
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0), "the tracking survived the cut")
        // Backspace deletes the M; retyped, it stays lowercase.
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.deleteBackward(nil)
        XCTAssertEqual(units(view.string), units(""))
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0))
        type("m", into: view)
        XCTAssertEqual(units(view.string), units("m"))

        // The same with the override already armed when the cut happens:
        // q moves with the text.
        reload(view, to: "")
        for letter in ["x", "x", "x", ".", " "] { type(letter, into: view) }
        type("m", into: view)
        view.deleteBackward(nil)
        XCTAssertTrue(view.capitalOverride.isArmed(at: 5))
        view.setSelectedRange(NSRange(location: 0, length: 5))
        view.cut(nil)
        XCTAssertEqual(units(view.string), units(""))
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0))
        type("m", into: view)
        XCTAssertEqual(units(view.string), units("m"))
    }

    func testConsequence8DeletingAfterTheCapitalLeavesItStanding() throws {
        let view = try makeView()
        type("m", into: view)
        type("d", into: view)
        XCTAssertEqual(units(view.string), units("Md"))
        view.deleteBackward(nil)
        XCTAssertEqual(units(view.string), units("M"))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0))
        XCTAssertFalse(view.capitalOverride.isArmed)
        type("d", into: view)
        XCTAssertEqual(units(view.string), units("Md"))
        XCTAssertFalse(view.capitalOverride.isArmed)
        // A forward delete after it neither.
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.deleteForward(nil)
        XCTAssertEqual(units(view.string), units("M"))
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0))
        // But a forward delete over it, from in front, removes it.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.deleteForward(nil)
        XCTAssertEqual(units(view.string), units(""))
        XCTAssertTrue(view.capitalOverride.isArmed(at: 0))
    }

}
