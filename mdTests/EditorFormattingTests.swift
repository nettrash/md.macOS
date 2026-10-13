//
//  EditorFormattingTests.swift
//  mdTests
//
//  The Mac's formatting commands around the shared `MarkdownFormatting`
//  (whose vectors `FormattingTests` runs): the Format menu's chords, and an
//  edit made through the real editor — one Undo step, the typed wrap and its
//  setting.
//

import AppKit
import SwiftUI
import XCTest
@testable import md

@MainActor
final class EditorFormattingTests: XCTestCase {

    // MARK: The menu

    /// The family's chords on Apple (md.win `docs/formatting.md` §5, and the
    /// table md for iPad pins against this one).
    func testTheFormatMenuCarriesTheFamilysChords() {
        let expected: [(MarkdownFormatting.Op, Character, EventModifiers)] = [
            (.bold, "b", .command), (.italic, "i", .command),
            (.code, "c", [.command, .shift]), (.strikethrough, "x", [.command, .shift]),
            (.link, "k", .command),
            (.heading1, "1", [.command, .option]), (.heading2, "2", [.command, .option]),
            (.heading3, "3", [.command, .option]), (.heading4, "4", [.command, .option]),
            (.heading5, "5", [.command, .option]), (.heading6, "6", [.command, .option]),
            (.bulletList, "l", [.command, .shift]), (.taskList, "t", [.command, .shift]),
            (.quote, "'", .command),
            (.indent, "]", .command), (.outdent, "[", .command),
        ]
        XCTAssertEqual(FormatMenu.all.count, expected.count)
        for (row, (op, key, modifiers)) in zip(FormatMenu.all, expected) {
            XCTAssertEqual(row.op, op)
            XCTAssertEqual(row.key.character, key, row.title)
            XCTAssertEqual(row.modifiers, modifiers, row.title)
        }
        // Every command but the phone bar's heading cycle is on the menu.
        XCTAssertEqual(Set(FormatMenu.all.map(\.op.rawValue)),
                       Set(MarkdownFormatting.Op.allCases.map(\.rawValue)).subtracting(["headingCycle"]))
    }

    /// No Format chord collides with another of the Mac's own: View's ⌘1–⌘3
    /// and Zen, Book's ⇧⌘B, Go's ⌃⌘↑ / ⌃⌘↓, Print, Edit ▸ Find's five, or
    /// the system's ⇧⌘Q Log Out.
    func testNoFormatChordCollides() {
        func id(_ key: Character, _ modifiers: EventModifiers) -> String { "\(key)|\(modifiers.rawValue)" }
        let taken: Set<String> = [
            id("1", .command), id("2", .command), id("3", .command),
            id("b", [.command, .shift]), id("p", .command),
            id("f", .command), id("f", [.command, .option]), id("g", .command), id("g", [.command, .shift]),
            id("e", .command), id("q", [.command, .shift]),
        ]
        let chords = FormatMenu.all.map { id($0.key.character, $0.modifiers) }
        XCTAssertEqual(Set(chords).count, chords.count, "two Format rows share a chord")
        XCTAssertTrue(Set(chords).isDisjoint(with: taken), "a Format chord is already the Mac's")
    }

    // MARK: Through the editor

    private final class UndoHost: NSObject, NSTextViewDelegate {
        let undoManager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
    }

    private func makeEditor(_ text: String, wrap: Bool = true,
                            capitalize: Bool = false) throws -> (SmartTextView, UndoHost) {
        let scroll = MarkdownEditor.makeScrollView()
        let view = try XCTUnwrap(scroll.documentView as? SmartTextView)
        let name = "md.format.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        defaults.set(capitalize, forKey: TypingSettings.capitalizeSentencesKey)
        defaults.set(wrap, forKey: FormattingSettings.wrapSelectionKey)
        view.defaults = defaults
        let host = UndoHost()
        host.undoManager.groupsByEvent = false
        view.delegate = host
        view.string = text
        return (view, host)
    }

    func testACommandIsOneUndoStep() throws {
        let (view, host) = try makeEditor("say hello now")
        view.setSelectedRange(NSRange(location: 4, length: 5))
        view.applyFormatting(.bold)
        XCTAssertEqual(view.string, "say **hello** now")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 5))
        view.applyFormatting(.heading2)
        XCTAssertEqual(view.string, "## say **hello** now")
        host.undoManager.undo()
        XCTAssertEqual(view.string, "say **hello** now")
        host.undoManager.undo()
        XCTAssertEqual(view.string, "say hello now")
        XCTAssertFalse(host.undoManager.canUndo)
    }

    func testANoEditCommandLeavesNothingToUndo() throws {
        let (view, host) = try makeEditor("text")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.applyFormatting(.outdent)
        XCTAssertEqual(view.string, "text")
        XCTAssertFalse(host.undoManager.canUndo)
    }

    func testTypingOverASelectionWrapsItAndUndoesInOneStep() throws {
        let (view, host) = try makeEditor("area pi r")
        view.setSelectedRange(NSRange(location: 5, length: 4))
        host.undoManager.beginUndoGrouping()
        view.insertText("$", replacementRange: NSRange(location: NSNotFound, length: 0))
        while host.undoManager.groupingLevel > 0 { host.undoManager.endUndoGrouping() }
        XCTAssertEqual(view.string, "area $pi r$")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 4))
        host.undoManager.undo()
        XCTAssertEqual(view.string, "area pi r")
    }

    /// One keystroke's undo group, as the event loop would open it.
    private func keystroke(_ host: UndoHost, _ body: () -> Void) {
        host.undoManager.beginUndoGrouping()
        body()
        while host.undoManager.groupingLevel > 0 { host.undoManager.endUndoGrouping() }
    }

    /// Formatting a word md has just capitalized is not the writer deleting
    /// that capital: `**Word**` must not arm the delete-and-retype override
    /// (§3.4) where `Word` began, or the next word typed there — straight
    /// after the command, or after its Undo — would skip the sentence rule.
    func testFormattingAFreshCapitalLeavesNoOverrideBehind() throws {
        let noRange = NSRange(location: NSNotFound, length: 0)
        for viaUndo in [false, true] {
            let (view, host) = try makeEditor("", capitalize: true)
            keystroke(host) { view.insertText("word", replacementRange: noRange) }
            XCTAssertEqual(view.string, "Word")
            XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0))

            view.setSelectedRange(NSRange(location: 0, length: 4))
            view.applyFormatting(.bold)
            XCTAssertEqual(view.string, "**Word**")
            XCTAssertFalse(view.capitalOverride.isArmed, "the command armed the override")
            if viaUndo {
                host.undoManager.undo()
                XCTAssertEqual(view.string, "Word")
                XCTAssertFalse(view.capitalOverride.isArmed, "the command's Undo armed the override")
            }

            view.setSelectedRange(NSRange(location: 0, length: 0))
            keystroke(host) { view.insertText("big", replacementRange: noRange) }
            XCTAssertEqual(view.string, viaUndo ? "BigWord" : "Big**Word**", "viaUndo: \(viaUndo)")
        }
    }

    func testTypingAWrapOverAFreshCapitalLeavesNoOverrideBehind() throws {
        let noRange = NSRange(location: NSNotFound, length: 0)
        let (view, host) = try makeEditor("", capitalize: true)
        keystroke(host) { view.insertText("word", replacementRange: noRange) }
        view.setSelectedRange(NSRange(location: 0, length: 4))
        keystroke(host) { view.insertText("*", replacementRange: noRange) }
        XCTAssertEqual(view.string, "*Word*")
        XCTAssertFalse(view.capitalOverride.isArmed)
    }

    func testWithTheSettingOffTypingReplacesTheSelection() throws {
        let (view, host) = try makeEditor("word", wrap: false)
        view.setSelectedRange(NSRange(location: 0, length: 4))
        keystroke(host) { view.insertText("*", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        XCTAssertEqual(view.string, "*")
    }

    func testOtherCharactersAndACaretAreOrdinaryTyping() throws {
        let (view, host) = try makeEditor("word")
        view.setSelectedRange(NSRange(location: 0, length: 4))
        keystroke(host) { view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        XCTAssertEqual(view.string, "a")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        keystroke(host) { view.insertText("*", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        XCTAssertEqual(view.string, "a*")
    }

    func testTheSettingDefaultsToOn() throws {
        let name = "md.format.default.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(FormattingSettings.wrapSelection(in: defaults))
        defaults.set(false, forKey: FormattingSettings.wrapSelectionKey)
        XCTAssertFalse(FormattingSettings.wrapSelection(in: defaults))
    }
}
