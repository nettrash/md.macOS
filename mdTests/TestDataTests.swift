//
//  TestDataTests.swift
//  mdTests
//
//  Fixture-driven tests over the shared TestData corpus (mirrored in the
//  iOS / macOS / Android / VS Code repos). Every fixture must parse and
//  render, and each per-feature file must carry the construct its name
//  promises, so a fixture edit that loses a feature fails here rather than
//  silently weakening the corpus.
//
//  Fifteen of the sixteen fixtures are byte-identical in all four repos, and
//  a difference in one of them is drift to be fixed. `test.md` is the
//  deliberate exception: being the kitchen-sink document, it names the
//  platform it runs on and the command that builds it, so those few lines
//  differ per repo on purpose. Do not unify them.
//

import XCTest
@testable import md

final class TestDataTests: XCTestCase {

    private static let fixtures = [
        "blockquotes", "code", "edge-cases", "headings", "images",
        "inline", "lists", "math", "mermaid", "notes", "outline",
        "page-breaks", "plantuml", "tables", "test", "thematic-breaks",
    ]

    private func load(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: TestDataTests.self)
                .url(forResource: name, withExtension: "md", subdirectory: "TestData"),
            "missing fixture \(name).md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testCorpusIsComplete() {
        let names = Bundle(for: TestDataTests.self)
            .urls(forResourcesWithExtension: "md", subdirectory: "TestData")?
            .map { $0.deletingPathExtension().lastPathComponent }
        XCTAssertEqual(names?.sorted(), Self.fixtures)
    }

    func testEveryFixtureParsesAndRenders() throws {
        for name in Self.fixtures {
            let source = try load(name)
            XCTAssertFalse(MarkdownParser.parse(source).isEmpty,
                           "\(name).md parsed to no blocks")
            let html = MarkdownHTML.document(source, title: name, dark: false)
            XCTAssertTrue(html.contains("<body"), "\(name).md rendered no body")
        }
    }

    func testHeadingsFixtureCoversAllSixLevels() throws {
        let levels = Set(MarkdownParser.parse(try load("headings")).compactMap { block -> Int? in
            if case let .heading(level, _) = block.kind { return level }
            return nil
        })
        XCTAssertTrue(levels.isSuperset(of: [1, 2, 3, 4, 5, 6]))
    }

    func testTablesFixtureParsesTables() throws {
        let tables = MarkdownParser.parse(try load("tables")).filter {
            if case .table = $0.kind { return true }
            return false
        }
        // Three real tables; the delimiter-less pair of lines is not one.
        XCTAssertEqual(tables.count, 3)
    }

    func testListsFixtureCarriesOrderedAndUnordered() throws {
        var sawOrdered = false, sawUnordered = false
        for block in MarkdownParser.parse(try load("lists")) {
            if case let .list(ordered, _) = block.kind {
                if ordered { sawOrdered = true } else { sawUnordered = true }
            }
        }
        XCTAssertTrue(sawOrdered)
        XCTAssertTrue(sawUnordered)
    }

    func testPageBreaksFixtureCarriesBothSpellings() throws {
        let breaks = MarkdownParser.parse(try load("page-breaks")).filter {
            if case .pageBreak = $0.kind { return true }
            return false
        }
        XCTAssertEqual(breaks.count, 2)
    }

    func testNotesFixtureKeepsPrivateNotesOutOfTheHTML() throws {
        let source = try load("notes")
        // Two `note:` comments; the plain comment is not a note.
        XCTAssertEqual(MarkdownParser.notes(source).count, 2)
        let html = MarkdownHTML.document(source, title: "notes", dark: false)
        XCTAssertTrue(html.contains("Visible prose before"))
        XCTAssertFalse(html.contains("private author note"))
        XCTAssertFalse(html.contains("plain comment"))
    }

    func testOutlineFixtureDedupesAndSlugs() throws {
        let outline = MarkdownParser.outline(try load("outline"))
        let slugs = outline.map(\.slug)
        XCTAssertTrue(slugs.contains("section"))
        XCTAssertTrue(slugs.contains("section-1"))
        XCTAssertTrue(slugs.contains("c--f"))
        XCTAssertFalse(outline.contains { $0.text.contains("not a heading") })
        XCTAssertEqual(outline.last?.text, "Setext also counts")
    }

    func testImagesFixtureEmitsImgTags() throws {
        let html = MarkdownHTML.document(try load("images"), title: "images", dark: false)
        XCTAssertTrue(html.contains(
            "<img src=\"https://nettrash.me/favicon.ico\" alt=\"nettrash.me favicon\" title=\"The favicon\">"))
        XCTAssertTrue(html.contains(
            "<a href=\"https://nettrash.me\"><img src=\"https://nettrash.me/favicon.ico\" alt=\"badge\"></a>"))
    }

    func testRichFixturesEmitTheirContainers() throws {
        let math = MarkdownHTML.document(try load("math"), title: "math", dark: false)
        XCTAssertTrue(math.contains("class=\"md-mathi\""))
        XCTAssertTrue(math.contains("class=\"md-mathd\""))
        XCTAssertTrue(math.contains("katex.min.js"))

        let mermaid = MarkdownHTML.document(try load("mermaid"), title: "mermaid", dark: false)
        XCTAssertTrue(mermaid.contains("<pre class=\"mermaid\">"))

        let plantuml = MarkdownHTML.document(try load("plantuml"), title: "plantuml", dark: false)
        XCTAssertTrue(plantuml.contains("<div class=\"plantuml\">"))
    }

    func testExamplesBundleIsCompleteAndRenders() throws {
        // The Examples folder ships in the *app* bundle (the tests are
        // hosted, so Bundle.main is the app). The root files are the
        // File ▸ Examples menu, in name order.
        let bundle = Bundle.main
        let expectedRoots = [
            "01-Welcome", "02-Formatting", "03-Tables", "04-Code",
            "05-Images", "06-Math", "07-Diagrams", "08-Plots",
            "09-Writer Tools",
        ]
        let roots = bundle.urls(forResourcesWithExtension: "md", subdirectory: "Examples")?
            .map { $0.deletingPathExtension().lastPathComponent }
        XCTAssertEqual(roots?.sorted(), expectedRoots)

        // The example book: every article at its exact place in the tree,
        // since Example Book… copies the folder verbatim.
        let articles = [
            ("Examples/Example Book", "01-Preface"),
            ("Examples/Example Book/02-Getting Started", "01-The Editor"),
            ("Examples/Example Book/02-Getting Started", "02-Saving and Export"),
            ("Examples/Example Book/03-Going Further", "01-Rich Content"),
            ("Examples/Example Book/03-Going Further", "02-Writing a Book"),
        ]
        for (subdirectory, name) in articles {
            XCTAssertNotNil(bundle.url(forResource: name, withExtension: "md",
                                       subdirectory: subdirectory),
                            "missing example article \(subdirectory)/\(name).md")
        }

        // Every bundled example — book articles included — must parse and
        // render, the same bar as the fixture corpus above.
        let root = try XCTUnwrap(bundle.resourceURL?.appendingPathComponent("Examples"))
        let all = try XCTUnwrap(FileManager.default.enumerator(at: root,
                                                               includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "md" }
        // Derived from the two rosters above rather than written out, so that
        // adding an example is one edit and not two — a literal here went
        // stale the moment `08-Plots.md` arrived.
        XCTAssertEqual(all.count, expectedRoots.count + articles.count,
                       "stray or missing .md under Examples")
        for url in all {
            let source = try String(contentsOf: url, encoding: .utf8)
            let name = url.lastPathComponent
            XCTAssertFalse(MarkdownParser.parse(source).isEmpty,
                           "\(name) parsed to no blocks")
            let html = MarkdownHTML.document(source, title: name, dark: false)
            XCTAssertTrue(html.contains("<body"), "\(name) rendered no body")
        }
    }
}
