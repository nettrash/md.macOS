//
//  DocumentExport.swift
//  md
//
//  Created by nettrash on 29/06/2026.
//
//  Print, "share rendered PDF" and "share source" — the document's output
//  paths. The macOS (AppKit) sibling of the iOS export file.
//
//  Rendering goes through an offscreen `WKWebView` rather than printing the
//  text view directly. WebKit honors the full typewriter CSS, including the
//  paper background, in both the PDF and the printed page — the chosen
//  theme (and dark mode's cream-on-carbon ink) survives. The CSS sets
//  `print-color-adjust: exact` so those backgrounds actually render.
//
//  Presentation is imperative against the key window: the macOS share
//  picker (`NSSharingServicePicker`) and the print operation both want a
//  window / view to anchor to, which is fiddly to thread through a SwiftUI
//  `ShareLink` when the artifact (a freshly rendered PDF) has to be
//  produced on demand first.
//
//  Rename / Move To / Duplicate are intentionally absent here: on macOS the
//  app is a real `NSDocument`-backed `DocumentGroup`, so the title-bar
//  proxy menu and the File menu provide those natively and correctly — no
//  in-app reimplementation needed (unlike iOS, where `DocumentGroup` offers
//  no in-editor rename).
//

import AppKit
import WebKit

/// Loads themed HTML into an offscreen web view, then yields a PDF or a
/// print operation once layout has settled. Hold a strong reference for the
/// duration of the operation — the print operation keeps using the web view.
@MainActor
final class WebRenderer: NSObject, WKNavigationDelegate {
    /// A4 at 72 dpi, in points — the page the PDF and print job target.
    static let pageSize = CGSize(width: 595, height: 842)

    private let webView: WKWebView
    // createPDF() captures the web view's current rendering — that rendering
    // only exists once the view is backed by a live window. Park the web view
    // in an off-screen, non-activating panel for the duration of the render.
    private let hostPanel: NSPanel
    private var onReady: ((Result<Void, Error>) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        let wv = WKWebView(frame: CGRect(origin: .zero, size: WebRenderer.pageSize),
                           configuration: configuration)
        webView = wv
        let panel = NSPanel(
            contentRect: NSRect(x: -WebRenderer.pageSize.width - 100, y: 0,
                                width: WebRenderer.pageSize.width,
                                height: WebRenderer.pageSize.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = wv
        panel.orderBack(nil)
        hostPanel = panel
        super.init()
        webView.navigationDelegate = self
    }

    /// Load `html` and resume when the web view reports the load finished.
    func load(html: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            onReady = { continuation.resume(with: $0) }
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func makePDF() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// A print operation that paginates the rendered web content.
    func printOperation(_ info: NSPrintInfo) -> NSPrintOperation {
        webView.printOperation(with: info)
    }

    // WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onReady?(.success(())); onReady = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onReady?(.failure(error)); onReady = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onReady?(.failure(error)); onReady = nil
    }
}

/// The three document output actions, presented against the key window.
@MainActor
enum DocumentExport {

    /// `NSSharingServicePicker` is deallocated as soon as the call that
    /// shows it returns, which would dismiss the popover; keep it alive
    /// until the user is done with it.
    private static var sharePicker: NSSharingServicePicker?

    /// Print the rendered document, themed to match the current appearance.
    static func print(source: String, title: String, dark: Bool) async {
        let html = MarkdownHTML.document(source, title: title, dark: dark)
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false
            info.jobDisposition = .spool
            let operation = renderer.printOperation(info)
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            operation.jobTitle = title
            // `run()` is synchronous: it spins the modal panel and returns
            // only once printing finishes, so `renderer` (and the web view
            // the operation is still reading) stays alive for the whole job.
            // The sheet-based `runModal(for:…)` would return immediately and
            // let the renderer deallocate mid-print.
            operation.run()
        } catch {
            // Rendering failed (malformed HTML is essentially impossible here);
            // nothing actionable to surface to the user.
        }
        withExtendedLifetime(renderer) {}
    }

    /// Render the document to a PDF and offer it through the share picker.
    static func sharePDF(source: String, title: String, dark: Bool) async {
        let html = MarkdownHTML.document(source, title: title, dark: dark)
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            let data = try await renderer.makePDF()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(sanitized(title)).pdf")
            try data.write(to: url, options: .atomic)
            presentShare(items: [url])
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not generate PDF"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        withExtendedLifetime(renderer) {}
    }

    /// Share the raw Markdown source. Shares the real file when it has been
    /// saved (so the filename and location are preserved); otherwise writes
    /// the current text to a temporary `.md` and shares that.
    static func shareSource(fileURL: URL?, text: String, title: String) {
        if let fileURL {
            presentShare(items: [fileURL])
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitized(title)).md")
        try? Data(text.utf8).write(to: url, options: .atomic)
        presentShare(items: [url])
    }

    // MARK: - Presentation

    private static func presentShare(items: [Any]) {
        guard let window = keyWindow(), let anchor = window.contentView else { return }
        let picker = NSSharingServicePicker(items: items)
        sharePicker = picker
        // Anchor near the top-trailing corner of the content view (macOS
        // uses a bottom-left origin, so the top edge is at `maxY`).
        let rect = NSRect(x: anchor.bounds.maxX - 24, y: anchor.bounds.maxY - 8, width: 1, height: 1)
        picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
    }

    private static func keyWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }

    /// Make a string safe to use as a file name.
    private static func sanitized(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Document" : cleaned
    }
}
