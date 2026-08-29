//
//  ViewModeTests.swift
//  mdTests
//
//  The view-mode open rule and the per-file memory behind it (`ViewMode.swift`).
//  Seven cases, mirrored by name in the iOS and Android suites — this behaviour
//  is shared across three apps that must agree about one document, so a
//  divergence has to fail somewhere rather than show up as a file that opens
//  differently on the phone than on the Mac. (The seventh,
//  `navigationNudgeIsTransient`, is the newest: a jump is not a preference.)
//  The book-exemption case is Mac-and-iOS-local — Android carries that flag
//  on its view-model — and is not one of the seven.
//

import XCTest
@testable import md

final class ViewModeTests: XCTestCase {

    /// A defaults store of its own per test, so nothing here can read or
    /// disturb the real app's `md.viewModeMemory`.
    private func makeDefaults() throws -> UserDefaults {
        let name = "md.viewmode.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: The rule

    func testOpenRuleTruthTable() {
        // A known file opens in exactly the mode it was left in, on any
        // width — the author's own choice outranks every default.
        for isWide in [true, false] {
            for remembered in [DocumentView.Mode.edit, .split, .preview] {
                XCTAssertEqual(ViewModeRule.openViewMode(remembered: remembered,
                                                         isEmptyDocument: false,
                                                         hasFileIdentity: true,
                                                         isWide: isWide),
                               remembered,
                               "a remembered \(remembered) must survive isWide=\(isWide)")
                // …including for a document that is empty right now.
                XCTAssertEqual(ViewModeRule.openViewMode(remembered: remembered,
                                                         isEmptyDocument: true,
                                                         hasFileIdentity: true,
                                                         isWide: isWide),
                               remembered)
            }
        }

        // Nothing to read yet: File ▸ New, or a real 0-byte file. Edit,
        // whatever the width.
        for isWide in [true, false] {
            XCTAssertEqual(ViewModeRule.openViewMode(remembered: nil,
                                                     isEmptyDocument: true,
                                                     hasFileIdentity: false,
                                                     isWide: isWide),
                           .edit)
            XCTAssertEqual(ViewModeRule.openViewMode(remembered: nil,
                                                     isEmptyDocument: true,
                                                     hasFileIdentity: true,
                                                     isWide: isWide),
                           .edit)
        }

        // An unknown file with content: Split where Split is on offer — the
        // Mac and the iPad keep the behaviour they have always had, which is
        // the whole point of the rule taking a width — and Preview only where
        // it is not, i.e. a phone, where reading is the common case and the
        // only thing that fits.
        XCTAssertEqual(ViewModeRule.openViewMode(remembered: nil,
                                                 isEmptyDocument: false,
                                                 hasFileIdentity: true,
                                                 isWide: true),
                       .split)
        XCTAssertEqual(ViewModeRule.openViewMode(remembered: nil,
                                                 isEmptyDocument: false,
                                                 hasFileIdentity: true,
                                                 isWide: false),
                       .preview)
        // `hasFileIdentity` never changes the answer — it governs whether the
        // caller stores it. An example opened from the File menu (content, no
        // file yet) opens like the document it is.
        XCTAssertEqual(ViewModeRule.openViewMode(remembered: nil,
                                                 isEmptyDocument: false,
                                                 hasFileIdentity: false,
                                                 isWide: true),
                       .split)
        XCTAssertEqual(ViewModeRule.openViewMode(remembered: nil,
                                                 isEmptyDocument: false,
                                                 hasFileIdentity: false,
                                                 isWide: false),
                       .preview)
    }

    func testRememberedSplitSurvivesANarrowOpen() throws {
        // The trap this whole feature can fall into: opening a file whose
        // remembered mode is Split on a window too narrow to show Split must
        // *display* Edit while leaving the stored preference saying Split, so
        // the Mac (and the same phone, rotated) still gets Split back.
        let defaults = try makeDefaults()
        let identity = ViewModeMemory.identity(for: URL(fileURLWithPath: "/private/tmp/split.md"))
        ViewModeMemory.remember(.split, for: identity, defaults: defaults)

        let remembered = try XCTUnwrap(ViewModeMemory.lookup(identity, defaults: defaults))
        let opened = ViewModeRule.openViewMode(remembered: remembered,
                                               isEmptyDocument: false,
                                               hasFileIdentity: true,
                                               isWide: false)
        XCTAssertEqual(opened, .split, "the raw mode must come back raw")
        XCTAssertEqual(ViewModeRule.effectiveMode(opened, isWide: false), .edit,
                       "…and only the display is coerced")

        // Storing what the narrow window opened with must not have downgraded
        // the memory — this is the assignment that would destroy it.
        ViewModeMemory.remember(opened, for: identity, defaults: defaults)
        XCTAssertEqual(ViewModeMemory.lookup(identity, defaults: defaults), .split)
        XCTAssertEqual(ViewModeRule.effectiveMode(opened, isWide: true), .split)
    }

    // MARK: Tokens

    func testModeTokensAreTheThreeLiterals() {
        // These three strings are on disk in three apps; they are written out
        // longhand precisely so a rename of the enum cannot change them.
        XCTAssertEqual(ViewModeMemory.token(for: .edit), "edit")
        XCTAssertEqual(ViewModeMemory.token(for: .split), "split")
        XCTAssertEqual(ViewModeMemory.token(for: .preview), "preview")

        for mode in DocumentView.Mode.allCases {
            let token = ViewModeMemory.token(for: mode)
            XCTAssertEqual(ViewModeMemory.mode(forToken: token), mode)
            XCTAssertEqual(ViewModeMemory.mode(forToken: token.uppercased()), mode)
            XCTAssertEqual(ViewModeMemory.mode(forToken: token.capitalized), mode)
        }

        // Whitespace is forgiven, exactly as the Android port's
        // `modeFromToken` forgives it.
        XCTAssertEqual(ViewModeMemory.mode(forToken: "  Split "), .split)
        // A token that names nothing is nil, never fatal.
        XCTAssertNil(ViewModeMemory.mode(forToken: ""))
        XCTAssertNil(ViewModeMemory.mode(forToken: "zen"))
        XCTAssertNil(ViewModeMemory.mode(forToken: "reader"))
    }

    // MARK: Codec

    func testCodecRoundTripsAndRejectsAForeignHeader() {
        let entries = [
            ViewModeMemory.Entry(identity: "53ba23f60734adf1", mode: .preview),
            ViewModeMemory.Entry(identity: "427542472354b900", mode: .split),
            ViewModeMemory.Entry(identity: "0123456789abcdef", mode: .edit),
        ]
        let encoded = ViewModeMemory.encode(entries)
        XCTAssertEqual(encoded, """
            v1
            53ba23f60734adf1 preview
            427542472354b900 split
            0123456789abcdef edit
            """)
        XCTAssertEqual(ViewModeMemory.decode(encoded), entries)
        // An empty memory is still a well-formed one.
        XCTAssertEqual(ViewModeMemory.encode([]), "v1")
        XCTAssertEqual(ViewModeMemory.decode("v1"), [])

        // Line 0 must read exactly `v1`, or the value is treated as absent —
        // that is how a future format retires this one without reading it.
        XCTAssertEqual(ViewModeMemory.decode(""), [])
        XCTAssertEqual(ViewModeMemory.decode("v2\n53ba23f60734adf1 edit"), [])
        XCTAssertEqual(ViewModeMemory.decode(" v1\n53ba23f60734adf1 edit"), [])
        XCTAssertEqual(ViewModeMemory.decode("53ba23f60734adf1 edit"), [])
        XCTAssertEqual(ViewModeMemory.decode("{\"53ba23f60734adf1\":\"edit\"}"), [])

        // A malformed line is skipped, never fatal — the rest still loads —
        // and a repeated identity keeps only its newest (first) row.
        let survivor = ViewModeMemory.Entry(identity: "53ba23f60734adf1", mode: .edit)
        XCTAssertEqual(ViewModeMemory.decode("""
            v1
            not-hex-at-all edit
            53ba23f60734adf1extra edit
            53BA23F60734ADF1 edit
            427542472354b900 zen
            427542472354b900
            427542472354b900 edit split

            53ba23f60734adf1 edit
            53ba23f60734adf1 preview
            """),
            [survivor])

        // The mode is parsed BEFORE the identity is marked seen. This value
        // — the exact one the Android suite pins — decoded to nothing while
        // the order was the other way round: the unreadable `zen` line took
        // the file's only slot and hid the good `split` line under it.
        XCTAssertEqual(
            ViewModeMemory.decode("v1\n53ba23f60734adf1 zen\n53ba23f60734adf1 split"),
            [ViewModeMemory.Entry(identity: "53ba23f60734adf1", mode: .split)],
            "a bad token must skip its line, not its file")
    }

    // MARK: MRU

    func testTouchedIsMruAndTruncatesAtTwoHundred() throws {
        let a = "aaaaaaaaaaaaaaaa", b = "bbbbbbbbbbbbbbbb", c = "cccccccccccccccc"
        var list = [ViewModeMemory.Entry]()
        list = ViewModeMemory.touched(list, identity: a, mode: .edit)
        list = ViewModeMemory.touched(list, identity: b, mode: .split)
        list = ViewModeMemory.touched(list, identity: c, mode: .preview)
        XCTAssertEqual(list.map(\.identity), [c, b, a], "newest first")

        // Touching a file already in the list moves it to the front and
        // updates its mode — it never grows a duplicate.
        list = ViewModeMemory.touched(list, identity: a, mode: .preview)
        XCTAssertEqual(list.map(\.identity), [a, c, b])
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list.first?.mode, .preview)

        // The cap: exactly 200 entries survive, and it is the oldest that
        // falls off.
        var big = [ViewModeMemory.Entry]()
        for index in 0..<ViewModeMemory.maxEntries {
            big = ViewModeMemory.touched(big, identity: identity(index), mode: .edit)
        }
        XCTAssertEqual(big.count, ViewModeMemory.maxEntries)
        XCTAssertEqual(big.last?.identity, identity(0))

        big = ViewModeMemory.touched(big, identity: identity(ViewModeMemory.maxEntries), mode: .split)
        XCTAssertEqual(big.count, ViewModeMemory.maxEntries, "still exactly 200")
        XCTAssertEqual(big.first?.identity, identity(ViewModeMemory.maxEntries))
        XCTAssertEqual(big.last?.identity, identity(1), "the oldest is what goes")
        XCTAssertNil(big.first(where: { $0.identity == identity(0) }))

        // …and the same through the real store, round-tripped as text.
        let defaults = try makeDefaults()
        for index in 0...ViewModeMemory.maxEntries {
            ViewModeMemory.remember(.edit, for: identity(index), defaults: defaults)
        }
        XCTAssertEqual(ViewModeMemory.entries(defaults: defaults).count, ViewModeMemory.maxEntries)
        XCTAssertNil(ViewModeMemory.lookup(identity(0), defaults: defaults))
        XCTAssertEqual(ViewModeMemory.lookup(identity(ViewModeMemory.maxEntries), defaults: defaults), .edit)
        // An unknown file stays unknown — that is what makes the open rule's
        // first branch reachable at all.
        XCTAssertNil(ViewModeMemory.lookup("ffffffffffffffff", defaults: defaults))
    }

    /// A distinct, well-formed 16-hex identity per index.
    private func identity(_ index: Int) -> String {
        String(format: "%016x", index)
    }

    // MARK: The book exemption

    @MainActor
    func testBookArticleMarkIsClaimedExactlyOnce() {
        // Book articles are exempt from the per-file memory on all three
        // ports — including the Mac's own-window path, where the navigator
        // opens an article as an ordinary document window. The window that
        // lands on the file claims the mark; a second claim, i.e. the reader
        // opening the same file from the Finder later, is an ordinary open.
        let article = URL(fileURLWithPath: "/private/tmp/md-book-\(UUID().uuidString)/ch1.md")
        let plain = URL(fileURLWithPath: "/private/tmp/md-plain-\(UUID().uuidString)/notes.md")

        XCTAssertFalse(BookArticleOpens.claimOpen(article), "nothing marked yet")

        BookArticleOpens.mark(article)
        XCTAssertFalse(BookArticleOpens.claimOpen(plain),
                       "a mark belongs to one file, not to the next open")
        XCTAssertTrue(BookArticleOpens.claimOpen(article))
        XCTAssertFalse(BookArticleOpens.claimOpen(article),
                       "the mark is consumed: opening it again is an ordinary open")
    }

    // MARK: Navigation nudges

    /// A jump is not a preference. Mirrors the iOS suite's case of the same
    /// name (and Android's `navigationNudgeIsTransient`), because the bug it
    /// pins shut was the same shape on all three: a file its author keeps in
    /// Preview, one trip through Go ▸ Notes, and the file's remembered mode
    /// was Edit from then on — forever, because the jump went through the
    /// persisting setter. Reading is not choosing.
    ///
    /// The model below is `DocumentView`'s state written out longhand:
    /// `preferred` is the `@SceneStorage` mode (what `setMode` writes and
    /// what the memory stores), `navigation` is the `@State` nudge, and
    /// `displayed()` is `effectiveMode`. Keeping the two apart here is the
    /// point of the case — the store has to be provably untouched by a jump.
    func testNavigationNudgeIsTransient() throws {
        // The rule itself: nudge only when the destination's pane is off
        // screen. Split shows both, so it never nudges — and the question is
        // always asked of the *displayed* mode.
        XCTAssertEqual(ViewModeRule.navigationNudge(displayed: .preview, wants: .edit), .edit)
        XCTAssertEqual(ViewModeRule.navigationNudge(displayed: .edit, wants: .preview), .preview)
        XCTAssertNil(ViewModeRule.navigationNudge(displayed: .edit, wants: .edit))
        XCTAssertNil(ViewModeRule.navigationNudge(displayed: .preview, wants: .preview))
        XCTAssertNil(ViewModeRule.navigationNudge(displayed: .split, wants: .edit))
        XCTAssertNil(ViewModeRule.navigationNudge(displayed: .split, wants: .preview))

        let defaults = try makeDefaults()
        let file = ViewModeMemory.identity(for: URL(fileURLWithPath: "/private/tmp/notes.md"))

        // A file the reader keeps in Preview, opened in a Mac window — which
        // is always wide, so nothing here is ever coerced.
        ViewModeMemory.remember(.preview, for: file, defaults: defaults)
        var preferred = ViewModeRule.openViewMode(
            remembered: ViewModeMemory.lookup(file, defaults: defaults),
            isEmptyDocument: false,
            hasFileIdentity: true,
            isWide: true)
        var navigation: DocumentView.Mode?
        func displayed() -> DocumentView.Mode {
            ViewModeRule.displayedMode(preferred: preferred, navigation: navigation, isWide: true)
        }
        XCTAssertEqual(displayed(), .preview)

        // They open the Go ▸ Notes menu and pick a note — `jump(to note:)`.
        if let nudge = ViewModeRule.navigationNudge(displayed: displayed(), wants: .edit) {
            navigation = nudge
        }
        XCTAssertEqual(displayed(), .edit, "the note has to be visible to be read")
        XCTAssertEqual(ViewModeMemory.lookup(file, defaults: defaults), .preview,
                       "reading a note is not a preference: the store is untouched")

        // A second note: the window is already nudged, so nothing changes —
        // in particular the override is not cleared out from under them,
        // which is why the view assigns only a non-nil nudge.
        if let nudge = ViewModeRule.navigationNudge(displayed: displayed(), wants: .edit) {
            navigation = nudge
        }
        XCTAssertEqual(displayed(), .edit)
        XCTAssertEqual(ViewModeMemory.lookup(file, defaults: defaults), .preview)

        // Now a deliberate pick — View ▸ Split, ⌘2, i.e. `setMode(.split)`:
        // the nudge goes and the raw choice is what is persisted.
        navigation = nil
        preferred = .split
        ViewModeMemory.remember(preferred, for: file, defaults: defaults)
        XCTAssertNil(navigation, "a deliberate pick clears the nudge")
        XCTAssertEqual(ViewModeMemory.lookup(file, defaults: defaults), .split)
        XCTAssertEqual(displayed(), .split, "…and the Mac, always wide, shows it")

        // The Android half of the same bug, and the reason the nudge asks
        // the displayed mode rather than the raw one. A Mac never coerces,
        // so the width that makes this bite is the phone's: a file
        // remembered as Split renders as Edit there, so a jump into the
        // preview still has a pane to bring on screen — and Split survives
        // in the store, where at that width it could never be re-picked.
        XCTAssertEqual(ViewModeRule.displayedMode(preferred: .split, navigation: nil, isWide: false),
                       .edit)
        XCTAssertEqual(ViewModeRule.navigationNudge(displayed: .edit, wants: .preview), .preview)
        XCTAssertEqual(ViewModeRule.displayedMode(preferred: .split, navigation: .preview, isWide: false),
                       .preview)
        XCTAssertEqual(ViewModeMemory.lookup(file, defaults: defaults), .split)

        // Opening another document drops the override
        // (`applyViewModeMemory`) — and the Save-As migration deliberately
        // does not, since that is the same document one ⌘S later.
        navigation = .edit
        XCTAssertEqual(displayed(), .edit)
        navigation = nil
        XCTAssertEqual(displayed(), .split)
    }

    // MARK: Identity

    func testIdentityMatchesTheSharedShaVectors() throws {
        // The two vectors from the spec. They are what catches a
        // UTF-16-for-UTF-8 slip between the ports: both are pure ASCII, so
        // they would still agree byte for byte — which is exactly why the
        // hash is pinned here as well as being described in prose.
        XCTAssertEqual(ViewModeMemory.sha256Prefix("file:/tmp/a.md"), "53ba23f60734adf1")
        XCTAssertEqual(
            ViewModeMemory.sha256Prefix("saf:com.android.externalstorage.documents:primary:Documents/a.md"),
            "427542472354b900")
        // Non-ASCII is where the encodings actually part company, so pin one.
        XCTAssertEqual(ViewModeMemory.sha256Prefix("file:/tmp/é.md").count, 16)
        XCTAssertNotEqual(ViewModeMemory.sha256Prefix("file:/tmp/é.md"),
                          ViewModeMemory.sha256Prefix("file:/tmp/e.md"))

        // `identity(for:)` is that hash over "file:" + the resolved path…
        XCTAssertTrue(ViewModeMemory.isIdentity(
            ViewModeMemory.identity(for: URL(fileURLWithPath: "/private/tmp/a.md"))))
        XCTAssertNotEqual(ViewModeMemory.identity(for: URL(fileURLWithPath: "/private/tmp/a.md")),
                          ViewModeMemory.identity(for: URL(fileURLWithPath: "/private/tmp/b.md")))

        // …and the symlink resolution is load-bearing, not cosmetic: the
        // system hands the same document over under two paths, and without it
        // one file would occupy two entries that disagree.
        //
        // The document has to actually exist for this to work — measured:
        // `resolvingSymlinksInPath()` resolves an intermediate symlink only
        // when the whole path resolves to something on disk, and returns a
        // path with a missing leaf untouched. That is fine here (a document
        // being opened is by definition on disk) but it is why this fixture
        // writes the file instead of just naming it.
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
        let real = base.appendingPathComponent("md-viewmode-\(UUID().uuidString)", isDirectory: true)
        let link = base.appendingPathComponent("md-viewmode-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "# a\n".write(to: real.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: real)
        }
        XCTAssertEqual(ViewModeMemory.identity(for: real.appendingPathComponent("a.md")),
                       ViewModeMemory.identity(for: link.appendingPathComponent("a.md")))

        // And it is a well-formed identity by the decoder's own standard, so
        // anything `identity(for:)` produces survives a codec round trip.
        let produced = ViewModeMemory.identity(for: real.appendingPathComponent("a.md"))
        XCTAssertTrue(ViewModeMemory.isIdentity(produced))
        XCTAssertEqual(
            ViewModeMemory.decode(ViewModeMemory.encode([.init(identity: produced, mode: .split)])),
            [.init(identity: produced, mode: .split)])
    }
}
