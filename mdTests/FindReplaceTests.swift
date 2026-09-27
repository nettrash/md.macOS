//
//  FindReplaceTests.swift
//  mdTests
//
//  Find and Replace in the editing pane. The UI is `NSTextFinder`'s own
//  find bar, driven by the standard Edit ▸ Find menu, so what md owns is
//  narrow and is exactly what is pinned here:
//
//  * the text view md builds is a find client, and a find client that can
//    *replace* — `usesFindBar`, incremental searching, selectable and
//    editable — and the scroll view around it is the bar's container;
//  * the Edit ▸ Find rows are in the menu bar with the chords a Mac writer
//    expects — SwiftUI builds no Find submenu of its own, so md's
//    `DocumentCommands` supplies one, and ⌘F is a menu key equivalent on
//    macOS rather than a text-view key binding: without the rows there is
//    no way into the find bar at all;
//  * a Find row always has somewhere to go: a window already showing its
//    editing pane is served at once, and a window showing only the preview
//    (or Zen reading) nudges the editor back and is served as soon as
//    SwiftUI has built it — bounded, so the retry gives up rather than
//    ambushing a mode switch minutes later;
//  * a replace reaches the `text` binding — which is what marks the
//    document dirty and starts autosave — exactly once for a whole
//    Replace All, and is one undo step;
//  * `SmartTextView` sees a replace as the external edit it is: a tracked
//    capital moves with the text when the replacement is elsewhere, and is
//    let go when the replacement lands on it (§3.4).
//
//  HOW A REPLACE IS DRIVEN HERE
//  ----------------------------
//  `NSTextFinder` reads its search and replacement strings from the find
//  bar's own text fields, which exist only in a window on screen; there is
//  no API to hand it either. What it does with them, though, is a published
//  contract (NSTextFinder.h): it asks the client `shouldReplaceCharacters`,
//  has the client `replaceCharacters` in each range — "starting from the
//  last match and moving toward the first, in order to preserve the indexes
//  of the matches which precede the current one" — and finally tells it
//  `didReplaceCharacters`. `findBarReplace` below is that sequence, against
//  the very text view the app builds. Nothing is simulated but the two
//  strings the writer would have typed.
//

import XCTest
import SwiftUI
import AppKit
@testable import md

/// `NSTextView` implements every one of `NSTextFinderClient`'s (all
/// optional) methods — being the find bar's client is what an `NSTextView`
/// in a scroll view *is* — but AppKit declares the conformance in its
/// implementation rather than in the header, so Swift cannot see it. The
/// tests state it in order to call the replace methods by name instead of
/// by selector; nothing is added and no behaviour changes.
extension NSTextView: NSTextFinderClient {}

final class FindReplaceTests: XCTestCase {

    // MARK: - Fixtures

    /// Holds the document text a `MarkdownEditor` binding writes to.
    private final class TextBox {
        var text: String
        init(_ text: String) { self.text = text }
    }

    /// The editing pane as `makeNSView` builds it: the app's own scroll
    /// view and text view, a coordinator wired as the delegate, and a
    /// binding standing in for the document's.
    private func makeEditor(_ text: String, undoOverride: UndoManager? = nil)
        throws -> (box: TextBox, view: SmartTextView, scrollView: NSScrollView,
                   coordinator: MarkdownEditor.Coordinator) {
        let box = TextBox(text)
        let editor = MarkdownEditor(text: Binding(get: { box.text }, set: { box.text = $0 }),
                                    undoOverride: undoOverride)
        let coordinator = MarkdownEditor.Coordinator(editor)
        let scrollView = MarkdownEditor.makeScrollView()
        let view = try XCTUnwrap(scrollView.documentView as? SmartTextView)
        view.delegate = coordinator
        view.string = text
        coordinator.textView = view
        return (box, view, scrollView, coordinator)
    }

    /// A defaults store of its own, so nothing here reads or disturbs the
    /// real app's Edit ▸ Typing toggles.
    private func withOwnTypingSettings(_ view: SmartTextView) throws {
        let name = "md.find.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(true, forKey: TypingSettings.continueListsKey)
        defaults.set(true, forKey: TypingSettings.capitalizeSentencesKey)
        view.defaults = defaults
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
    }

    private let noRange = NSRange(location: NSNotFound, length: 0)

    /// One Replace (or Replace All) exactly as `NSTextFinder` performs it
    /// against its client — see the file header.
    private func findBarReplace(_ ranges: [NSRange], with replacement: String,
                                in view: NSTextView) {
        let client: NSTextFinderClient = view
        let values = ranges.map { NSValue(range: $0) }
        let strings = [String](repeating: replacement, count: ranges.count)
        guard client.shouldReplaceCharacters?(inRanges: values, with: strings) ?? true else { return }
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            client.replaceCharacters?(in: range, with: replacement)
        }
        client.didReplaceCharacters?()
    }

    /// Every match of `needle` in `haystack`, by the one rule every md
    /// edition matches by (`TextSearch.cs`): ordinal, case-insensitive.
    private func matches(of needle: String, in haystack: String) -> [NSRange] {
        let text = haystack as NSString
        var found: [NSRange] = []
        var from = 0
        while from < text.length {
            let rest = NSRange(location: from, length: text.length - from)
            let hit = text.range(of: needle, options: [.caseInsensitive, .literal], range: rest)
            guard hit.location != NSNotFound else { break }
            found.append(hit)
            from = hit.location + max(hit.length, 1)
        }
        return found
    }

    // MARK: - The editor is a find client that can replace

    func testTheEditorsTextViewUsesTheFindBar() throws {
        let scrollView = MarkdownEditor.makeScrollView()
        let view = try XCTUnwrap(scrollView.documentView as? SmartTextView)

        XCTAssertTrue(view.usesFindBar, "⌘F would open the old modal Find panel")
        XCTAssertTrue(view.isIncrementalSearchingEnabled, "matches would not light up while typing")
        XCTAssertTrue(view.isSelectable, "NSTextFinder refuses an unselectable client")
        XCTAssertTrue(view.isEditable, "an uneditable client is offered Find but never Replace")
        // The bar drops into the scroll view; without a container there is
        // nowhere for it to appear.
        XCTAssertTrue(view.enclosingScrollView === scrollView)
        XCTAssertEqual(scrollView.findBarPosition, .aboveContent)
    }

    /// The Find rows the menu bar sends: each is a `performTextFinderAction:`
    /// carrying an `NSTextFinder.Action` in its tag, and the text view
    /// validates every one of them — including the replace family, which it
    /// would refuse if it were not editable.
    func testTheTextViewValidatesEveryFindAndReplaceAction() throws {
        let scrollView = MarkdownEditor.makeScrollView()
        let view = try XCTUnwrap(scrollView.documentView as? SmartTextView)
        let action = #selector(NSResponder.performTextFinderAction(_:))

        for finderAction: NSTextFinder.Action in [.showFindInterface, .nextMatch, .previousMatch,
                                                  .showReplaceInterface,
                                                  .replace, .replaceAll, .replaceAndFind] {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.tag = finderAction.rawValue
            XCTAssertTrue(view.validateUserInterfaceItem(item),
                          "the editor refused NSTextFinder.Action rawValue \(finderAction.rawValue)")
        }

        // Use Selection for Find (⌘E) is the one row that depends on the
        // editor's state rather than its configuration: there has to be a
        // selection to search for.
        let useSelection = NSMenuItem(title: "", action: action, keyEquivalent: "")
        useSelection.tag = NSTextFinder.Action.setSearchString.rawValue
        view.string = "old and old"
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(view.validateUserInterfaceItem(useSelection), "nothing is selected")
        view.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertTrue(view.validateUserInterfaceItem(useSelection))
    }

    /// The whole chain md owns, end to end: a Find row's action arrives at
    /// the editor and the find bar opens over it. (`performTextFinderAction`
    /// is what `DocumentCommands.performFinderAction` sends; here it is
    /// delivered straight to the text view, since a hosted test has no key
    /// window for the responder chain to start from.)
    func testAFindActionOpensAndClosesTheFindBarOverTheEditor() throws {
        let scrollView = MarkdownEditor.makeScrollView()
        let view = try XCTUnwrap(scrollView.documentView as? SmartTextView)
        view.string = "old and old"
        XCTAssertFalse(scrollView.isFindBarVisible)

        view.performTextFinderAction(finderSender(.showReplaceInterface))
        XCTAssertTrue(scrollView.isFindBarVisible,
                      "Find and Replace did not open the find bar")

        view.performTextFinderAction(finderSender(.hideFindInterface))
        XCTAssertFalse(scrollView.isFindBarVisible)
    }

    /// What a Find menu row sends: `performTextFinderAction:` with the
    /// action in the sender's tag.
    private func finderSender(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(NSResponder.performTextFinderAction(_:)),
                              keyEquivalent: "")
        item.tag = action.rawValue
        return item
    }

    /// SwiftUI's Edit menu has no Find submenu — it goes Undo, Redo, Cut,
    /// Copy, Paste, Delete, Select All and straight on to AutoFill — so
    /// `DocumentCommands` supplies one. These are the rows and the chords a
    /// Mac writer reaches for; ⌘F is a menu key equivalent on macOS, so a
    /// missing row is a chord that does nothing at all.
    func testEditMenuCarriesTheFindRowsAndTheirChords() throws {
        let menu = try XCTUnwrap(mainMenuWhenBuilt(), "the test host built no menu bar")
        let edit = try XCTUnwrap(menu.items.first { $0.title == "Edit" }?.submenu,
                                 "no Edit menu: \(describe(menu))")
        let find = try XCTUnwrap(edit.items.first { $0.title == "Find" }?.submenu,
                                 "no Edit ▸ Find submenu: \(describe(edit))")

        let expected: [(String, String, NSEvent.ModifierFlags)] = [
            ("Find…", "f", [.command]),
            ("Find and Replace…", "f", [.command, .option]),
            ("Find Next", "g", [.command]),
            ("Find Previous", "g", [.command, .shift]),
            ("Use Selection for Find", "e", [.command])
        ]
        for (title, key, modifiers) in expected {
            let row = try XCTUnwrap(find.items.first { $0.title == title },
                                    "no \(title) row: \(describe(find))")
            XCTAssertEqual(row.keyEquivalent, key, "\(title) lost its key")
            XCTAssertEqual(row.keyEquivalentModifierMask, modifiers, "\(title) lost its modifiers")
            XCTAssertFalse(row.isSeparatorItem)
        }

        // The Typing submenu the earlier work put in the same group is still
        // beside it — neither displaced the other.
        XCTAssertNotNil(edit.items.first { $0.title == "Typing" }?.submenu)
    }

    /// SwiftUI builds the menu bar as the app finishes launching, which can
    /// be after the first test starts; give it a moment rather than racing.
    private func mainMenuWhenBuilt() -> NSMenu? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let menu = NSApp?.mainMenu,
               menu.items.contains(where: { $0.title == "Edit" }) { return menu }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return NSApp?.mainMenu
    }

    private func describe(_ menu: NSMenu) -> String {
        menu.items.map { item in
            item.submenu.map { "\(item.title)(\(describe($0)))" } ?? item.title
        }.joined(separator: ", ")
    }

    /// When no text view has focus — a window whose editing pane the writer
    /// has not clicked into yet — the Find rows fall back to the frontmost
    /// window's editor rather than dropping the action. This is the search
    /// that finds it, and it must find md's own editor, never the find
    /// bar's search field (whose field editor is an `NSTextView` too, in
    /// the very same tree).
    func testTheFindFallbackFindsTheEditingPaneAndNotTheFindBar() throws {
        let scrollView = MarkdownEditor.makeScrollView()
        let view = try XCTUnwrap(scrollView.documentView as? SmartTextView)
        view.string = "old and old"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        // A sidebar of ordinary controls first, so the search really walks
        // past them rather than finding the first thing it meets.
        container.addSubview(NSTextField(labelWithString: "Contents"))
        scrollView.frame = container.bounds
        container.addSubview(scrollView)

        XCTAssertTrue(DocumentCommands.firstEditor(in: container) === view)

        // With the find bar open, its own field is in the tree as well.
        view.performTextFinderAction(finderSender(.showReplaceInterface))
        XCTAssertTrue(scrollView.isFindBarVisible)
        XCTAssertTrue(DocumentCommands.firstEditor(in: container) === view,
                      "the fallback would have searched the find bar's own field")
    }

    /// A window with no editing pane — Preview mode, a panel — has nothing
    /// to find in, and the fallback says so rather than guessing.
    func testTheFindFallbackFindsNothingWithoutAnEditingPane() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.addSubview(NSTextField(labelWithString: "Preview"))
        container.addSubview(NSButton(title: "Close", target: nil, action: nil))
        XCTAssertNil(DocumentCommands.firstEditor(in: container))
        XCTAssertNil(DocumentCommands.firstEditor(in: nil))
    }

    // MARK: - ⌘F in a window showing only the preview

    /// A real window holding whatever pane the mode is showing — the whole
    /// fixture the delivery needs, since what it looks for is an editing
    /// pane inside a window. Never ordered in: nothing here needs to be on
    /// screen, and a test must not take the writer's keyboard.
    private func makeWindow(showing view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false          // ARC owns it, not AppKit
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.frame = content.bounds
        content.addSubview(view)
        window.contentView = content
        addTeardownBlock { window.close() }
        return window
    }

    /// A window that is showing its editing pane answers a Find row at once,
    /// whether or not the writer has ever clicked into the text: the editor
    /// is given the keyboard and then performs the action.
    ///
    /// ⌘E is the row that shows both halves in one go — it needs the
    /// editor's *selection*, so it can only have worked if the editor really
    /// was the one asked — and unlike ⌘F it leaves the keyboard where it
    /// put it, instead of handing it straight on to the find bar's own
    /// search field.
    func testAFindActionReachesTheEditingPaneOfAWindowThatHasOne() throws {
        let scrollView = MarkdownEditor.makeScrollView()
        let view = try XCTUnwrap(scrollView.documentView as? SmartTextView)
        view.string = "old and older"
        view.setSelectedRange(NSRange(location: 8, length: 5))     // "older"
        let window = makeWindow(showing: scrollView)
        try withOwnFindPasteboard("something else")

        XCTAssertTrue(DocumentCommands.deliverFinderAction(finderSender(.setSearchString),
                                                           to: window))
        XCTAssertTrue(window.firstResponder === view, "the editor was not given the keyboard")
        XCTAssertEqual(NSPasteboard(name: .find).string(forType: .string), "older",
                       "Use Selection for Find never reached the editor")

        // …and ⌘F over the same window opens the bar.
        XCTAssertTrue(DocumentCommands.deliverFinderAction(finderSender(.showFindInterface),
                                                           to: window))
        XCTAssertTrue(scrollView.isFindBarVisible)
    }

    /// Preview only (or Zen reading): the window has no editing pane, so
    /// there is nothing to deliver to — and this is the case that used to
    /// end the command, leaving ⌘F to do nothing at all while its menu row
    /// stayed enabled. `ViewModeSelection.showEditor` now nudges the editor
    /// back, but a nudge only sets SwiftUI state: the text view does not
    /// exist until SwiftUI has built the pane a runloop turn or two later.
    /// The delayed delivery is what still opens the find bar over it.
    func testFindInAPreviewOnlyWindowWaitsForTheEditorTheNudgeBringsBack() throws {
        let scrollView = MarkdownEditor.makeScrollView()
        let view = try XCTUnwrap(scrollView.documentView as? SmartTextView)
        view.string = "old and old"
        let window = makeWindow(showing: NSTextField(labelWithString: "Preview"))

        let sender = finderSender(.showFindInterface)
        XCTAssertFalse(DocumentCommands.deliverFinderAction(sender, to: window),
                       "a preview-only window has no editing pane to find in")

        DocumentCommands.deliverFinderAction(sender, to: window, whenTheEditorAppears: 12)
        // The nudge's effect, late enough that the first try misses and the
        // retry is what lands it: SwiftUI swaps the preview for the editing
        // pane only after its own update and display pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + DocumentCommands.retryInterval * 1.5) {
            let content = window.contentView
            content?.subviews.forEach { $0.removeFromSuperview() }
            scrollView.frame = content?.bounds ?? .zero
            content?.addSubview(scrollView)
        }

        spinRunLoop(until: { scrollView.isFindBarVisible })
        XCTAssertTrue(scrollView.isFindBarVisible,
                      "⌘F died in a preview-only window instead of showing the source")
    }

    /// …and the waiting is bounded. A window that never grows an editing
    /// pane — the writer moved on, the nudge landed nowhere — must stop the
    /// retry, not hold the action open for a mode switch minutes later.
    func testTheDelayedFindDeliveryStopsWhenNoEditorAppears() throws {
        let scrollView = MarkdownEditor.makeScrollView()
        let window = makeWindow(showing: NSTextField(labelWithString: "Preview"))

        let attempts = 2
        DocumentCommands.deliverFinderAction(finderSender(.showFindInterface), to: window,
                                             whenTheEditorAppears: attempts)
        // Let the attempts run out against a window with no editing pane.
        spinRunLoop(for: DocumentCommands.retryInterval * Double(attempts + 2))

        let content = try XCTUnwrap(window.contentView)
        scrollView.frame = content.bounds
        content.addSubview(scrollView)
        spinRunLoop(for: DocumentCommands.retryInterval * Double(attempts + 2))

        XCTAssertFalse(scrollView.isFindBarVisible,
                       "the delayed delivery never gave up — a later pane got a stale ⌘F")
    }

    /// Run the main runloop for a while, which is what drains the delayed
    /// delivery's waits.
    private func spinRunLoop(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
        }
    }

    private func spinRunLoop(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !done() {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - A reload under an open find bar

    /// The find bar caches the ranges of the matches it found. A revert, a
    /// "Reload from Disk" in the book workspace, or any other programmatic
    /// whole-text change goes through `MarkdownEditor.updateNSView` while
    /// that cache is live — and the editor is NOT recreated for it
    /// (`.id(editingURL)` does not change), so the same `NSTextFinder`
    /// carries on against a document that is gone.
    ///
    /// Assigning `string` does not tell it: ⌘G then finds nothing and
    /// Replace All rewrites at the stale offsets — and when the new text is
    /// shorter, `NSMutableRLEArray` throws `NSRangeException` and the whole
    /// app goes with it, taking every unsaved window. `replaceWholeText`
    /// edits through `shouldChangeText(in:replacementString:)` instead,
    /// which is what invalidates the cache.
    ///
    /// Both halves are asserted here, because they fail separately: Find
    /// Next going dead is the quiet one, the crash is the loud one.
    func testAReloadUnderAnOpenFindBarKeepsFindNextAndReplaceAllHonest() throws {
        let scrollView = MarkdownEditor.makeScrollView()
        let view = try XCTUnwrap(scrollView.documentView as? SmartTextView)
        view.string = "alpha alpha alpha alpha and alpha"

        try withOwnFindPasteboard("alpha")
        view.performTextFinderAction(finderSender(.showFindInterface))
        view.performTextFinderAction(finderSender(.nextMatch))

        // The file changed underneath and was reloaded: exactly what
        // `updateNSView` does, with the editor left in place.
        MarkdownEditor.replaceWholeText(of: view, with: "zzz alpha zzz alpha")
        XCTAssertEqual(view.string, "zzz alpha zzz alpha")

        // ⌘G. The first match of "alpha" in the *new* text is at 4.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.performTextFinderAction(finderSender(.nextMatch))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 5),
                       "Find Next went dead after the reload — stale match ranges")

        // Replace All. Whatever is in the replace field, every match must
        // go and nothing else may be touched.
        view.performTextFinderAction(finderSender(.replaceAll))
        XCTAssertFalse(view.string.lowercased().contains("alpha"),
                       "Replace All missed matches it had cached at the old offsets")
        XCTAssertEqual(occurrences(of: "zzz", in: view.string), 2,
                       "Replace All rewrote text that was not a match: \(view.string)")
    }

    /// The same reload with the new text *shorter* than the old — the shape
    /// that crashes rather than mangles.
    func testAShorteningReloadUnderAnOpenFindBarSurvivesReplaceAll() throws {
        let scrollView = MarkdownEditor.makeScrollView()
        let view = try XCTUnwrap(scrollView.documentView as? SmartTextView)
        view.string = "alpha alpha alpha alpha and alpha"

        try withOwnFindPasteboard("alpha")
        view.performTextFinderAction(finderSender(.showFindInterface))
        view.performTextFinderAction(finderSender(.nextMatch))

        MarkdownEditor.replaceWholeText(of: view, with: "alpha")
        // No ⌘G in between: this is the writer who reloads and goes
        // straight for Replace All. `NSRangeException` here is fatal.
        view.performTextFinderAction(finderSender(.replaceAll))
        XCTAssertFalse(view.string.lowercased().contains("alpha"))
    }

    /// A reload is not one of the writer's edits: `string` assignment never
    /// put one on the undo stack, and the edit that replaced it must not
    /// either — ⌘Z after a revert would otherwise put the old file back.
    /// The typewriter face has to survive it too.
    func testAReloadIsNotAnUndoStepAndKeepsTheTypingAttributes() throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let editor = try makeEditor("first text", undoOverride: undo)
        XCTAssertFalse(undo.canUndo)

        MarkdownEditor.replaceWholeText(of: editor.view, with: "second text")

        XCTAssertEqual(editor.view.string, "second text")
        XCTAssertFalse(undo.canUndo, "the reload landed on the writer's undo stack")

        var effective = NSRange()
        let storage = try XCTUnwrap(editor.view.textStorage)
        let attributes = storage.attributes(at: 0, effectiveRange: &effective)
        XCTAssertEqual(effective, NSRange(location: 0, length: storage.length),
                       "the reloaded text is not uniformly attributed")
        XCTAssertEqual(attributes[.font] as? NSFont, Typewriter.editorFont())
        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, Typewriter.inkNSColor)
    }

    /// `replaceWholeText` is what `updateNSView` calls, and §3.4 says an
    /// external replacement clears both the tracked capital and the armed
    /// override.
    func testAReloadClearsTheTrackedCapital() throws {
        let editor = try makeEditor("")
        try withOwnTypingSettings(editor.view)
        let view = editor.view

        view.insertText("m", replacementRange: noRange)
        XCTAssertEqual(view.string, "M")
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 0))

        MarkdownEditor.replaceWholeText(of: view, with: "M")
        XCTAssertEqual(view.capitalOverride, CapitalOverride(),
                       "a reload left md defending a capital in text that is gone")
    }

    /// The system-wide find pasteboard is what `NSTextFinder` seeds its
    /// search field from; it is shared with every other app on the Mac, so
    /// it is put back exactly as it was found.
    private func withOwnFindPasteboard(_ needle: String) throws {
        let pasteboard = NSPasteboard(name: .find)
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(needle, forType: .string)
        addTeardownBlock {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        matches(of: needle, in: haystack).count
    }

    // MARK: - A replace reaches the document

    func testReplaceAllPushesTheTextBindingExactlyOnce() throws {
        let editor = try makeEditor("old and old and old")
        var changes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: editor.view, queue: nil) { _ in changes += 1 }
        addTeardownBlock { NotificationCenter.default.removeObserver(observer) }

        findBarReplace(matches(of: "old", in: editor.view.string), with: "new", in: editor.view)

        XCTAssertEqual(editor.view.string, "new and new and new")
        // The binding is what marks the document dirty and starts autosave;
        // a replace that never reached it would be lost on close.
        XCTAssertEqual(editor.box.text, "new and new and new")
        XCTAssertEqual(changes, 1, "a whole Replace All is one change, not one per match")
    }

    func testASingleReplacePushesTheTextBinding() throws {
        let editor = try makeEditor("old and old")
        findBarReplace([NSRange(location: 0, length: 3)], with: "new", in: editor.view)
        XCTAssertEqual(editor.box.text, "new and old")
    }

    /// The match rule is the one `TextSearch.cs` defines for every md
    /// edition: case-insensitive, so Replace All replaces `Old` and `OLD`
    /// too — and the replacement goes in exactly as typed.
    func testReplaceAllIsCaseInsensitiveAndReplacesLiterally() throws {
        let editor = try makeEditor("old Old OLD older")
        findBarReplace(matches(of: "old", in: editor.view.string), with: "new", in: editor.view)
        XCTAssertEqual(editor.box.text, "new new new newer")
    }

    // MARK: - Undo

    /// Replace All is one undo step. `SmartTextView` deliberately splits
    /// the undo group in two when *it* capitalizes a letter (§3.5); a
    /// replace must not go anywhere near that path, or ⌘Z would take the
    /// matches back one at a time.
    func testReplaceAllIsOneUndoStep() throws {
        let undo = UndoManager()
        undo.groupsByEvent = false        // the test plays the event loop
        let editor = try makeEditor("old and old and old", undoOverride: undo)

        undo.beginUndoGrouping()
        findBarReplace(matches(of: "old", in: editor.view.string), with: "new", in: editor.view)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }

        XCTAssertEqual(editor.view.string, "new and new and new")
        XCTAssertEqual(editor.box.text, "new and new and new")
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(editor.view.string, "old and old and old")
        XCTAssertFalse(undo.canUndo, "the replace left more than one step behind")
        // The binding is deliberately not asserted here: `NSTextView` posts
        // no text-change notification when it *undoes* an edit — measured,
        // and the same for typing and for a paste as for a replace — so the
        // undo half of the binding is nothing a replace changes either way.
    }

    /// The book workspace hands each article its own undo stack
    /// (`MarkdownEditor.undoOverride`) and recreates the editor when the
    /// selection moves. A Replace All in one article must register there
    /// and nowhere else.
    func testAReplaceRegistersOnlyOnTheArticlesOwnUndoStack() throws {
        let first = UndoManager()
        let second = UndoManager()
        first.groupsByEvent = false
        second.groupsByEvent = false

        let articleA = try makeEditor("old text", undoOverride: first)
        first.beginUndoGrouping()
        findBarReplace(matches(of: "old", in: articleA.view.string), with: "new", in: articleA.view)
        while first.groupingLevel > 0 { first.endUndoGrouping() }

        // Moving to the next article: a fresh pane, a fresh stack.
        let articleB = try makeEditor("other text", undoOverride: second)
        XCTAssertTrue(first.canUndo)
        XCTAssertFalse(second.canUndo, "the previous article's replace leaked into this one")

        second.undo()
        XCTAssertEqual(articleB.view.string, "other text", "an empty stack still changed the text")
        first.undo()
        XCTAssertEqual(articleA.view.string, "old text")
    }

    // MARK: - Smart typing sees a replace as an external edit (§3.4)

    /// A replace elsewhere in the document is an ordinary edit: the tracked
    /// capital moves with the text, and the delete-and-retype override
    /// still works on it afterwards.
    func testAReplaceElsewhereMovesTheTrackedCapitalWithTheText() throws {
        let editor = try makeEditor("old and old")
        try withOwnTypingSettings(editor.view)
        let view = editor.view

        // Write ". h" at the end, a character at a time: the `h` opens a
        // sentence, so md capitalizes it and tracks the capital.
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText(".", replacementRange: noRange)
        view.insertText(" ", replacementRange: noRange)
        view.insertText("h", replacementRange: noRange)
        XCTAssertEqual(view.string, "old and old. H")
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 13))

        // Replace All "old" → "x": every match is before the capital and
        // each is two units shorter, so the capital slides back four.
        findBarReplace(matches(of: "old", in: view.string), with: "x", in: view)
        XCTAssertEqual(view.string, "x and x. H")
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 9),
                      "the tracked capital did not follow the replacement")

        // …and md still lets the capital go when the writer retypes it.
        view.setSelectedRange(NSRange(location: 9, length: 1))
        view.insertText("h", replacementRange: noRange)
        XCTAssertEqual(view.string, "x and x. h")
        XCTAssertEqual(editor.box.text, "x and x. h")
    }

    /// A replace that lands *on* the capital is a replacement md did not
    /// make: it stops defending it (§3.4 — an edit that removes the tracked
    /// capital arms the override where it stood).
    func testAReplaceOverTheCapitalLetsItGo() throws {
        let editor = try makeEditor("old and old")
        try withOwnTypingSettings(editor.view)
        let view = editor.view

        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText(".", replacementRange: noRange)
        view.insertText(" ", replacementRange: noRange)
        view.insertText("here", replacementRange: noRange)
        XCTAssertEqual(view.string, "old and old. Here")
        XCTAssertTrue(view.capitalOverride.tracksCapital(at: 13))

        // The writer replaces the word the capital opens.
        findBarReplace([NSRange(location: 13, length: 4)], with: "there", in: view)
        XCTAssertEqual(view.string, "old and old. there")
        XCTAssertFalse(view.capitalOverride.tracksCapital,
                       "md kept tracking a capital it no longer wrote")
        XCTAssertTrue(view.capitalOverride.isArmed(at: 13))
        XCTAssertEqual(editor.box.text, "old and old. there")
    }
}
