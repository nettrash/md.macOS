//
//  RichRenderTests.swift
//  mdTests (macOS)
//
//  End-to-end smoke test for the rich preview: loads a document containing
//  LaTeX math, a Mermaid graph and a PlantUML diagram into a real WKWebView
//  through the app's asset scheme handler, waits for md-init.js to finish,
//  and asserts each rendered to an SVG / KaTeX span. This exercises the whole
//  offline pipeline (custom-scheme ES-module loading, KaTeX, Mermaid, and the
//  TeaVM PlantUML engine) on the same WebKit that drives the iOS build.
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

    func testMathMermaidPlantumlRenderOffline() async throws {
        let source = """
        Inline math $a^2 + b^2 = c^2$ and a display formula:

        $$\\int_0^1 x^2\\,dx = \\frac{1}{3}$$

        ```mermaid
        graph TD
          A[Start] --> B[Done]
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
        let plantuml = try await evalCount(webView, "document.querySelectorAll('.plantuml svg').length")

        XCTAssertGreaterThanOrEqual(katex, 1, "KaTeX should render at least the inline + display math")
        XCTAssertGreaterThanOrEqual(mermaid, 1, "Mermaid should render an SVG")
        XCTAssertGreaterThanOrEqual(plantuml, 1, "PlantUML should render an SVG")
    }

    // MARK: helpers

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
