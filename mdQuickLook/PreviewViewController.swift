//
//  PreviewViewController.swift
//  mdQuickLook
//
//  md's Quick Look preview on the Mac: Space in Finder, a column view's
//  preview, a peek from any app that asks Quick Look shows a Markdown,
//  PlantUML, Graphviz or TextBundle file as md renders it — the app's own
//  `MarkdownHTML`, the app's own engines — instead of as plain text.
//
//  The extension carries only the engines a preview uses — KaTeX with its
//  fonts and mhchem, Viz.js, highlight.js and md-init.js, about 3 MB, copied
//  from md/rich at build time — because the App Sandbox does not let it read
//  the containing md.app's bundle (measured: every `rich/` read failed).
//  Mermaid and PlantUML, the other 10 MB, are never loaded (`QuickLookPage`). And it reaches no network: a content rule
//  blocks every http and https load, so a remote image in the document stays
//  a gap rather than a request made on the reader's behalf by a preview they
//  only glanced at.
//

import AppKit
import QuickLookUI
import WebKit
import os

/// What the extension did, for Console: a preview that silently falls back
/// to the system's plain-text one is otherwise indistinguishable from one
/// that was never asked.
private let log = Logger(subsystem: "me.nettrash.md", category: "quicklook")

final class PreviewViewController: NSViewController, QLPreviewingController {

    private let assets = QuickLookAssetHandler()
    private var webView: WKWebView?
    private var pending: ((Error?) -> Void)?

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 900))
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        guard let source = Self.source(of: url) else {
            log.error("no text in \(url.lastPathComponent, privacy: .public)")
            handler(CocoaError(.fileReadCorruptFile))
            return
        }
        log.notice("preview \(url.lastPathComponent, privacy: .public): \(source.utf16.count, privacy: .public) units")
        let title = url.deletingPathExtension().lastPathComponent
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        assets.html = QuickLookPage.adapt(MarkdownHTML.document(source, title: title, dark: dark))
        pending = handler

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "md.quicklook.offline",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        ) { [weak self] rules, error in
            if let error { log.error("offline rule: \(error.localizedDescription, privacy: .public)") }
            DispatchQueue.main.async { self?.show(rules: rules) }
        }
    }

    private func show(rules: WKContentRuleList?) {
        // Without the offline rule the page is not shown: a preview that
        // might reach the network is not one this extension makes.
        guard let rules else {
            finish(CocoaError(.featureUnsupported))
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(assets, forURLScheme: QuickLookAssetHandler.scheme)
        configuration.userContentController.add(rules)
        let webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        view.addSubview(webView)
        self.webView = webView
        webView.load(URLRequest(url: QuickLookAssetHandler.indexURL))
        // Quick Look should not wait on a page that never finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish(nil) }
    }

    private func finish(_ error: Error?) {
        guard let pending else { return }
        self.pending = nil
        log.notice("finished: \(error?.localizedDescription ?? "ok", privacy: .public)")
        pending(error)
    }

    /// Poll for md-init.js's `data-md-render-complete` and finish when it is
    /// set. Nothing to stop: once Quick Look has been answered — here, by
    /// the fallback, or by a failure — the poll ends with it.
    private func waitForRenderComplete(_ webView: WKWebView) {
        guard pending != nil else { return }
        webView.evaluateJavaScript("document.documentElement.getAttribute('data-md-render-complete')") {
            [weak self, weak webView] value, _ in
            guard let self, let webView else { return }
            if (value as? String) == "1" {
                log.info("render complete")
                self.finish(nil)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.waitForRenderComplete(webView) }
            }
        }
    }

    /// The Markdown a file holds: a `.textbundle` folder's `text.md`, a
    /// `.textpack`'s, or the file itself decoded as the app decodes it.
    static func source(of url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            // Lazy: only the text file is ever read, never the bundle's assets.
            guard let wrapper = try? FileWrapper(url: url, options: []) else { return nil }
            return TextBundle.textFromBundle(wrapper)?.0
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if url.pathExtension.lowercased() == "textpack" {
            return TextBundle.textFromPack(data)?.0
        }
        return PlainTextCodec.decode(data)?.text
    }
}

extension PreviewViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The document has loaded, but md-init.js may still be drawing
        // (Graphviz is asynchronous): Quick Look is told the preview is
        // ready once the page says it has settled — or, failing that, by
        // the ten-second fallback `show` set.
        waitForRenderComplete(webView)
        // What the page became, for Console — the one way to tell a drawn
        // preview from a blank one without looking at it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak webView] in
            webView?.evaluateJavaScript(
                "JSON.stringify({katex: document.querySelectorAll('.katex').length, graphviz: document.querySelectorAll('.graphviz svg').length, placeholders: document.querySelectorAll('.md-ql-diagram').length, complete: document.documentElement.getAttribute('data-md-render-complete')})"
            ) { value, _ in
                log.info("rendered: \((value as? String) ?? "?", privacy: .public)")
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { finish(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("web content process terminated")
        finish(WKError(.webContentProcessTerminated))
    }

    /// Links do nothing inside a preview: an in-page anchor scrolls, and
    /// anything else — the web, or one of the extension's own assets — is
    /// not the preview's to open.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = QuickLookPage.allowsNavigation(to: action.request.url, page: QuickLookAssetHandler.indexURL)
        decisionHandler(allowed ? .allow : .cancel)
    }
}

/// Serves the page and the extension's own copy of the light engines over a
/// private `mdassets://` origin — the app's own arrangement
/// (`MdAssetSchemeHandler`), which is what lets `md-init.js`'s module imports
/// resolve. `rich/<file>` is answered from the extension's Resources, where
/// the build phase put the engines flat.
final class QuickLookAssetHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mdassets"
    static let indexURL = URL(string: "mdassets://md/index.html")!

    var html = ""

    /// The extension's own Resources, holding the engines flat.
    private static let root: URL? = Bundle.main.resourceURL?.standardizedFileURL

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        let path = url.path
        if path.isEmpty || path == "/" || path == "/index.html" {
            respond(task, url: url, data: Data(html.utf8), mime: "text/html")
            return
        }
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        // Only `rich/`, and nothing that climbs out of it.
        guard relative.hasPrefix("rich/"), let root = Self.root else {
            respond(task, url: url, data: Data(), mime: "application/octet-stream", status: 404)
            return
        }
        let file = root.appendingPathComponent(String(relative.dropFirst("rich/".count))).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            log.error("asset not readable: \(file.path, privacy: .public)")
            respond(task, url: url, data: Data(), mime: "application/octet-stream", status: 404)
            return
        }
        respond(task, url: url, data: data, mime: Self.mime(for: file.pathExtension))
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String, status: Int = 200) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }
}
