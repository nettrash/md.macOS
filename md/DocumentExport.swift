//
//  DocumentExport.swift
//  md
//
//  Created by nettrash on 29/06/2026.
//
//  Print, "share rendered PDF", "export as PDF", "export as HTML",
//  "export as LaTeX" and "share source" — the document's output paths. The
//  macOS (AppKit) sibling of the iOS export file.
//
//  "Export as LaTeX…" is the odd one out and the only one with no rendering
//  behind it at all: `LaTeXExport` serializes the parsed blocks straight to
//  `.tex`, which is what lets it hand the author's mathematics back as
//  mathematics instead of as a picture of it.
//
//  "Export as HTML…" writes one self-contained file: the live DOM captured
//  *after* the engines have run (diagrams are inline SVG, formulas already
//  expanded), with every script and stylesheet link removed, so it opens
//  anywhere with no engines, no folder of assets and no network. KaTeX's
//  stylesheet rides along — fonts inlined as data: URIs — but only for a
//  document that actually has math.
//
//  Rendering goes through an offscreen `WKWebView` rather than printing the
//  text view directly, so WebKit lays the page out with the full document
//  CSS. Print and PDF both come out as real A4 pages — WebKit paginates
//  line-aware (nothing sliced at a fold) and honors `break-after: page`,
//  so the author's `\newpage` markers cut pages. The pages are plain
//  white with the light ink regardless of the window's appearance: paper
//  tint and dark mode are screen themes (see `MarkdownHTML.css`).
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
import CryptoKit
import PDFKit
import UniformTypeIdentifiers
import WebKit

/// The print-pipeline pagination did not produce a PDF.
private struct PDFPaginationError: LocalizedError {
    var errorDescription: String? { "The PDF pages could not be produced." }
}

/// A rich-content element could not be photographed for the EPUB.
private struct SnapshotError: LocalizedError {
    var errorDescription: String? { "The rich-content images could not be captured." }
}

/// The finished page could not be read back out of the web view for the
/// self-contained HTML export.
private struct HTMLCaptureError: LocalizedError {
    var errorDescription: String? { "The rendered page could not be captured." }
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

// MARK: - PDF page size (trim sizes)

/// A named PDF page ("trim") size in PostScript points — 1 inch = 72 pt.
///
/// This small table is the *single source of truth* the three platforms copy
/// verbatim (iOS feeds it to `paperRect`/`printableRect`, macOS to
/// `NSPrintInfo.paperSize`, Android builds a custom `MediaSize` from it), so the
/// numbers must live in exactly one place per platform and never be typed twice
/// — a drift here would paginate the same document differently on iOS than on
/// Android.
///
/// A4 keeps the historical `595.2 × 841.8` (210 × 297 mm rounded to a tenth of a
/// point — the value the app paginated to before trim sizes existed), so
/// choosing A4, the default, reproduces the old output exactly. The imperial
/// sizes are exact (6 × 9" = 432 × 648 pt); A5 is 148 × 210 mm converted the
/// same way A4 was.
struct PageSize: Identifiable, Equatable {
    let id: String       // stable key for @AppStorage / cross-platform parity — never localized
    let label: String    // the menu title
    let width: CGFloat   // points, portrait
    let height: CGFloat

    var size: CGSize { CGSize(width: width, height: height) }

    static let a4           = PageSize(id: "a4",      label: "A4",           width: 595.2, height: 841.8)
    static let a5           = PageSize(id: "a5",      label: "A5",           width: 419.5, height: 595.3)
    static let usLetter     = PageSize(id: "letter",  label: "US Letter",    width: 612,   height: 792)
    static let usLegal      = PageSize(id: "legal",   label: "US Legal",     width: 612,   height: 1008)
    static let sixByNine    = PageSize(id: "6x9",     label: "6 × 9\"",      width: 432,   height: 648)
    static let fiveByEight  = PageSize(id: "5x8",     label: "5 × 8\"",      width: 360,   height: 576)
    static let digest       = PageSize(id: "5.5x8.5", label: "5.5 × 8.5\"",  width: 396,   height: 612)

    /// Every offered size, in menu order — A4 first, since it is the default.
    static let all: [PageSize] = [.a4, .a5, .usLetter, .usLegal, .sixByNine, .fiveByEight, .digest]

    /// The size stored under `id`, falling back to A4 for an empty or unknown
    /// key — so a first launch, or a preference written by some future version
    /// that offered a size this build doesn't, still lands on the default.
    static func named(_ id: String) -> PageSize {
        all.first { $0.id == id } ?? .a4
    }

    /// The body margin (CSS `padding`) for this trim size, scaled down from
    /// A4's `48px 56px` so a small page doesn't wear A4-sized margins — a 6 × 9"
    /// booklet with A4 margins wastes a quarter of its width. Each axis scales
    /// with its own dimension, so A4 reproduces `48px 56px` to the pixel (the
    /// historical value, hence an A4 export is byte-for-byte what it always was)
    /// and every smaller page gets a proportionate frame. Rounded to whole
    /// pixels: sub-pixel margins are invisible, and the integer string is what
    /// keeps the A4 case identical.
    var cssPadding: String {
        let vertical = Int((48 * height / PageSize.a4.height).rounded())
        let horizontal = Int((56 * width / PageSize.a4.width).rounded())
        return "\(vertical)px \(horizontal)px"
    }
}

// MARK: - Diagram → standalone SVG (Feature 1)

/// The pure pieces of "export one diagram as a real vector `.svg` file":
/// which blocks a document offers, and the fix-up that turns a diagram's
/// rendered root `<svg>` (read out of the offscreen DOM as outerHTML) into a
/// self-standing SVG document. No WebKit and no I/O here — all of it is
/// unit-testable.
///
/// Only the three *diagram* engines qualify — Mermaid, Graphviz and PlantUML
/// each render to an inline `<svg>`. Math does **not**: KaTeX lays a formula
/// out as HTML + CSS, never SVG, so a formula has no vector to export and is
/// deliberately never offered.
enum DiagramSVG {

    /// One diagram the document offers for SVG export, in document order.
    struct Diagram: Equatable {
        /// 0-based position among the document's diagrams — the same order
        /// `querySelectorAll('pre.mermaid, div.plantuml, div.graphviz')`
        /// reports the rendered containers in, so the capture step pulls the
        /// matching `<svg>` back out by this index. (The DOM query and this
        /// list both walk the document in order and both see only diagrams,
        /// so they pair up index-for-index — the same document-order pairing
        /// the EPUB path relies on between its rich containers and their
        /// snapshots, minus the formulas neither of us can export.)
        let ordinal: Int
        let kind: Kind
        /// The Graphviz layout program (`dot` / `neato` / …) for a
        /// `.graphviz` diagram; nil for the others. Only for the menu label.
        let engine: String?
        /// A short label lifted from the diagram's source — its first
        /// non-empty line — so a reader can tell two diagrams apart in the
        /// menu. Empty when the source has no non-blank line.
        let label: String

        enum Kind: String { case mermaid, plantuml, graphviz }

        /// The engine's display name, naming the Graphviz layout when it is
        /// not the default `dot` (a `neato` graph reads quite differently).
        var typeName: String {
            switch kind {
            case .mermaid: return "Mermaid"
            case .plantuml: return "PlantUML"
            case .graphviz:
                if let engine, engine != "dot" { return "Graphviz (\(engine))" }
                return "Graphviz"
            }
        }

        /// The menu row: the type, plus the source label when there is one.
        var menuTitle: String {
            label.isEmpty ? typeName : "\(typeName): \(label)"
        }
    }

    /// The diagrams a document offers, in document order.
    ///
    /// Mirrors exactly how `MarkdownHTML` decides what becomes a diagram, so
    /// this list pairs index-for-index with the rendered DOM's diagram
    /// containers:
    ///  • a raw `.puml` / `.gv` document is one diagram — the whole file (see
    ///    `MarkdownHTML.document`, which renders it without parsing Markdown);
    ///  • otherwise every fenced block whose info string names Mermaid,
    ///    PlantUML or a Graphviz layout — including one nested in a block
    ///    quote, which `MarkdownHTML` renders by recursing into the quote, so
    ///    the walk recurses too and the quoted diagram keeps its place.
    /// Math fences and every other code block are skipped: a formula is not
    /// SVG, and ordinary code is not a diagram.
    static func diagrams(inSource source: String) -> [Diagram] {
        if MarkdownHTML.isRawPlantUML(source) {
            return [Diagram(ordinal: 0, kind: .plantuml, engine: nil,
                            label: firstLine(of: source))]
        }
        if MarkdownHTML.isRawGraphviz(source) {
            return [Diagram(ordinal: 0, kind: .graphviz, engine: "dot",
                            label: firstLine(of: source))]
        }
        var diagrams: [Diagram] = []
        appendDiagrams(in: MarkdownParser.parse(source), into: &diagrams)
        return diagrams
    }

    /// Walk a block list in render order, appending each diagram; recurse into
    /// block quotes so a quoted diagram lands in its document-order place
    /// (MarkdownHTML renders quoted blocks in line).
    private static func appendDiagrams(in blocks: [MarkdownBlock], into out: inout [Diagram]) {
        for block in blocks {
            switch block.kind {
            case let .codeBlock(language, code):
                guard let classified = classify(language) else { continue }
                out.append(Diagram(ordinal: out.count, kind: classified.kind,
                                   engine: classified.engine, label: firstLine(of: code)))
            case let .quote(inner):
                appendDiagrams(in: inner, into: &out)
            default:
                continue
            }
        }
    }

    /// Classify a fence info string the way `MarkdownHTML.renderBlock` does —
    /// lower-cased, the same three families, the same Graphviz alias table —
    /// or nil for anything that is not a diagram (math, csv, plain code).
    /// Reusing `MarkdownHTML.graphvizEngines` keeps the two in lockstep: a
    /// layout added there is offered here without a second edit.
    private static func classify(_ language: String?) -> (kind: Diagram.Kind, engine: String?)? {
        switch (language ?? "").lowercased() {
        case "mermaid":
            return (.mermaid, nil)
        case "plantuml", "puml", "plant-uml":
            return (.plantuml, nil)
        case let lang where MarkdownHTML.graphvizEngines[lang] != nil:
            return (.graphviz, MarkdownHTML.graphvizEngines[lang])
        default:
            return nil
        }
    }

    /// The first non-empty line of `source`, trimmed and capped so one long
    /// line can't dwarf the menu. Purely cosmetic — a human reads it, nothing
    /// re-parses it — so ordinary `String` line splitting is fine here.
    private static func firstLine(of source: String) -> String {
        for line in source.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed.count > 40
                    ? trimmed.prefix(40).trimmingCharacters(in: .whitespaces) + "…"
                    : trimmed
            }
        }
        return ""
    }

    // MARK: SVG fix-up

    /// Turn a diagram's rendered root `<svg …>…</svg>` (read from the DOM as
    /// outerHTML) into a standalone `.svg` document: guarantee the SVG
    /// namespace, give an unsized root real pixel dimensions from its
    /// `viewBox`, and prepend the XML prolog so the file is a well-formed
    /// standalone document any browser or vector editor opens.
    ///
    /// Mermaid emits `width="100%"` and no `height` — fine inside a flowing
    /// page (the page CSS caps it), useless in a file, where it renders at
    /// zero or full-viewport height. Graphviz and PlantUML already write
    /// absolute `width`/`height`, so those are left exactly as the engine drew
    /// them.
    ///
    /// String scanning (not `ScalarText`) throughout, matching how the EPUB
    /// export reads this same engine-generated markup: the input is a
    /// serializer's ASCII tag syntax, never author prose, so there is no
    /// combining-mark hazard to guard against.
    static func standaloneDocument(fromSVG svg: String) -> String {
        let fixed = withResolvedSize(inNamespaced(svg))
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + fixed
    }

    /// The root `<svg …>` opening tag's range (from `<svg` to the first `>`),
    /// or nil if there isn't one. Engine outerHTML never puts a `>` inside the
    /// root tag's attribute values, so the first `>` really does close it.
    private static func openingTagRange(of svg: String) -> Range<String.Index>? {
        guard let open = svg.range(of: "<svg"),
              let close = svg.range(of: ">", range: open.upperBound..<svg.endIndex) else { return nil }
        return open.lowerBound..<close.upperBound
    }

    /// Ensure the root carries the default SVG namespace so the standalone
    /// file is well-formed. Both engines already declare it, but a file must
    /// not lean on that.
    private static func inNamespaced(_ svg: String) -> String {
        guard let tagRange = openingTagRange(of: svg) else { return svg }
        if attribute("xmlns", in: String(svg[tagRange])) != nil { return svg }
        var result = svg
        // Right after `<svg`, before the other attributes.
        result.insert(contentsOf: " xmlns=\"http://www.w3.org/2000/svg\"",
                      at: svg.index(tagRange.lowerBound, offsetBy: 4))
        return result
    }

    /// Give the root real dimensions when it lacks them. If both `width` and
    /// `height` are already absolute lengths the engine sized it (Graphviz,
    /// PlantUML) — leave it untouched. Otherwise, when a 4-number `viewBox` is
    /// present, set `width`/`height` to the viewBox's own width and height,
    /// which is what makes a Mermaid `width="100%"` file open at its true size.
    private static func withResolvedSize(_ svg: String) -> String {
        guard let tagRange = openingTagRange(of: svg) else { return svg }
        let tag = String(svg[tagRange])
        if isAbsoluteLength(attribute("width", in: tag)),
           isAbsoluteLength(attribute("height", in: tag)) { return svg }
        guard let box = viewBox(in: tag), box.count == 4 else { return svg }
        var newTag = setAttribute("width", to: box[2], in: tag)
        newTag = setAttribute("height", to: box[3], in: newTag)
        return svg.replacingCharacters(in: tagRange, with: newTag)
    }

    /// The value range of a whole attribute `name="…"` (or `name='…'`) inside
    /// an opening tag. The leading space is load-bearing: it matches only a
    /// whole attribute, so `width` never captures `stroke-width`.
    private static func attributeValueRange(_ name: String, in tag: String)
        -> Range<String.Index>? {
        for quote in ["\"", "'"] {
            if let key = tag.range(of: " \(name)=\(quote)"),
               let close = tag.range(of: quote, range: key.upperBound..<tag.endIndex) {
                return key.upperBound..<close.lowerBound
            }
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        attributeValueRange(name, in: tag).map { String(tag[$0]) }
    }

    /// Set `name`'s value, or add `name="value"` after `<svg` when absent.
    private static func setAttribute(_ name: String, to value: String, in tag: String) -> String {
        if let range = attributeValueRange(name, in: tag) {
            return tag.replacingCharacters(in: range, with: value)
        }
        var result = tag
        result.insert(contentsOf: " \(name)=\"\(value)\"",
                      at: result.index(result.startIndex, offsetBy: 4))  // past "<svg"
        return result
    }

    /// Whether an attribute value is an absolute SVG length: present, and a
    /// number (optionally with a unit like `pt`/`px`), but not a percentage.
    /// A missing value and `width="100%"` are both "not absolute", which is
    /// exactly what makes a Mermaid root get resized and a Graphviz root not.
    private static func isAbsoluteLength(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty, !value.hasSuffix("%") else { return false }
        return value.first.map { $0 == "." || $0.isNumber } ?? false
    }

    /// The `viewBox`'s space/comma-separated tokens, or nil.
    private static func viewBox(in tag: String) -> [String]? {
        attribute("viewBox", in: tag)?
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
    }
}

/// Loads themed HTML into an offscreen web view, then yields a PDF or a
/// print operation once layout has settled. Hold a strong reference for the
/// duration of the operation — the print operation keeps using the web view.
@MainActor
final class WebRenderer: NSObject, WKNavigationDelegate {
    /// A4 at 72 dpi (rounded), in points — the width the renderer's web view
    /// lays content out against (its host panel's size), and the geometry the
    /// EPUB snapshots measure in. Not the paper the PDF paginates to: that is a
    /// chosen `PageSize` (default `a4PageSize`), fed to `NSPrintInfo.paperSize`.
    static let pageSize = CGSize(width: 595, height: 842)

    /// Real A4 in points (210 × 297 mm at 72 dpi) — the default page a shared
    /// / exported PDF paginates to, and the value `PageSize.a4` carries (see
    /// `makePDF(title:pageSize:)`, which takes any trim size).
    static let a4PageSize = CGSize(width: 595.2, height: 841.8)

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

    /// The full height of the laid-out document, in points. Falls back to 0
    /// if the script can't run for some reason.
    private func contentHeight() async -> CGFloat {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { value, _ in
                continuation.resume(returning: (value as? NSNumber).map { CGFloat(truncating: $0) } ?? 0)
            }
        }
    }

    /// Capture the rendered document as real pages of `pageSize` — the print
    /// pipeline pointed at a PDF file instead of a printer, so a shared /
    /// exported PDF is exactly what printing produces. WebKit paginates the way
    /// it prints: line-aware (no line of text sliced at a fold) and honoring
    /// the export CSS's `break-after: page`, so the author's `\newpage`
    /// markers cut pages here too.
    ///
    /// The print operation reflows the web content to the printable width it is
    /// given, so a narrower trim size lays the text out narrower — the caller
    /// pairs this with the matching scaled CSS margin (see `PageSize.cssPadding`
    /// / `styledForExport`). `pageSize` defaults to A4 for callers that don't
    /// offer a choice. The offscreen web view's own host-panel size is left
    /// alone (the EPUB snapshots measure against it); only the paper changes.
    func makePDF(title: String, pageSize: CGSize = WebRenderer.a4PageSize) async throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-pdf-\(UUID().uuidString).pdf")
        // Start from the shared print settings exactly like the Print
        // command, but force the chosen paper and a silent save-to-file job.
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = pageSize
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

    /// The rich-content elements (math / Mermaid / Graphviz / PlantUML)
    /// after the engines have run: their bounding boxes in document order,
    /// in view points, plus whether each is math (it decides the image's
    /// alt text). Grows the view to the full document first — the snapshot
    /// API captures view coordinates, so every element must lie inside.
    ///
    /// This selector, `EpubBuilder.containsRichContent` and
    /// `EpubBuilder.replacingRichElements` enumerate the same set of
    /// containers and must be changed together: a class one of them misses
    /// either skips the snapshot pass entirely or shifts every later image
    /// onto the wrong element.
    func richElements() async -> [(rect: CGRect, isMath: Bool)] {
        let height = max(WebRenderer.pageSize.height, await contentHeight())
        hostPanel.setContentSize(CGSize(width: WebRenderer.pageSize.width, height: height))
        webView.layoutSubtreeIfNeeded()
        // Give the web process a beat to repaint the newly exposed area —
        // snapshotting it immediately can yield blank regions.
        try? await Task.sleep(nanoseconds: 300_000_000)
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                "Array.from(document.querySelectorAll(" +
                "'.md-mathi, .md-mathd, .mermaid, .plantuml, .graphviz'))" +
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

    /// The rendered document as one self-contained HTML file.
    ///
    /// Taken from the live DOM *after* `data-md-render-complete`, so what is
    /// captured is the finished page: Mermaid, Graphviz and PlantUML have
    /// already become inline `<svg>`, and KaTeX has already expanded its
    /// formulas into markup. Nothing is left to run, so every `<script>` and
    /// every stylesheet `<link>` into `rich/` is removed — the exported file
    /// must not reach for an engine that will not be there. They go in the
    /// DOM, not by string surgery on the serialized markup.
    ///
    /// `outerHTML` does not include the doctype, and without one every
    /// browser renders the page in quirks mode, so it is put back by hand.
    func selfContainedHTML() async throws -> String {
        let capture = """
        (function () {
          document.querySelectorAll('script, link[rel="stylesheet"]').forEach(function (el) {
            el.remove();
          });
          // A stale completion flag would be misleading in a file that has
          // nothing left to complete.
          document.documentElement.removeAttribute('data-md-render-complete');
          return document.documentElement.outerHTML;
        })()
        """
        let captured = try await webView.evaluateJavaScript(capture)
        guard let markup = captured as? String, !markup.isEmpty else {
            throw HTMLCaptureError()
        }
        return "<!DOCTYPE html>\n" + markup
    }

    /// Read the rendered root `<svg>` of the diagram at `index` (0-based, in
    /// document order among `pre.mermaid`, `div.plantuml`, `div.graphviz` —
    /// the diagram half of the selector `richElements` uses) straight out of
    /// the finished DOM as outerHTML. That is the real vector, not a
    /// rasterised snapshot.
    ///
    /// Nil when that diagram has no `<svg>`: a block whose engine threw or
    /// timed out is left showing its source text (see md-init.js), and there
    /// is nothing vector to export.
    func diagramSVG(at index: Int) async -> String? {
        let script = """
        (function () {
          var nodes = document.querySelectorAll('pre.mermaid, div.plantuml, div.graphviz');
          var el = nodes[\(index)];
          if (!el) return null;
          var svg = el.querySelector('svg');
          return svg ? svg.outerHTML : null;
        })()
        """
        let value = try? await webView.evaluateJavaScript(script)
        return value as? String
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
            // Real A4, the same page an *A4* exported / shared PDF paginates to
            // — so a document proofed via Export as PDF prints with the same
            // folds, not the printer's default paper's (Page Setup can still
            // override deliberately). Print stays A4 rather than following the
            // export's trim-size preference: a paper proof goes on the paper in
            // the tray, and the trim size is an export-file concern (matching
            // iOS, whose Print path likewise doesn't take a `PageSize`).
            info.paperSize = WebRenderer.a4PageSize
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false
            info.jobDisposition = .spool
            let operation = renderer.printOperation(info)
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            operation.jobTitle = title
            // WKWebView's printing view starts with a zero frame and won't
            // size itself; without this, pagination aborts ("view's frame
            // was not initialized properly before knowsPageRange:") — the
            // same landmine `makePDF` steps over.
            operation.view?.frame = NSRect(origin: .zero, size: info.paperSize)
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

    /// Rewrite the export HTML's body margin to `pageSize`'s scaled padding, so
    /// a small trim size doesn't carry A4-sized margins. Only the *first*
    /// `padding: 48px 56px;` is touched — that is the body rule inside the
    /// head's `<style>`, which always precedes any user content, so a document
    /// that happens to quote that exact CSS in a code block is left untouched.
    /// For A4 the replacement equals the original (see `PageSize.cssPadding`),
    /// so an A4 export is byte-for-byte what it was before trim sizes existed.
    private static func styledForExport(_ html: String, pageSize: PageSize) -> String {
        guard let range = html.range(of: "padding: 48px 56px;") else { return html }
        return html.replacingCharacters(in: range, with: "padding: \(pageSize.cssPadding);")
    }

    /// Render the document to a PDF and offer it through the share picker.
    static func sharePDF(source: String, title: String, dark: Bool,
                         pageSize: PageSize = .a4) async {
        let html = styledForExport(
            MarkdownHTML.document(source, title: title, dark: dark, export: true),
            pageSize: pageSize)
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            let data = try await renderer.makePDF(title: title, pageSize: pageSize.size)
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
    static func exportPDF(source: String, title: String, dark: Bool,
                          pageSize: PageSize = .a4) async {
        let html = styledForExport(
            MarkdownHTML.document(source, title: title, dark: dark, export: true),
            pageSize: pageSize)
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            let data = try await renderer.makePDF(title: title, pageSize: pageSize.size)
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

    // MARK: - Self-contained HTML

    /// KaTeX's stylesheet with its web fonts embedded, ready to be dropped
    /// into an exported page — or nil if the bundle is missing it.
    ///
    /// A formula is not glyphs alone: `katex.min.css` positions every piece of
    /// it, so an export that dropped the stylesheet would show the right
    /// characters in the wrong places. It cannot be linked either, since the
    /// file has to stand on its own — so it is inlined, and each `@font-face`
    /// keeps only its **woff2** source, rewritten as a `data:` URI. woff2 is
    /// the one format every browser that matters reads; carrying the `woff`
    /// and `ttf` alternates as well would quadruple the payload for nothing,
    /// and leaving them as relative paths would leave dead links in the file.
    /// Twenty faces, about 300 KB before encoding.
    static func embeddedKatexCSS() -> String? {
        guard let root = Bundle.main.resourceURL,
              var css = try? String(contentsOf: root.appendingPathComponent("rich/katex.min.css"),
                                    encoding: .utf8) else { return nil }

        let fonts = root.appendingPathComponent("rich/fonts")
        let pattern = #"src:url\(fonts/([A-Za-z0-9_-]+)\.woff2\) format\("woff2"\)[^;}]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        // Back-to-front, so each replacement leaves the earlier ranges valid.
        let ns = css as NSString
        for match in regex.matches(in: css, range: NSRange(location: 0, length: ns.length)).reversed() {
            let face = ns.substring(with: match.range(at: 1))
            guard let data = try? Data(contentsOf: fonts.appendingPathComponent("\(face).woff2")) else {
                continue  // leave the rule alone rather than emit a broken src
            }
            let src = "src:url(data:font/woff2;base64,\(data.base64EncodedString())) format(\"woff2\")"
            css = (css as NSString).replacingCharacters(in: match.range, with: src)
        }
        return css
    }

    /// The notice that has to travel with an exported page carrying KaTeX's
    /// stylesheet and fonts. The code is MIT; the faces are **not** — they are
    /// SIL Open Font License 1.1 with reserved names, and the OFL requires its
    /// notice to accompany the fonts wherever they go. Exporting is the first
    /// thing md does that hands those files to somebody else, so this is the
    /// first place the obligation actually bites.
    private static let katexNotice = """
    <!--
      Mathematics rendered with KaTeX (https://katex.org) — MIT License,
      Copyright (c) 2013-2020 Khan Academy and other contributors.
      The embedded KaTeX_* fonts are licensed under the SIL Open Font
      License 1.1 (https://scripts.sil.org/OFL); "KaTeX" is a Reserved Font
      Name. The fonts are embedded unmodified.
    -->
    """

    /// The exported page itself — the whole artifact, with no UI attached, so
    /// a test can capture exactly what the user's file would contain (see
    /// `RichRenderTests`; this is the only one of the three platforms that
    /// can drive a real WebKit render in its test bundle).
    ///
    /// The diagrams are already inline SVG and the formulas already expanded
    /// by the time the page is captured (see `selfContainedHTML`), so the only
    /// thing that has to be carried across by hand is KaTeX's stylesheet, and
    /// only for a document that actually has math in it.
    static func renderedHTMLPage(source: String, title: String, dark: Bool) async throws -> String {
        // `export: true` gives the page its paper styling. The `\newpage`
        // rule is the one thing not wanted here: in export CSS it becomes
        // `break-after: page`, which is invisible on screen and only means
        // anything on paper, so a reader scrolling the file would see the
        // author's page breaks silently vanish. The screen styling keeps them
        // as the dashed rule they look like in the preview. (`document`
        // forces the light theme under `export`, so the light border is the
        // right one whatever the window's appearance.)
        let html = MarkdownHTML.document(source, title: title, dark: dark, export: true)
            .replacingOccurrences(of: ".md-pagebreak { height: 0; margin: 0; break-after: page; }",
                                  with: ".md-pagebreak { border-top: 2px dashed rgba(43,38,32,0.16); margin: 1.6em 0; }")
        let renderer = WebRenderer()
        defer { withExtendedLifetime(renderer) {} }
        try await renderer.load(html: html)
        var page = try await renderer.selfContainedHTML()
        // Only a document with math pulled KaTeX in, and only that document
        // needs to carry the stylesheet and its fonts.
        if html.contains("rich/katex.min.css"), let css = embeddedKatexCSS() {
            page = page.replacingOccurrences(
                of: "</head>", with: "<style>\(css)</style>\n\(katexNotice)\n</head>")
        }
        // Mermaid's own stylesheet travels inside every diagram it drew.
        if page.contains("class=\"mermaid\"") {
            page = page.replacingOccurrences(of: "</head>", with: "\(mermaidNotice)\n</head>")
        }
        return page
    }

    /// Mermaid writes its own theme CSS into every diagram it draws, so an
    /// exported page carrying a Mermaid diagram is carrying several kilobytes
    /// of Mermaid's source text — not just generated geometry, the way
    /// Graphviz and PlantUML output is. MIT asks for its notice to go with
    /// that, so it does.
    private static let mermaidNotice = """
    <!--
      Diagrams rendered with Mermaid (https://mermaid.js.org) — MIT License,
      Copyright (c) 2014-2022 Knut Sveidqvist. The diagram SVG carries
      Mermaid's own theme stylesheet.
    -->
    """

    /// Export the rendered document as a single HTML file the reader can open
    /// anywhere — no engines, no folder of assets, no network. The sibling of
    /// `exportPDF`: same offscreen render, same save panel, only the artifact
    /// differs.
    ///
    /// Writing the file needs nothing the PDF export doesn't already have:
    /// the destination is one the user picked in an `NSSavePanel`, which the
    /// sandbox's `files.user-selected.read-write` entitlement covers.
    static func exportHTML(source: String, title: String, dark: Bool) async {
        do {
            let page = try await renderedHTMLPage(source: source, title: title, dark: dark)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.html]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "\(sanitized(title)).html"
            // Sheet on the document window when there is one; app-modal
            // otherwise (e.g. invoked from the menu bar with no key window).
            let response: NSApplication.ModalResponse
            if let window = keyWindow() {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            if response == .OK, let url = panel.url {
                try Data(page.utf8).write(to: url, options: .atomic)
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not export HTML"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - LaTeX

    /// The `.tex` file type. There is no system-declared TeX type on macOS,
    /// so one is derived from the extension and told what it really is —
    /// plain text — which is enough for the panel to append `.tex` and for
    /// the file to open in whatever the user edits LaTeX with.
    private static let texType = UTType(filenameExtension: "tex",
                                        conformingTo: .plainText) ?? .plainText

    /// Export the document as LaTeX source, saved where the user chooses.
    ///
    /// Alone among the exports this one needs neither WebKit nor a theme:
    /// `LaTeXExport` is pure string work over the same parsed blocks, and a
    /// `.tex` file has no light or dark. It is also the only export that
    /// hands the author's mathematics back *as* mathematics — the PDF, the
    /// EPUB and the print path all rasterise a formula, and the HTML
    /// re-typesets it as KaTeX. The `await` below is the save panel's; the
    /// writing itself is synchronous.
    ///
    /// The sandbox needs nothing new for it: the destination is a URL the
    /// user picked in an `NSSavePanel`, which `files.user-selected.read-write`
    /// already covers — the same grant `exportPDF` and `exportHTML` write
    /// under.
    static func exportLaTeX(source: String, title: String) async {
        await writeTeX(LaTeXExport.document(source), title: title)
    }

    /// The whole book as one `book`-class .tex — each chapter a `\chapter`,
    /// each article a `\section`, in the same reading order as the PDF
    /// compile and the EPUB.
    static func exportBookLaTeX(book: EPUBBook) async {
        await writeTeX(LaTeXExport.book(book), title: book.title)
    }

    /// Ask for a destination and write the generated source there, alerting
    /// rather than failing quietly.
    private static func writeTeX(_ text: String, title: String) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [texType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(sanitized(title)).tex"
        // Sheet on the document window when there is one; app-modal
        // otherwise (e.g. invoked from the menu bar with no key window).
        let response: NSApplication.ModalResponse
        if let window = keyWindow() {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not export LaTeX"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Diagram → SVG export

    /// A diagram produced no vector — its engine hit a syntax error or timed
    /// out, so md-init.js left the block as source text with no `<svg>`.
    private struct DiagramCaptureError: LocalizedError {
        var errorDescription: String? {
            "This diagram couldn't be captured — it may have failed to render."
        }
    }

    /// Render the document offscreen (engines and all, waiting for
    /// render-complete like the PDF / EPUB paths), pull the chosen diagram's
    /// rendered `<svg>` out of the finished DOM, wrap it as a standalone
    /// `.svg`, and save it where the user picks. `diagram` came from
    /// `DiagramSVG.diagrams(inSource:)`, so its `ordinal` is the diagram's
    /// document-order position — the same order the DOM reports the containers.
    ///
    /// `dark: false`: a `.svg` file carries no screen theme, so it is captured
    /// from the light render (Mermaid bakes its own colours into the SVG;
    /// Graphviz/PlantUML draw explicit ink). `export: true` only to keep the
    /// same page the other captures use — it changes nothing in the vector.
    ///
    /// The sandbox needs nothing new: the destination is a URL the user picked
    /// in an `NSSavePanel`, which `files.user-selected.read-write` already
    /// covers — the same grant the PDF / HTML / LaTeX exports write under.
    static func exportDiagramSVG(source: String, title: String,
                                 diagram: DiagramSVG.Diagram) async {
        let html = MarkdownHTML.document(source, title: title, dark: false, export: true)
        let renderer = WebRenderer()
        do {
            try await renderer.load(html: html)
            guard let svg = await renderer.diagramSVG(at: diagram.ordinal) else {
                throw DiagramCaptureError()
            }
            let document = DiagramSVG.standaloneDocument(fromSVG: svg)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.svg]
            panel.canCreateDirectories = true
            // Named `<doc>-<n>.svg` for the diagram's 1-based document position,
            // so several exports from one document don't collide by default.
            panel.nameFieldStringValue = "\(sanitized(title))-\(diagram.ordinal + 1).svg"
            let response: NSApplication.ModalResponse
            if let window = keyWindow() {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            if response == .OK, let url = panel.url {
                try Data(document.utf8).write(to: url, options: .atomic)
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not export SVG"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        withExtendedLifetime(renderer) {}
    }

    // MARK: - TextBundle export

    /// Export the document as a `.textbundle` and save it where the user
    /// picks. Local images the Markdown references by relative path are copied
    /// into `assets/` and their refs rewritten (see `TextBundle.exportRewriting`);
    /// refs that can't be found next to the source are left exactly as written.
    ///
    /// Assets resolve relative to the *saved* document's folder — an unsaved,
    /// never-written document has no such folder, so it simply exports with an
    /// empty `assets/` and every ref left untouched. No WebKit and only a
    /// handful of small file reads; the `await` is the save panel's alone.
    ///
    /// The sandbox needs nothing new: the destination is a URL the user picked
    /// in an `NSSavePanel` (`files.user-selected.read-write`), and the images
    /// read from beside the document are covered by that document's own grant,
    /// taken under its security scope in `readAsset`.
    static func exportTextBundle(source: String, fileURL: URL?, title: String) async {
        let rewrite = TextBundle.exportRewriting(source: source) { relativePath in
            readAsset(relativePath, besideDocumentAt: fileURL)
        }
        let wrapper = TextBundle.bundleWrapper(text: rewrite.text, assets: rewrite.assets)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.textBundle]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(sanitized(title)).textbundle"
        let response: NSApplication.ModalResponse
        if let window = keyWindow() {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        do {
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not export TextBundle"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Read an image the document references by relative path, if it sits
    /// beside the (saved) document. The resolved path is constrained to the
    /// document's own folder — a `../…` ref that would climb out is treated as
    /// not found (and so left untouched), the same containment the preview's
    /// asset scheme handler enforces, so an export never reaches for a file
    /// outside the document's directory.
    ///
    /// Symlinks are resolved before the containment check, not just `..`:
    /// `standardizedFileURL` collapses `..` but follows no links, so a symlink
    /// sitting beside the document and named to match an image ref could
    /// otherwise point anywhere on disk and pass the prefix test. Resolving
    /// both sides first means the check compares the real locations.
    private static func readAsset(_ relativePath: String, besideDocumentAt fileURL: URL?) -> Data? {
        guard let folder = fileURL?.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL else { return nil }
        let candidate = folder.appendingPathComponent(relativePath)
            .resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(folder.path + "/") else { return nil }

        // The document's own folder may be security-scoped (opened in place).
        let scoped = fileURL!.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL!.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: candidate)
    }

    // MARK: - EPUB

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

    // MARK: - EPUB export (single document)

    /// Build an EPUB 3 of the single open document (see `EPUBExport`) and save
    /// it where the user chooses — the document sibling of `exportEPUB(book:)`,
    /// offered beside Export as PDF / HTML / LaTeX.
    ///
    /// It reuses the book pipeline whole: the same stored-zip container, the
    /// same package document, the same rich-block snapshotting, and the same
    /// title-derived `dc:identifier` (so two exports of the same document land
    /// on the same identifier in a reader's library). What a lone document is
    /// *not* is a book — so there is no title-page unit, and the nav is the
    /// document's own headings rather than a chapter / article tree. The panel
    /// comes first, exactly as the book export: photographing a document's
    /// diagrams can take a while, and the user may cancel anyway. The title is
    /// resolved before the panel so the suggested file name matches it.
    ///
    /// The sandbox needs nothing new: the destination is a URL the user picked
    /// in an `NSSavePanel`, which `files.user-selected.read-write` already
    /// covers — the same grant the book EPUB and the PDF / HTML exports write
    /// under.
    static func exportDocumentEPUB(source: String, fileName: String) async {
        let title = EPUBExport.documentTitle(
            frontMatter: MarkdownParser.frontMatter(of: source), fileName: fileName)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.epub]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(sanitized(title)).epub"
        let response: NSApplication.ModalResponse
        if let window = keyWindow() {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        do {
            let data = try await EPUBExport.buildDocument(source: source, title: title)
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

/// A book read into memory for the structured exports — display names and
/// Markdown sources, in the same reading order as the PDF compile (see
/// `BookLibrary.readStructuredBook`). Named for the EPUB it was written
/// for; the LaTeX export walks the same tree.
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
    /// rich content (math / Mermaid / Graphviz / PlantUML) render once in the
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
                       identifier: EPUBExport.stableIdentifier(forTitle: book.title),
                       modified: modifiedNow())
    }

    /// Render the single open document and assemble its EPUB (see
    /// `documentEntries`). The document sibling of `build(book:)`: its rich
    /// content (math / Mermaid / Graphviz / PlantUML) is photographed by the
    /// offscreen `WebRenderer` exactly as a book article's is — engines and all
    /// — while a plain document never touches the web view.
    ///
    /// The trap this sidesteps: `build(book:)` prepends a title-page unit and
    /// counts its nav from the units past it, so suppressing that title page
    /// would leave the nav cursor pointing one file short. There is no title
    /// page here to suppress — the document is assembled directly as a single
    /// `content.xhtml` unit whose spine and nav both name it.
    @MainActor
    static func buildDocument(source: String, title: String) async throws -> Data {
        let document = MarkdownHTML.document(source, title: title, dark: false, export: true)
        var body = bodyHTML(of: document)
        var images: [(file: String, data: Data)] = []
        if containsRichContent(body) {
            // Unit index 0 — the one content file. `richSnapshots` keys its
            // PNGs on this index (images/unit-000-rich-N.png), which resolve
            // relative to content.xhtml just as a book article's images do.
            let rich = try await richSnapshots(document: document, unit: 0)
            body = replacingRichElements(in: body, with: rich.tags)
            images = rich.images
        }
        let entries = documentEntries(title: title, body: xhtmlBody(body), images: images,
                                      outline: MarkdownParser.outline(source),
                                      modified: modifiedNow())
        // Same stored-zip container as `archive`; the pure `documentEntries`
        // is the seam the tests drive, so the packing runs through one list.
        var zip = EPUBZipWriter()
        for entry in entries { zip.add(entry.name, entry.data) }
        return zip.finish()
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

    /// The EPUB title for a single document: the front-matter `title:` field
    /// if the author gave a non-empty one, else the file name.
    ///
    /// A book takes its title from its folder name; a lone document has no
    /// folder, so the file name is the closest thing to a title it has — and
    /// the title is also what `stableIdentifier` hashes, so two exports of the
    /// same document (same front matter, same file name) reach the same
    /// identifier. The key match is case-insensitive because generators write
    /// `title:` and `Title:` alike; the first non-empty one wins, matching how
    /// a duplicate key is otherwise resolved.
    static func documentTitle(frontMatter: [MetadataField], fileName: String) -> String {
        for field in frontMatter
        where field.key.caseInsensitiveCompare("title") == .orderedSame {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return fileName
    }

    /// The EPUB package entries for a single document, `mimetype` first:
    /// container, package document, nav, the shared stylesheet, the one content
    /// file (`content.xhtml`, carrying its already-rendered, rich-blocks-
    /// snapshotted body), then the snapshot images.
    ///
    /// Pure — no WebKit, no I/O — so the container shape and, above all, the
    /// nav / spine stay unit-testable. The subtlety a book export carries and a
    /// document must *not*: `build(book:)` makes its first unit a title page and
    /// counts the nav from the units past it, so naively reusing that path with
    /// the title page removed would leave the nav pointing one file short. Here
    /// there is exactly one unit — `content.xhtml` — the spine names it, and
    /// every nav entry is a heading anchor *into* it. The nav links use the slug
    /// `MarkdownParser.outline` assigns each heading, which is the same id
    /// `MarkdownHTML` gives that heading, so a nav tap lands on the right
    /// section rather than on nothing. `body` is already the XHTML-fixed body
    /// (`xhtmlBody(bodyHTML(of:))`), the same form `articleUnit` wraps.
    static func documentEntries(title: String, body: String,
                                images: [(file: String, data: Data)],
                                outline: [OutlineEntry], modified: String)
        -> [(name: String, data: Data)] {
        let contentFile = "content.xhtml"
        let unit = Unit(file: contentFile, title: title,
                        xhtml: xhtmlDocument(title: title, body: body))
        // The document's outline as the nav TOC: a flat list of heading links,
        // the way the Contents menu itself lists them, each pointing at its
        // anchor inside the single content file. Reuses the book `nav` builder
        // (entries with no children ⇒ a flat <ol>), so there is no book-tree
        // nesting to fork.
        //
        // A document with no headings has an empty outline, and a toc <nav>
        // with no list item is not valid EPUB 3. So a headingless document
        // gets a single entry — the whole document, under its title, linking
        // to the content file itself — spec-valid and sensible for a reader.
        // (Android already guarded this; the two Apple copies did not.)
        let navEntries = outline.isEmpty
            ? [NavEntry(title: title, file: contentFile)]
            : outline.map { NavEntry(title: $0.text, file: "\(contentFile)#\($0.slug)") }
        let opfString = opf(title: title, identifier: stableIdentifier(forTitle: title),
                            modified: modified, units: [unit.file], images: images.map(\.file))
        var out: [(name: String, data: Data)] = [
            ("mimetype", Data(mimetype.utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/content.opf", Data(opfString.utf8)),
            ("OEBPS/nav.xhtml", Data(nav(title: title, entries: navEntries).utf8)),
            ("OEBPS/style.css", Data(stylesheet().utf8)),
            ("OEBPS/\(unit.file)", Data(unit.xhtml.utf8)),
        ]
        out += images.map { ("OEBPS/\($0.file)", $0.data) }
        return out
    }

    /// Whether the rendered markup carries anything the engines must
    /// typeset — the trigger for the web-view snapshot pass.
    ///
    /// Each test stops at the class value's closing quote, so the Graphviz
    /// container matches whatever else its tag carries: MarkdownHTML names
    /// the layout program in a `data-engine` attribute after the class
    /// (`<div class="graphviz" data-engine="neato">`).
    static func containsRichContent(_ html: String) -> Bool {
        html.contains("class=\"md-mathi\"") || html.contains("class=\"md-mathd\"")
            || html.contains("class=\"mermaid\"") || html.contains("class=\"plantuml\"")
            || html.contains("class=\"graphviz\"")
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
    ///
    /// `[^>]*` after the class attribute is what lets a Graphviz container
    /// match: its tag carries the layout program as well
    /// (`<div class="graphviz" data-engine="twopi">`), and a pattern
    /// anchored on `">` straight after the class value would match only the
    /// bare containers — leaving every DOT diagram in the book as raw
    /// source, and (worse) shifting the snapshots onto the wrong elements.
    /// Attribute values here are renderer-generated engine names, so they
    /// never contain `>`.
    static func replacingRichElements(in html: String, with tags: [String]) -> String {
        guard !tags.isEmpty, let regex = try? NSRegularExpression(
            pattern: "<(span|div|pre) class=\"(?:md-mathi|md-mathd|mermaid|plantuml|graphviz)\""
                + "[^>]*>[\\s\\S]*?</\\1>")
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
    /// A stable identifier for a book, derived from its title — an RFC 4122
    /// version 5 (name-based) UUID in the standard URL namespace.
    ///
    /// EPUB's `dc:identifier` is what a reader uses to decide whether two
    /// files are the same publication. A fresh random UUID on every export
    /// means every export is a *different* book: re-exporting after fixing a
    /// typo stacks up beside the old one in Apple Books instead of replacing
    /// it, and a store that expects a stable identifier across releases —
    /// KDP, Kobo — cannot accept the file at all. Deriving it from the title
    /// makes the same book export to the same identifier every time, on every
    /// platform, with nothing to store alongside the folder.
    ///
    /// Renaming the book does change it, which is the right answer: to a
    /// reader's library that is a different publication.
    static func stableIdentifier(forTitle title: String) -> String {
        // The URL namespace from RFC 4122 §Appendix C.
        let namespace: [UInt8] = [0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1,
                                  0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8]
        var input = Data(namespace)
        input.append(Data(title.utf8))

        var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant

        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let groups = [hex.prefix(8),
                      hex.dropFirst(8).prefix(4),
                      hex.dropFirst(12).prefix(4),
                      hex.dropFirst(16).prefix(4),
                      hex.dropFirst(20)]
        return "urn:uuid:" + groups.joined(separator: "-")
    }

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
