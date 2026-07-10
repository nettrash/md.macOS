//
//  PDFExportTests.swift
//  mdTests (macOS)
//
//  Regression tests for the share / export PDF path: the whole document must
//  come back as ONE PDF page — not sliced into A4 pages (which cut a line of
//  text at every boundary), and not clipped at the PDF format's 14,400 pt
//  page cap (which cut everything past ~17 A4 pages of content; content
//  taller than the cap is scaled down uniformly instead). Renders through
//  the real `WebRenderer`, i.e. the same WKWebView + asset-scheme pipeline
//  the app's share / export actions use.
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

    func testPDFIsOneContentTallPage() async throws {
        // ~200 paragraphs — dozens of A4 pages if the capture paginated,
        // and far more than one A4 page if it clipped at the view bounds.
        let renderer = WebRenderer()
        try await renderer.load(html: MarkdownHTML.document(paragraphs(200), title: "long", dark: false, export: true))
        let data = try await renderer.makePDF()

        let document = try XCTUnwrap(PDFDocument(data: data), "makePDF should produce a readable PDF")
        XCTAssertEqual(document.pageCount, 1, "The shared / exported PDF must be a single continuous page")

        let page = try XCTUnwrap(document.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, WebRenderer.pageSize.width, accuracy: 1,
                       "Under the 14,400 pt cap the page keeps the A4 width the document is laid out at")
        XCTAssertGreaterThan(bounds.height, WebRenderer.pageSize.height * 2,
                             "The page must grow with the content, not clip at A4 height")

        let text = page.string ?? ""
        XCTAssertTrue(text.contains("Paragraph 200"),
                      "The very end of the document is on the page — nothing clipped")
    }

    func testVeryLongDocumentScalesToOneLegalPage() async throws {
        // ~700 paragraphs render far taller than the PDF format's 14,400 pt
        // page cap. CoreGraphics clips any page beyond the cap (this cut real
        // documents), so the capture must shrink the rendering uniformly to
        // ONE legal page instead — same layout, smaller scale, nothing lost.
        let renderer = WebRenderer()
        try await renderer.load(html: MarkdownHTML.document(paragraphs(700), title: "huge", dark: false, export: true))
        let data = try await renderer.makePDF()

        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 1, "Still a single page, never paginated or split")

        let page = try XCTUnwrap(document.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.height, WebRenderer.maxPageDimension, accuracy: 1,
                       "Oversize content lands exactly on the 14,400 pt cap")
        XCTAssertLessThan(bounds.width, WebRenderer.pageSize.width,
                          "The width shrinks by the same factor — a uniform scale, not a re-wrap")

        let text = page.string ?? ""
        XCTAssertTrue(text.contains("Paragraph 1 —"), "The top of the document is on the page")
        XCTAssertTrue(text.contains("Paragraph 700"),
                      "The very end of the document is on the page — nothing clipped at the cap")
    }

    func testNewpageSplitsExportIntoContentTallPages() async throws {
        // The author's `\newpage` markers split the export into one page per
        // section — each page content-tall and complete, with neighbours'
        // content nowhere on it.
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
        let data = try await renderer.makePDF()

        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 3, "One page per `\\newpage` section")
        let texts = (0..<3).map { document.page(at: $0)?.string ?? "" }
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
        let data = try await renderer.makePDF()

        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = try XCTUnwrap(document.page(at: 0)).string ?? ""
        XCTAssertTrue(text.contains("ENDMARKER"),
                      "The tail of a long code line must wrap onto the page, not be clipped away")
    }

    func testA4LayoutPaginatesToRealA4Pages() async throws {
        // The opt-in A4 layout (the PDF Layout setting) goes through the
        // print pipeline instead: a long document must come back as several
        // pages of exactly A4 size, with nothing lost off the end.
        let renderer = WebRenderer()
        try await renderer.load(html: MarkdownHTML.document(paragraphs(60), title: "a4", dark: false, export: true))
        let data = try await renderer.makeA4PDF(title: "a4")

        let document = try XCTUnwrap(PDFDocument(data: data), "makeA4PDF should produce a readable PDF")
        XCTAssertGreaterThan(document.pageCount, 1, "A4 layout must paginate a long document")
        for index in 0..<document.pageCount {
            let bounds = try XCTUnwrap(document.page(at: index)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, WebRenderer.pageSize.width, accuracy: 1,
                           "Every page is A4-wide")
            XCTAssertEqual(bounds.height, WebRenderer.pageSize.height, accuracy: 1,
                           "Every page is A4-tall")
        }
        let text = (0..<document.pageCount)
            .map { document.page(at: $0)?.string ?? "" }
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("Paragraph 1 —"), "The document's start is in the PDF")
        XCTAssertTrue(text.contains("Paragraph 60"),
                      "The very end of the document is in the PDF — nothing clipped")
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
