//
//  RichRenderTests.swift
//  mdTests (macOS)
//
//  End-to-end smoke test for the rich preview: loads a document containing
//  LaTeX math, a Mermaid graph, a Graphviz DOT graph and a PlantUML diagram
//  into a real WKWebView through the app's asset scheme handler, waits for
//  md-init.js to finish, and asserts each rendered to an SVG / KaTeX span.
//  This exercises the whole offline pipeline (custom-scheme ES-module loading,
//  KaTeX, Mermaid, Viz.js and the TeaVM PlantUML engine) on the same WebKit
//  that drives the iOS build.
//
//  It then does the same for "Export as HTML…": takes a real export of a
//  rich document and loads it back from `file://` in a second web view with
//  *no* scheme handler registered, so anything still reaching for the
//  bundled `rich/` engines could not possibly resolve. That is the strongest
//  proof of the self-contained export available on any of the three
//  platforms, and this is the only test bundle that can run it.
//
//  macOS-only (parks the web view in an offscreen NSWindow so layout runs),
//  so it lives outside the parser test file that is shared with iOS.
//

import AppKit
import WebKit
import XCTest
@testable import md

@MainActor
final class RichRenderTests: XCTestCase {

    func testMathMermaidGraphvizPlantumlRenderOffline() async throws {
        let source = """
        Inline math $a^2 + b^2 = c^2$ and a display formula:

        $$\\int_0^1 x^2\\,dx = \\frac{1}{3}$$

        ```mermaid
        graph TD
          A[Start] --> B[Done]
        ```

        ```dot
        digraph G {
          a -> b;
          b -> c;
        }
        ```

        ```plantuml
        @startuml
        Alice -> Bob: Authentication Request
        Bob --> Alice: Authentication Response
        @enduml
        ```
        """

        let handler = MdAssetSchemeHandler()
        handler.html = MarkdownHTML.document(source, title: "rich", dark: false)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: MdAssetSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1200), configuration: config)

        // Off-screen host window: WKWebView only lays out (which Mermaid's text
        // measurement and Graphviz need) when it is in a window.
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 800, height: 1200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderBack(nil)
        defer { window.contentView = nil }

        webView.load(URLRequest(url: MdAssetSchemeHandler.indexURL))
        try await waitForRenderComplete(webView, timeout: 40)

        let katex = try await evalCount(webView, "document.querySelectorAll('.katex').length")
        let mermaid = try await evalCount(webView, "document.querySelectorAll('.mermaid svg').length")
        let graphviz = try await evalCount(webView, "document.querySelectorAll('.graphviz svg').length")
        let plantuml = try await evalCount(webView, "document.querySelectorAll('.plantuml svg').length")

        XCTAssertGreaterThanOrEqual(katex, 1, "KaTeX should render at least the inline + display math")
        XCTAssertGreaterThanOrEqual(mermaid, 1, "Mermaid should render an SVG")
        // Viz.js is the engine PlantUML already carried; a ```dot fence now
        // reaches it directly, so the DOT graph must become an SVG of its own.
        XCTAssertGreaterThanOrEqual(graphviz, 1, "Graphviz should render an SVG")
        XCTAssertGreaterThanOrEqual(plantuml, 1, "PlantUML should render an SVG")
    }

    // MARK: mhchem — `\ce{}` chemistry rides the existing KaTeX pipeline

    /// Proof that mhchem actually loaded and matches the bundled KaTeX. With
    /// mhchem present `\ce{}` / `\pu{}` are defined macros, so KaTeX typesets
    /// them cleanly; were the file missing or version-mismatched, `\ce` would be
    /// an undefined control sequence and KaTeX (throwOnError:false) would leave a
    /// `.katex-error` node — so "a `.katex`, and no `.katex-error`" is the
    /// difference between a working extension and a silent no-op.
    func testMhchemRendersChemistryInWebView() async throws {
        let source =
            "A reaction $\\ce{H2SO4 + 2 OH- -> SO4^2- + 2 H2O}$ and units $\\pu{123 kJ/mol}$."
        try await withRenderedWebView(source) { webView in
            let katex = try await evalCount(webView, "document.querySelectorAll('.katex').length")
            let errors = try await evalCount(webView, "document.querySelectorAll('.katex-error').length")
            XCTAssertGreaterThanOrEqual(katex, 1, "the \\ce{} / \\pu{} formulas must typeset via KaTeX")
            XCTAssertEqual(errors, 0, "\\ce{} and \\pu{} must be defined — mhchem loaded and matches KaTeX")
        }
    }

    // MARK: highlight.js — fenced code with a language hint is syntax-highlighted

    /// Proof that a `language-…` fenced block is highlighted in the live DOM:
    /// highlight.js tags the processed element `hljs` and wraps the source in
    /// semantic token spans (`.hljs-keyword`, `.hljs-string`, `.hljs-comment`)
    /// that the hand-written theme in `MarkdownHTML.css` then colours. This is
    /// the reach that the string-level tests can't see, and the same live DOM
    /// feeds preview, print, PDF and HTML export.
    func testSyntaxHighlightingAppliesInWebView() async throws {
        let source = """
        ```swift
        // a greeting
        let greeting = "hello"
        func f() -> Int { return 1 }
        ```
        """
        try await withRenderedWebView(source) { webView in
            let processed = try await evalCount(webView, "document.querySelectorAll('code.hljs').length")
            let tokens = try await evalCount(
                webView,
                "document.querySelectorAll('code.hljs .hljs-keyword, code.hljs .hljs-string, code.hljs .hljs-comment').length")
            XCTAssertGreaterThanOrEqual(processed, 1, "the language-tagged block must be processed by highlight.js")
            XCTAssertGreaterThanOrEqual(tokens, 1, "highlight.js must emit the token spans the theme colours")
        }
    }

    // MARK: HTML export — the exported file, loaded back with no engines

    /// The strongest check the three platforms allow: take a real export of a
    /// rich document, write it to disk, and open it in a *second* web view
    /// with **no scheme handler registered at all** — so anything still
    /// reaching for `mdassets://…/rich/` could not possibly resolve. What
    /// survives there is exactly what a reader gets.
    func testExportedHTMLStandsAloneWithNoEngines() async throws {
        let source = """
        Inline math $a^2 + b^2 = c^2$ and a display formula:

        $$\\int_0^1 x^2\\,dx = \\frac{1}{3}$$

        ```dot
        digraph G { a -> b; }
        ```

        ```mermaid
        graph TD
          A[Start] --> B[Done]
        ```

        | a | b |
        | - | - |
        | 1 | 2 |
        """
        let page = try await DocumentExport.renderedHTMLPage(source: source, title: "rich", dark: false)

        // A doctype has to be there by hand — `outerHTML` omits it, and
        // without one the browser drops into quirks mode.
        XCTAssertTrue(page.hasPrefix("<!DOCTYPE html>\n"))
        // The obligation that travels with the fonts (OFL 1.1, reserved name).
        XCTAssertTrue(page.contains("SIL Open Font"), "the KaTeX font licence notice must ship with the fonts")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-export-\(UUID().uuidString).html")
        try Data(page.utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        // Deliberately a bare configuration: no `mdassets` handler.
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1200),
                                configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 800, height: 1200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderBack(nil)
        defer { window.contentView = nil }

        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        try await waitForLoad(webView, timeout: 30)

        // Standards mode, not quirks — the doctype survived the round trip.
        let compatMode = try await webView.evaluateJavaScript("document.compatMode")
        XCTAssertEqual(compatMode as? String, "CSS1Compat")
        let doctype = try await webView.evaluateJavaScript("document.doctype ? document.doctype.name : ''")
        XCTAssertEqual(doctype as? String, "html")

        // Nothing left to run and nothing left to fetch.
        let scripts = try await evalCount(webView, "document.querySelectorAll('script').length")
        let links = try await evalCount(webView, "document.querySelectorAll('link').length")
        let richRefs = try await evalCount(
            webView, "document.documentElement.outerHTML.split('rich/').length - 1")
        XCTAssertEqual(scripts, 0)
        XCTAssertEqual(links, 0)
        XCTAssertEqual(richRefs, 0, "no reference to the bundled engine folder may survive the export")

        // …and the content is all still there, baked in.
        let svgs = try await evalCount(webView, "document.querySelectorAll('svg').length")
        let katex = try await evalCount(webView, "document.querySelectorAll('.katex').length")
        let tables = try await evalCount(webView, "document.querySelectorAll('table').length")
        XCTAssertGreaterThanOrEqual(svgs, 2, "the DOT and Mermaid diagrams must survive as inline SVG")
        XCTAssertGreaterThanOrEqual(katex, 2, "both formulas must survive as expanded KaTeX markup")
        XCTAssertEqual(tables, 1)

        // The embedded stylesheet is doing its job: KaTeX's own face is what
        // the formula computes to, from the inlined `@font-face` rules alone.
        let font = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('.katex .mord') || document.querySelector('.katex'))"
            + ".fontFamily")
        let family = (font as? String) ?? ""
        XCTAssertTrue(family.contains("KaTeX"), "expected a KaTeX face, got “\(family)”")
    }

    func testExportedHTMLOfAPlainDocumentCarriesNoFontPayload() async throws {
        // The ~300 KB of woff2 rides along only when the document has math.
        let plain = try await DocumentExport.renderedHTMLPage(
            source: "# Title\n\nJust prose, no formulas.\n", title: "plain", dark: false)
        XCTAssertFalse(plain.contains("data:font/woff2"), "a document without math must not carry the fonts")
        XCTAssertFalse(plain.contains("rich/"))
        XCTAssertFalse(plain.contains("<script"))
        XCTAssertTrue(plain.contains("Just prose"))
        XCTAssertLessThan(plain.utf8.count, 100_000, "a plain export should be a few KB, not a few hundred")
    }

    // MARK: helpers

    private func waitForLoad(_ webView: WKWebView, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !webView.isLoading {
                let state = try? await webView.evaluateJavaScript("document.readyState")
                if (state as? String) == "complete" { return }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("The exported file did not finish loading within \(Int(timeout))s")
    }

    /// Render `source` through the app's asset scheme handler in an off-screen
    /// WKWebView, wait for md-init.js to flag completion, then run `body` while
    /// the hosting window is still alive. Mirrors the setup of the first test;
    /// factored out so the mhchem and highlight.js cases don't each repeat it.
    private func withRenderedWebView(_ source: String,
                                     timeout: TimeInterval = 40,
                                     _ body: (WKWebView) async throws -> Void) async throws {
        let handler = MdAssetSchemeHandler()
        handler.html = MarkdownHTML.document(source, title: "rich", dark: false)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: MdAssetSchemeHandler.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1200), configuration: config)

        // Off-screen host window: WKWebView only lays out when it is in a window.
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 800, height: 1200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderBack(nil)
        defer { window.contentView = nil }

        webView.load(URLRequest(url: MdAssetSchemeHandler.indexURL))
        try await waitForRenderComplete(webView, timeout: timeout)
        try await body(webView)
    }

    private func waitForRenderComplete(_ webView: WKWebView, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = try? await webView.evaluateJavaScript(
                "document.documentElement.getAttribute('data-md-render-complete')")
            if (value as? String) == "1" { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("Rich rendering did not complete within \(Int(timeout))s")
    }

    private func evalCount(_ webView: WKWebView, _ js: String) async throws -> Int {
        let value = try await webView.evaluateJavaScript(js)
        return (value as? Int) ?? (value as? NSNumber)?.intValue ?? 0
    }
}
