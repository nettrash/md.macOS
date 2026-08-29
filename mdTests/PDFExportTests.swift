//
//  PDFExportTests.swift
//  mdTests (macOS)
//
//  Regression tests for the share / export PDF path: every PDF is real A4
//  pages produced by the print pipeline — paginated line-aware by WebKit
//  (no line of text sliced at a fold), honoring the author's `\newpage`
//  markers as page cuts, with nothing lost off the end. Renders through
//  the real `WebRenderer`, i.e. the same WKWebView + asset-scheme pipeline
//  the app's share / export / print actions use.
//
//  macOS-only (WebRenderer parks its web view in an offscreen NSPanel), so
//  it lives outside the parser test file that is shared with iOS.
//

import PDFKit
import XCTest
@testable import md

@MainActor
final class PDFExportTests: XCTestCase {

    private func paragraphs(_ count: Int) -> String {
        (1...count)
            .map { "Paragraph \($0) — enough words that the line has real width on the page." }
            .joined(separator: "\n\n")
    }

    private func pageTexts(of document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    func testPDFPaginatesToRealA4Pages() async throws {
        // A long document must come back as several pages of exactly A4
        // size, with nothing lost off the end.
        let renderer = WebRenderer()
        try await renderer.load(html: MarkdownHTML.document(paragraphs(60), title: "a4", dark: false, export: true))
        let data = try await renderer.makePDF(title: "a4")

        let document = try XCTUnwrap(PDFDocument(data: data), "makePDF should produce a readable PDF")
        XCTAssertGreaterThan(document.pageCount, 1, "A long document must paginate")
        for index in 0..<document.pageCount {
            let bounds = try XCTUnwrap(document.page(at: index)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, WebRenderer.pageSize.width, accuracy: 1,
                           "Every page is A4-wide")
            XCTAssertEqual(bounds.height, WebRenderer.pageSize.height, accuracy: 1,
                           "Every page is A4-tall")
        }
        let text = pageTexts(of: document).joined(separator: "\n")
        XCTAssertTrue(text.contains("Paragraph 1 —"), "The document's start is in the PDF")
        XCTAssertTrue(text.contains("Paragraph 60"),
                      "The very end of the document is in the PDF — nothing clipped")
    }

    func testNewpageCutsThePage() async throws {
        // The author's `\newpage` markers must start new pages: each short
        // section lands on its own A4 page, with neighbours' content
        // nowhere on it.
        let source = """
        AlphaStart body text.

        AlphaEnd.

        \\newpage

        BetaOnly section text.

        \\newpage

        GammaOnly closing text.
        """
        let renderer = WebRenderer()
        try await renderer.load(html: MarkdownHTML.document(source, title: "book", dark: false, export: true))
        let data = try await renderer.makePDF(title: "book")

        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 3, "One page per `\\newpage` section")
        let texts = pageTexts(of: document)
        XCTAssertTrue(texts[0].contains("AlphaEnd"), "Page 1 holds the first section")
        XCTAssertFalse(texts[0].contains("BetaOnly"), "…and nothing from the second")
        XCTAssertTrue(texts[1].contains("BetaOnly"), "Page 2 holds the second section")
        XCTAssertFalse(texts[1].contains("GammaOnly"), "…and nothing from the third")
        XCTAssertTrue(texts[2].contains("GammaOnly"), "Page 3 holds the third section")
        XCTAssertFalse(texts[2].contains("AlphaEnd"), "…and nothing from the first")
    }

    func testLongCodeLinesWrapInExport() async throws {
        // A code line much wider than the page: the preview scrolls it, but
        // paper can't — the export must wrap it, not clip it at the block's
        // edge. The end-of-line marker only survives into the PDF's text if
        // the whole line was actually painted.
        let line = (1...40).map { "token\($0)" }.joined(separator: " ") + " ENDMARKER"
        let source = "Before the code.\n\n```\n\(line)\n```\n\nAfter the code."
        let renderer = WebRenderer()
        try await renderer.load(html: MarkdownHTML.document(source, title: "code", dark: false, export: true))
        let data = try await renderer.makePDF(title: "code")

        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = pageTexts(of: document).joined(separator: "\n")
        XCTAssertTrue(text.contains("ENDMARKER"),
                      "The tail of a long code line must wrap onto the page, not be clipped away")
    }

    func testChosenPageSizeReachesTheRenderedPdfMediaBoxAndA4StaysDefault() async throws {
        // The strongest proof the trim choice flows the whole way through:
        // render a real one-page PDF and read the page's MediaBox back — a
        // plain heading, so the offscreen web view settles at once (no rich
        // engines), and one renderer serves both renders.
        let renderer = WebRenderer()
        try await renderer.load(
            html: MarkdownHTML.document("# Page", title: "Page", dark: false, export: true))

        func mediaBox(_ size: CGSize) async throws -> CGRect {
            let data = try await renderer.makePDF(title: "Page", pageSize: size)
            let pdf = try XCTUnwrap(PDFDocument(data: data))
            return try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        }

        // A chosen 6×9" trim reaches the page rect…
        let sixByNine = try await mediaBox(PageSize.sixByNine.size)
        XCTAssertEqual(sixByNine.width, 432, accuracy: 1)
        XCTAssertEqual(sixByNine.height, 648, accuracy: 1)
        // …and `makePDF`'s default is still real A4 — existing behaviour intact.
        let a4 = try await mediaBox(WebRenderer.a4PageSize)
        XCTAssertEqual(a4.width, 595.2, accuracy: 1)
        XCTAssertEqual(a4.height, 841.8, accuracy: 1)
        withExtendedLifetime(renderer) {}
    }

    func testPlotIsPaintedIntoThePDF() async throws {
        // A ```plot is a vector figure the moment the renderer returns, with no
        // engine to wait on — so the print pipeline paints it like any other
        // markup. Its `<text>` elements are real text, which is why the title and
        // an axis label come back out of the finished PDF: proof the figure was
        // drawn, not merely reserved space for.
        let source = """
        Before the figure.

        ```plot
        x: -10..10
        y: -2..2
        title: PlotTitleMarker
        xlabel: XAxisMarker
        sin(x) * exp(-abs(x)/5)
        ```

        After the figure.
        """
        let renderer = WebRenderer()
        try await renderer.load(html: MarkdownHTML.document(source, title: "plot", dark: false, export: true))
        let data = try await renderer.makePDF(title: "plot")

        let document = try XCTUnwrap(PDFDocument(data: data), "makePDF should produce a readable PDF")
        XCTAssertEqual(document.pageCount, 1, "one short page")
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, WebRenderer.pageSize.width, accuracy: 1)
        let text = pageTexts(of: document).joined(separator: "\n")
        XCTAssertTrue(text.contains("Before the figure"), "the prose above the figure")
        XCTAssertTrue(text.contains("After the figure"), "the prose below it — nothing clipped")
        XCTAssertTrue(text.contains("PlotTitleMarker"),
                      "the figure's own title must be painted, as vector text")
        XCTAssertTrue(text.contains("XAxisMarker"), "and its axis label with it")
    }

    func testEPUBRoundTripsThroughUnzip() async throws {
        // Assemble a small real EPUB (plain articles — no rich content, so
        // no web view) and check it with the system's unzip: an intact
        // archive (-t) and the mimetype read back byte-for-byte (-p) prove
        // the hand-rolled ZIP — headers, CRCs, central directory — is one
        // other tools accept, not just one our own code can write.
        let book = EPUBBook(
            title: "Round Trip",
            articles: [.init(name: "Intro", markdown: "# Intro\n\nHello *there*.")],
            chapters: [.init(name: "One",
                             articles: [.init(name: "First", markdown: "Body text.")])])
        let data = try await EPUBExport.build(book: book)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-epub-test-\(UUID().uuidString).epub")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let integrity = Process()
        integrity.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        integrity.arguments = ["-t", url.path]
        integrity.standardOutput = Pipe()
        integrity.standardError = Pipe()
        try integrity.run()
        integrity.waitUntilExit()
        XCTAssertEqual(integrity.terminationStatus, 0, "unzip -t must report an intact archive")

        let mimetype = Process()
        mimetype.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        mimetype.arguments = ["-p", url.path, "mimetype"]
        let out = Pipe()
        mimetype.standardOutput = out
        mimetype.standardError = Pipe()
        try mimetype.run()
        let bytes = out.fileHandleForReading.readDataToEndOfFile()
        mimetype.waitUntilExit()
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "application/epub+zip",
                       "The first entry reads back exactly")
    }
}
