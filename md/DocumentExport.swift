//
//  DocumentExport.swift
//  md
//
//  Created by nettrash on 29/06/2026.
//
//  Print, "share rendered PDF", "export as PDF" and "share source" — the
//  document's output paths. The macOS (AppKit) sibling of the iOS export file.
//
//  Rendering goes through an offscreen `WKWebView` rather than printing the
//  text view directly. WebKit honors the full typewriter CSS, including the
//  paper background, in both the PDF and the printed page — the chosen
//  theme (and dark mode's cream-on-carbon ink) survives. The CSS sets
//  `print-color-adjust: exact` so those backgrounds actually render.
//
//  Shared / exported PDFs honor the app-wide PDF Layout setting (see
//  `PDFLayout`): content-tall pages by default, or real A4 pages produced
//  by pointing the same print pipeline at a PDF file.
//
//  A book can also leave as an EPUB 3 (see `EPUBExport` at the bottom):
//  one XHTML file per title page / chapter heading / article, a nav TOC,
//  and the rich content photographed into PNGs by the same offscreen
//  web view — packed into a hand-rolled stored-only ZIP container.
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
import PDFKit
import UniformTypeIdentifiers
import WebKit

/// The per-section PDFs failed to assemble into one document.
private struct PDFAssemblyError: LocalizedError {
    var errorDescription: String? { "The PDF pages could not be assembled." }
}

/// The print-pipeline A4 pagination did not produce a PDF.
private struct PDFPaginationError: LocalizedError {
    var errorDescription: String? { "The A4 pages could not be produced." }
}

/// A rich-content element could not be photographed for the EPUB.
private struct SnapshotError: LocalizedError {
    var errorDescription: String? { "The rich-content images could not be captured." }
}

/// Bridges `NSPrintOperation.runModal`'s selector-based completion to a
/// closure. The operation does not retain its delegate, so the instance
/// keeps itself alive through `contextInfo` until the callback releases it.
private final class PrintCompletion: NSObject {
    private let done: (Bool) -> Void
    init(_ done: @escaping (Bool) -> Void) { self.done = done }

    @objc func printOperationDidRun(_ printOperation: NSPrintOperation,
                                    success: Bool,
                                    contextInfo: UnsafeMutableRawPointer?) {
        if let contextInfo { Unmanaged<PrintCompletion>.fromOpaque(contextInfo).release() }
        done(success)
    }
}

/// How shared / exported PDFs are laid out — the app-wide "PDF Layout"
/// setting (in the File menu and the share toolbar menu, stored once for
/// the whole app): content-tall pages with no line sliced by a cut (the
/// default, `WebRenderer.makePDF`), or real A4 pages paginated by the
/// print pipeline (`WebRenderer.makeA4PDF`).
enum PDFLayout: String, CaseIterable, Identifiable {
    case single, a4
    var id: String { rawValue }

    /// The UserDefaults key; the pickers observe it via `@AppStorage`.
    static let storageKey = "md.pdfLayout"

    var label: String {
        switch self {
        case .single: return "One long page"
        case .a4: return "A4 pages"
        }
    }

    /// The stored preference, read by the export paths at render time.
    static var current: PDFLayout {
        PDFLayout(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .single
    }
}

/// Loads themed HTML into an offscreen web view, then yields a PDF or a
/// print operation once layout has settled. Hold a strong reference for the
/// duration of the operation — the print operation keeps using the web view.
@MainActor
final class WebRenderer: NSObject, WKNavigationDelegate {
    /// A4 at 72 dpi, in points. The print job paginates to this page; the
    /// shared / exported PDF keeps this width but grows into a single page
    /// as tall as the content (see `makePDF`).
    static let pageSize = CGSize(width: 595, height: 842)

    /// The largest page dimension the PDF format allows — 200 inches at
    /// 72 dpi. CoreGraphics clips any page beyond this, so a document that
    /// renders taller is scaled down uniformly to fit (see `makePDF`).
    static let maxPageDimension: CGFloat = 14_400

    private let webView: WKWebView
    private let assets: MdAssetSchemeHandler
    // createPDF() captures the web view's current rendering — that rendering
    // only exists once the view is backed by a live window. Park the web view
    // in an off-screen, non-activating panel for the duration of the render.
    private let hostPanel: NSPanel
    private var onReady: ((Result<Void, Error>) -> Void)?

    override init() {
        let handler = MdAssetSchemeHandler()
        assets = handler
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: MdAssetSchemeHandler.scheme)
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

    /// Load `html` and resume once the rich renderers (math / diagrams) have
    /// finished — signalled by `data-md-render-complete` from md-init.js — so
    /// the captured PDF / print output includes them rather than the raw source.
    /// Served through the asset scheme handler so those bundled engines resolve.
    func load(html: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            onReady = { continuation.resume(with: $0) }
            assets.html = html
            webView.load(URLRequest(url: MdAssetSchemeHandler.indexURL))
        }
    }

    /// Capture the rendered document as **content-tall pages with no line
    /// sliced by a cut**: one page for the whole document, or — when the
    /// author placed `\newpage` markers — one page per section, each still
    /// exactly as tall as its content. (Printing still paginates to real
    /// paper; that's what paper needs.)
    func makePDF() async throws -> Data {
        // Grow the view (via its host panel — the web view is the panel's
        // content view and follows) to the full rendered height before
        // capturing: `createPDF` renders within the view's bounds, and an
        // A4-sized view would clip the document and cut the line at the
        // fold. CSS pixels equal points here (the view starts unscaled), so
        // DOM geometry maps 1:1: the document height and the author's page
        // cuts come straight from the DOM, and consecutive / edge markers
        // collapse into nothing rather than emitting empty pages.
        let height = max(WebRenderer.pageSize.height, await contentHeight())
        // A cut inside the body's top / bottom padding means the marker is
        // the first / last thing in the document — snap it to the edge so
        // the `>= 2` rule below collapses it instead of emitting a
        // padding-only sliver page.
        let (rawCuts, padTop, padBottom) = await pageCuts()
        let cuts = rawCuts
            .map { $0 <= padTop + 1 ? 0 : ($0 >= height - padBottom - 1 ? height : $0) }
            .map { min(max($0, 0), height) }
            .sorted()
        var segments: [(top: CGFloat, height: CGFloat)] = []
        var top: CGFloat = 0
        for cut in cuts + [height] {
            if cut - top >= 2 { segments.append((top, cut - top)) }
            top = max(top, cut)
        }
        if segments.isEmpty { segments = [(0, height)] }

        // A page taller than the PDF format's 14,400 pt cap is scaled down
        // uniformly instead of being clipped there (CoreGraphics cuts
        // anything past the cap) — judged per page, so only a document with
        // an oversize section shrinks. The shrink is a paint-only CSS
        // transform while the view keeps its 595 CSS px layout width:
        // transforms never re-flow content — CSS `zoom` does, and WebKit
        // re-wrapped the text when we tried it — so the wrapping stays
        // exactly the preview's; the pages just come out proportionally
        // smaller, with nothing lost.
        var scale: CGFloat = 1
        if let tallest = segments.map(\.height).max(), tallest > WebRenderer.maxPageDimension {
            scale = WebRenderer.maxPageDimension / tallest
            await shrinkRendering(by: scale)
        }
        let pageWidth = (WebRenderer.pageSize.width * scale).rounded(.up)
        hostPanel.setContentSize(CGSize(width: WebRenderer.pageSize.width,
                                        height: max(WebRenderer.pageSize.height, height * scale)))
        webView.layoutSubtreeIfNeeded()
        // Give the web process a beat to repaint the newly exposed area;
        // capturing immediately after the resize can yield blank regions.
        try? await Task.sleep(nanoseconds: 300_000_000)

        // One section → one page, straight out of WebKit.
        if segments.count == 1 {
            return try await capture(CGRect(x: 0, y: 0, width: pageWidth,
                                            height: segments[0].height * scale))
        }
        // Several → capture each slice as its own page and assemble.
        let assembled = PDFDocument()
        for segment in segments {
            let data = try await capture(CGRect(x: 0, y: segment.top * scale,
                                                width: pageWidth,
                                                height: segment.height * scale))
            guard let document = PDFDocument(data: data), let page = document.page(at: 0) else {
                throw PDFAssemblyError()
            }
            assembled.insert(page, at: assembled.pageCount)
        }
        guard let data = assembled.dataRepresentation() else { throw PDFAssemblyError() }
        return data
    }

    private func capture(_ rect: CGRect) async throws -> Data {
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        return try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: configuration) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// The tops of the author's `\newpage` markers plus the body's vertical
    /// padding, in (unscaled) points — the padding lets `makePDF` tell a
    /// marker at the very start / end of the document from a real cut.
    private func pageCuts() async -> (cuts: [CGFloat], padTop: CGFloat, padBottom: CGFloat) {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                "({top: parseFloat(getComputedStyle(document.body).paddingTop) || 0, " +
                "bottom: parseFloat(getComputedStyle(document.body).paddingBottom) || 0, " +
                "cuts: Array.from(document.querySelectorAll('.md-pagebreak')).map(e => e.getBoundingClientRect().top + window.scrollY)})") { value, _ in
                let dict = value as? [String: Any] ?? [:]
                let cuts = (dict["cuts"] as? [NSNumber] ?? []).map { CGFloat(truncating: $0) }
                let top = (dict["top"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
                let bottom = (dict["bottom"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
                continuation.resume(returning: (cuts, top, bottom))
            }
        }
    }

    /// The full height of the laid-out document, in points. Falls back to 0
    /// (→ one A4 page) if the script can't run for some reason. Reads the
    /// root element only: it reports in root coordinates, which shrink with
    /// the body zoom `makePDF` applies — `body.scrollHeight` would keep
    /// reporting in the body's own zoomed units and never converge.
    private func contentHeight() async -> CGFloat {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { value, _ in
                continuation.resume(returning: (value as? NSNumber).map { CGFloat(truncating: $0) } ?? 0)
            }
        }
    }

    /// Shrink the document's rendering with a paint-only transform (used
    /// when the content is taller than a PDF page may be), then wait a beat
    /// so the repaint lands before the capture. Layout is untouched, so the
    /// height measured before the shrink scales exactly.
    private func shrinkRendering(by scale: CGFloat) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript(
                "document.body.style.transformOrigin = '0 0'; document.body.style.transform = 'scale(\(scale))'") { _, _ in
                continuation.resume()
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// Capture the rendered document as real A4 pages — the print pipeline
    /// pointed at a PDF file instead of a printer. WebKit paginates the
    /// way it prints: line-aware (no line of text sliced at a fold) and
    /// honoring the export CSS's `break-after: page`, so the author's
    /// `\newpage` markers become page boundaries here too. Used when the
    /// PDF Layout preference is A4; the default stays `makePDF`.
    func makeA4PDF(title: String) async throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-a4-\(UUID().uuidString).pdf")
        // Start from the shared print settings exactly like the Print
        // command, but force A4 paper and a silent save-to-file job.
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = WebRenderer.pageSize
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary().setValue(url, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue)
        let operation = printOperation(info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.jobTitle = title
        // WKWebView's printing view starts with a zero frame and won't size
        // itself; without this, pagination aborts ("view's frame was not
        // initialized properly before knowsPageRange:").
        operation.view?.frame = NSRect(origin: .zero, size: info.paperSize)
        // WKWebView paginates asynchronously in the web process, so the
        // synchronous `run()` the Print command uses would deadlock here —
        // it survives there only because the print panel spins the run
        // loop. The sheet-modal variant is the async-safe path: with both
        // panels hidden it shows no UI and just calls back when the job is
        // done, while the web view stays alive and hosted throughout.
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let completion = PrintCompletion { continuation.resume(returning: $0) }
            operation.runModal(for: hostPanel,
                               delegate: completion,
                               didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)),
                               contextInfo: Unmanaged.passRetained(completion).toOpaque())
        }
        guard success else { throw PDFPaginationError() }
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    /// The rich-content elements (math / Mermaid / PlantUML) after the
    /// engines have run: their bounding boxes in document order, in view
    /// points, plus whether each is math (it decides the image's alt
    /// text). Grows the view to the full document first — the snapshot
    /// API captures view coordinates, so every element must lie inside.
    func richElements() async -> [(rect: CGRect, isMath: Bool)] {
        let height = max(WebRenderer.pageSize.height, await contentHeight())
        hostPanel.setContentSize(CGSize(width: WebRenderer.pageSize.width, height: height))
        webView.layoutSubtreeIfNeeded()
        // Same repaint beat as `makePDF` — snapshotting the newly exposed
        // area immediately can yield blank regions.
        try? await Task.sleep(nanoseconds: 300_000_000)
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                "Array.from(document.querySelectorAll('.md-mathi, .md-mathd, .mermaid, .plantuml'))" +
                ".map(e => { const r = e.getBoundingClientRect(); " +
                "return [r.left + window.scrollX, r.top + window.scrollY, r.width, r.height, " +
                "(e.classList.contains('md-mathi') || e.classList.contains('md-mathd')) ? 1 : 0]; })") { value, _ in
                let rows = value as? [[NSNumber]] ?? []
                continuation.resume(returning: rows.compactMap { row in
                    guard row.count == 5 else { return nil }
                    // Keep even degenerate rects: the EPUB builder pairs
                    // these 1:1 with the elements in the markup, so
                    // dropping one would shift every later image.
                    return (CGRect(x: CGFloat(truncating: row[0]),
                                   y: CGFloat(truncating: row[1]),
                                   width: CGFloat(truncating: row[2]),
                                   height: CGFloat(truncating: row[3])),
                            row[4] == 1)
                })
            }
        }
    }

    /// A PNG snapshot of `rect` (view points) at double resolution, for
    /// crisp formulas and diagrams in the EPUB. `snapshotWidth` is in
    /// points and WebKit re-renders the region at the implied scale, so
    /// doubling it yields a genuine 2× image rather than an upscale.
    func snapshotPNG(of rect: CGRect) async throws -> Data {
        let clamped = CGRect(x: rect.minX, y: rect.minY,
                             width: max(rect.width, 1), height: max(rect.height, 1))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = clamped
        configuration.snapshotWidth = NSNumber(value: Double(clamped.width) * 2)
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? SnapshotError())
                }
            }
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError()
        }
        return png
    }

    /// A print operation that paginates the rendered web content.
    func printOperation(_ info: NSPrintInfo) -> NSPrintOperation {
        webView.printOperation(with: info)
    }

    // WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        waitForRenderComplete()
    }

    /// Poll until md-init.js flags the document fully rendered (or give up after
    /// a generous cap — Graphviz-backed PlantUML diagrams are slow). Plain docs
    /// and math/Mermaid settle almost immediately.
    private func waitForRenderComplete(attempt: Int = 0) {
        // PlantUML renders sequentially, up to ~20s per Graphviz diagram, so a
        // document with several slow diagrams needs a generous cap.
        let maxAttempts = 480 // ~120s at 0.25s each
        webView.evaluateJavaScript("document.documentElement.getAttribute('data-md-render-complete')") { [weak self] value, _ in
            guard let self else { return }
            if (value as? String) == "1" || attempt >= maxAttempts {
                self.onReady?(.success(())); self.onReady = nil
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.waitForRenderComplete(attempt: attempt + 1)
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onReady?(.failure(error)); onReady = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onReady?(.failure(error)); onReady = nil
    }
}

/// The document output actions, presented against the key window.
@MainActor
enum DocumentExport {

    /// `NSSharingServicePicker` is deallocated as soon as the call that
    /// shows it returns, which would dismiss the popover; keep it alive
    /// until the user is done with it.
    private static var sharePicker: NSSharingServicePicker?

    /// Print the rendered document, themed to match the current appearance.
    static func print(source: String, title: String, dark: Bool) async {
        let html = MarkdownHTML.document(source, title: title, dark: dark, export: true)
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

    /// The PDF bytes for the current layout preference: one content-tall
    /// page per section (the default), or real A4 pages via the print
    /// pipeline. Both read the same rendered web view.
    private static func makePDFData(_ renderer: WebRenderer, title: String) async throws -> Data {
        switch PDFLayout.current {
        case .single: return try await renderer.makePDF()
        case .a4: return try await renderer.makeA4PDF(title: title)
        }
    }

    /// Render the document to a PDF and offer it through the share picker.
    static func sharePDF(source: String, title: String, dark: Bool) async {
        let html = MarkdownHTML.document(source, title: title, dark: dark, export: true)
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            let data = try await makePDFData(renderer, title: title)
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

    /// Render the document to a PDF and save it where the user chooses.
    /// Same rendering as `sharePDF` — only the destination differs: a
    /// save panel instead of the share picker.
    static func exportPDF(source: String, title: String, dark: Bool) async {
        let html = MarkdownHTML.document(source, title: title, dark: dark, export: true)
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            let data = try await makePDFData(renderer, title: title)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "\(sanitized(title)).pdf"
            // Sheet on the document window when there is one; app-modal
            // otherwise (e.g. invoked from the menu bar with no key window).
            let response: NSApplication.ModalResponse
            if let window = keyWindow() {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            if response == .OK, let url = panel.url {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not export PDF"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        withExtendedLifetime(renderer) {}
    }

    /// Build the whole book as an EPUB 3 (see `EPUBExport`) and save it
    /// where the user chooses — the book-window sibling of `exportPDF`.
    /// The panel comes first: photographing a book's diagrams can take a
    /// while, and the user may cancel anyway.
    static func exportEPUB(book: EPUBBook) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.epub]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(sanitized(book.title)).epub"
        let response: NSApplication.ModalResponse
        if let window = keyWindow() {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        do {
            let data = try await EPUBExport.build(book: book)
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not export EPUB"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
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

// MARK: - EPUB export

/// A book read into memory for the EPUB export — display names and
/// Markdown sources, in the same reading order as the PDF compile (see
/// `BookLibrary.readEPUBBook`).
struct EPUBBook {
    struct Article {
        let name: String
        let markdown: String
    }
    struct Chapter {
        let name: String
        let articles: [Article]
    }
    let title: String
    /// Top-level articles — the book's front matter, before any chapter.
    let articles: [Article]
    let chapters: [Chapter]
}

/// Builds the EPUB 3 container for a book: one XHTML file per unit (title
/// page, each root article, then per chapter a heading page followed by
/// its articles), a `nav.xhtml` TOC, the export stylesheet, and the OPF
/// package — zipped by `EPUBZipWriter`. Everything but `build` (which
/// photographs rich content in the offscreen `WebRenderer`) is pure
/// string work, kept static and non-isolated so it is directly testable.
enum EPUBExport {

    /// One spine entry: its file name inside OEBPS and the finished
    /// XHTML document that goes there.
    struct Unit {
        let file: String
        let title: String
        let xhtml: String
    }

    /// One table-of-contents row; chapters carry their articles as
    /// children, nested one level like the book itself.
    struct NavEntry {
        let title: String
        let file: String
        var children: [NavEntry] = []
    }

    /// The container identity — the FIRST zip entry, stored uncompressed,
    /// exactly these bytes.
    static let mimetype = "application/epub+zip"

    /// Points the reader at the package document.
    static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
    </rootfiles>
    </container>
    """

    // MARK: Building (renders rich content, hence main-actor)

    /// Render every unit of `book` and assemble the archive. Units with
    /// rich content (math / Mermaid / PlantUML) render once in the
    /// offscreen `WebRenderer`, which photographs each rich element into
    /// a PNG; plain units never touch the web view.
    @MainActor
    static func build(book: EPUBBook) async throws -> Data {
        var units: [Unit] = []
        var images: [(file: String, data: Data)] = []
        var entries: [NavEntry] = []

        // A page holding nothing but a level-1 heading — the title page
        // and every chapter's opener.
        func headingUnit(_ title: String) -> Unit {
            Unit(file: String(format: "unit-%03d.xhtml", units.count), title: title,
                 xhtml: xhtmlDocument(title: title, body: "<h1>\(xmlEscape(title))</h1>"))
        }
        func articleUnit(_ article: EPUBBook.Article) async throws -> Unit {
            let file = String(format: "unit-%03d.xhtml", units.count)
            let document = MarkdownHTML.document(article.markdown, title: article.name,
                                                 dark: false, export: true)
            var body = bodyHTML(of: document)
            if containsRichContent(body) {
                let rich = try await richSnapshots(document: document, unit: units.count)
                body = replacingRichElements(in: body, with: rich.tags)
                images.append(contentsOf: rich.images)
            }
            return Unit(file: file, title: article.name,
                        xhtml: xhtmlDocument(title: article.name, body: xhtmlBody(body)))
        }

        units.append(headingUnit(book.title))          // the title page
        for article in book.articles {
            let unit = try await articleUnit(article)
            units.append(unit)
            entries.append(NavEntry(title: article.name, file: unit.file))
        }
        for chapter in book.chapters {
            let heading = headingUnit(chapter.name)
            units.append(heading)
            var children: [NavEntry] = []
            for article in chapter.articles {
                let unit = try await articleUnit(article)
                units.append(unit)
                children.append(NavEntry(title: article.name, file: unit.file))
            }
            entries.append(NavEntry(title: chapter.name, file: heading.file, children: children))
        }
        return archive(title: book.title, units: units, entries: entries, images: images,
                       identifier: "urn:uuid:\(UUID().uuidString)", modified: modifiedNow())
    }

    /// Render `document` (with its engines — `load` waits for the
    /// render-complete flag, exactly like the PDF path) and photograph
    /// each rich element. Returns the replacement `<img>` tags in
    /// document order plus the PNGs they reference.
    @MainActor
    private static func richSnapshots(document: String, unit: Int) async throws
        -> (tags: [String], images: [(file: String, data: Data)]) {
        let renderer = WebRenderer()
        try await renderer.load(html: document)
        let elements = await renderer.richElements()
        var tags: [String] = []
        var images: [(file: String, data: Data)] = []
        for (index, element) in elements.enumerated() {
            let file = String(format: "images/unit-%03d-rich-%d.png", unit, index)
            let png = try await renderer.snapshotPNG(of: element.rect)
            images.append((file: file, data: png))
            // The PNG is 2×; the width attribute pins the displayed size
            // back to the layout size, and the stylesheet's
            // `max-width: 100%` still shrinks it on a narrow reader.
            tags.append("<img src=\"\(file)\" alt=\"\(element.isMath ? "formula" : "diagram")\""
                        + " width=\"\(Int(element.rect.width.rounded()))\"/>")
        }
        withExtendedLifetime(renderer) {}
        return (tags, images)
    }

    // MARK: Pure pieces (testable)

    /// Whether the rendered markup carries anything the engines must
    /// typeset — the trigger for the web-view snapshot pass.
    static func containsRichContent(_ html: String) -> Bool {
        html.contains("class=\"md-mathi\"") || html.contains("class=\"md-mathd\"")
            || html.contains("class=\"mermaid\"") || html.contains("class=\"plantuml\"")
    }

    /// The renderer's `<body>` content — everything between the body tags
    /// of the full themed document (`MarkdownHTML`'s per-block rendering
    /// is private; the document wrapper is its public face).
    static func bodyHTML(of document: String) -> String {
        guard let start = document.range(of: "<body"),
              let open = document.range(of: ">", range: start.upperBound..<document.endIndex),
              let end = document.range(of: "</body>", options: .backwards)
        else { return document }
        return String(document[open.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Post-process rendered HTML into well-formed XHTML: scripts (the
    /// engine references) stripped, void elements self-closed, and the
    /// one named entity the renderer uses replaced with its numeric form
    /// — XML predefines only amp / lt / gt / quot / apos.
    static func xhtmlBody(_ html: String) -> String {
        var out = replace("<script[^>]*>[\\s\\S]*?</script>", "", in: html)
        out = replace("<(br|hr|img)((?:[^>\"]|\"[^\"]*\")*?)\\s*/?>", "<$1$2/>", in: out)
        return out.replacingOccurrences(of: "&bull;", with: "&#8226;")
    }

    /// Replace each rich element in `html` — in document order, the same
    /// order `WebRenderer.richElements` reports — with its image tag.
    /// The elements' inner text is HTML-escaped by the renderer, so the
    /// first matching close tag is always the element's own.
    static func replacingRichElements(in html: String, with tags: [String]) -> String {
        guard !tags.isEmpty, let regex = try? NSRegularExpression(
            pattern: "<(span|div|pre) class=\"(?:md-mathi|md-mathd|mermaid|plantuml)\">[\\s\\S]*?</\\1>")
        else { return html }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var out = ""
        var cursor = html.startIndex
        for (match, tag) in zip(matches, tags) {
            guard let range = Range(match.range, in: html) else { continue }
            out += html[cursor..<range.lowerBound]
            out += tag
            cursor = range.upperBound
        }
        out += html[cursor...]
        return out
    }

    /// One XHTML5 content document, in the EPUB's shared stylesheet.
    static func xhtmlDocument(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
        <meta charset="utf-8"/>
        <title>\(xmlEscape(title))</title>
        <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// The EPUB 3 navigation document: root articles first, then each
    /// chapter with its articles nested one level below it.
    static func nav(title: String, entries: [NavEntry]) -> String {
        func list(_ entries: [NavEntry]) -> String {
            guard !entries.isEmpty else { return "" }
            let items = entries.map { entry in
                "<li><a href=\"\(entry.file)\">\(xmlEscape(entry.title))</a>\(list(entry.children))</li>"
            }.joined(separator: "\n")
            return "\n<ol>\n\(items)\n</ol>\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head>
        <meta charset="utf-8"/>
        <title>\(xmlEscape(title))</title>
        <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
        <nav epub:type="toc">
        <h1>\(xmlEscape(title))</h1>\(list(entries))</nav>
        </body>
        </html>
        """
    }

    /// The OPF package document: metadata, a manifest of every file, and
    /// the spine in reading order.
    static func opf(title: String, identifier: String, modified: String,
                    units: [String], images: [String]) -> String {
        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
        manifest += "<item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>\n"
        for (index, file) in units.enumerated() {
            manifest += "<item id=\"u\(index)\" href=\"\(file)\" media-type=\"application/xhtml+xml\"/>\n"
        }
        for (index, file) in images.enumerated() {
            manifest += "<item id=\"i\(index)\" href=\"\(file)\" media-type=\"image/png\"/>\n"
        }
        let spine = units.indices.map { "<itemref idref=\"u\($0)\"/>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">\(identifier)</dc:identifier>
        <dc:title>\(xmlEscape(title))</dc:title>
        <dc:language>en</dc:language>
        <meta property="dcterms:modified">\(modified)</meta>
        </metadata>
        <manifest>
        \(manifest)</manifest>
        <spine>
        \(spine)
        </spine>
        </package>
        """
    }

    /// The book's stylesheet: the export CSS the PDFs use, extracted from
    /// a rendered document (the CSS itself is private to `MarkdownHTML`),
    /// with a light EPUB override — the reader owns pages and margins.
    static func stylesheet() -> String {
        let document = MarkdownHTML.document("", title: "style", dark: false, export: true)
        var css = ""
        if let start = document.range(of: "<style>"),
           let end = document.range(of: "</style>") {
            css = String(document[start.upperBound..<end.lowerBound])
        }
        return css + "\n/* EPUB: the reader owns pages and margins. */\nbody { padding: 0.5em 5%; }\n"
    }

    /// Assemble the finished container: mimetype first (stored, per
    /// EPUB), then META-INF and the OEBPS payload.
    static func archive(title: String, units: [Unit], entries: [NavEntry],
                        images: [(file: String, data: Data)],
                        identifier: String, modified: String) -> Data {
        var zip = EPUBZipWriter()
        zip.add("mimetype", Data(mimetype.utf8))
        zip.add("META-INF/container.xml", Data(containerXML.utf8))
        zip.add("OEBPS/content.opf", Data(opf(title: title, identifier: identifier,
                                              modified: modified,
                                              units: units.map(\.file),
                                              images: images.map { $0.file }).utf8))
        zip.add("OEBPS/nav.xhtml", Data(nav(title: title, entries: entries).utf8))
        zip.add("OEBPS/style.css", Data(stylesheet().utf8))
        for unit in units { zip.add("OEBPS/\(unit.file)", Data(unit.xhtml.utf8)) }
        for image in images { zip.add("OEBPS/\(image.file)", image.data) }
        return zip.finish()
    }

    /// The `dcterms:modified` timestamp: UTC, second precision.
    static func modifiedNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func replace(_ pattern: String, _ template: String, in s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        return regex.stringByReplacingMatches(in: s, options: [],
                                              range: NSRange(s.startIndex..., in: s),
                                              withTemplate: template)
    }
}

/// A minimal ZIP writer for the EPUB container. EPUB requires the
/// `mimetype` entry uncompressed, and a book's text is small — so every
/// entry is STORED, with the classic table-driven CRC-32, local headers,
/// a central directory and the end record. No dependencies.
struct EPUBZipWriter {
    private var body = Data()
    private var directory = Data()
    private var count: UInt16 = 0

    /// Append one file. Order is preserved — add "mimetype" first.
    mutating func add(_ name: String, _ contents: Data) {
        let nameBytes = Data(name.utf8)
        let crc = Self.crc32(contents)
        let size = UInt32(contents.count)
        let offset = UInt32(body.count)
        // Local file header. A fixed DOS date (1980-01-01 00:00) keeps
        // the archive deterministic for a given payload.
        body.appendLE32(0x04034B50)
        body.appendLE16(20)                      // version needed
        body.appendLE16(0)                       // flags
        body.appendLE16(0)                       // method: stored
        body.appendLE16(0)                       // DOS time
        body.appendLE16(0x21)                    // DOS date
        body.appendLE32(crc)
        body.appendLE32(size)                    // compressed == raw
        body.appendLE32(size)
        body.appendLE16(UInt16(nameBytes.count))
        body.appendLE16(0)                       // extra length
        body.append(nameBytes)
        body.append(contents)
        // Matching central-directory record.
        directory.appendLE32(0x02014B50)
        directory.appendLE16(20)                 // version made by
        directory.appendLE16(20)                 // version needed
        directory.appendLE16(0)                  // flags
        directory.appendLE16(0)                  // method
        directory.appendLE16(0)                  // DOS time
        directory.appendLE16(0x21)               // DOS date
        directory.appendLE32(crc)
        directory.appendLE32(size)
        directory.appendLE32(size)
        directory.appendLE16(UInt16(nameBytes.count))
        directory.appendLE16(0)                  // extra
        directory.appendLE16(0)                  // comment
        directory.appendLE16(0)                  // disk number
        directory.appendLE16(0)                  // internal attributes
        directory.appendLE32(0)                  // external attributes
        directory.appendLE32(offset)
        directory.append(nameBytes)
        count += 1
    }

    /// The finished archive: entries, central directory, end record.
    func finish() -> Data {
        var out = body
        out.append(directory)
        out.appendLE32(0x06054B50)
        out.appendLE16(0)                        // this disk
        out.appendLE16(0)                        // directory's disk
        out.appendLE16(count)
        out.appendLE16(count)
        out.appendLE32(UInt32(directory.count))
        out.appendLE32(UInt32(body.count))       // directory offset
        out.appendLE16(0)                        // comment length
        return out
    }

    /// Table-driven CRC-32 (the ZIP / PNG polynomial, reflected).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }
    mutating func appendLE32(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                            UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
