//
//  MarkdownWebView.swift
//  md (macOS)
//
//  The live preview pane. Renders the same themed HTML that print / PDF /
//  "share rendered" produce (`MarkdownHTML.document`) inside a `WKWebView`,
//  so the preview is pixel-identical to the exported document and gains the
//  rich renderers — LaTeX math (KaTeX), Mermaid, PlantUML — that run from
//  bundled assets under `rich/`.
//
//  Everything is offline. A `WKURLSchemeHandler` serves the app HTML and the
//  bundled `rich/` assets under a private `mdassets://` origin; that real
//  origin (rather than `file://`) is what lets `md-init.js`'s ES-module
//  `import` of the PlantUML engine resolve. No network is ever touched.
//

import AppKit
import SwiftUI
import WebKit

// MARK: - Asset scheme handler

/// Serves the current preview HTML (`index.html`) and every bundled `rich/`
/// asset over the private `mdassets://` scheme. Shared verbatim with md (iOS).
final class MdAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mdassets"
    static let indexURL = URL(string: "mdassets://md/index.html")!

    /// The document HTML to serve for `index.html`. Updated then the web view
    /// is (re)loaded to show it.
    var html: String = ""

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let path = url.path

        if path.isEmpty || path == "/" || path == "/index.html" {
            respond(task, url: url, data: Data(html.utf8), mime: "text/html")
            return
        }

        // A bundled asset, e.g. /rich/plantuml.js or /rich/fonts/KaTeX_Main.woff2.
        guard let root = Bundle.main.resourceURL?.standardizedFileURL else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let fileURL = root.appendingPathComponent(rel).standardizedFileURL
        // Constrain to the bundle's resource directory — no path traversal.
        // Memory-map so serving the multi-MB engines (plantuml.js is ~7 MB)
        // doesn't read the whole file into the heap on the main thread.
        guard fileURL.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            respond(task, url: url, data: Data(), mime: "application/octet-stream", status: 404)
            return
        }
        respond(task, url: url, data: data, mime: Self.mime(for: fileURL.pathExtension))
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String, status: Int = 200) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// Correct MIME types matter: a JS module served as octet-stream is
    /// rejected by the module loader, and fonts/CSS need their real types.
    static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "html": return "text/html"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Preview navigation

/// A one-shot "scroll the preview to this heading" request (from the
/// Contents toolbar menu). SwiftUI re-sends the same value on every view
/// update, so each request carries a fresh `id`: the coordinator performs
/// every `id` exactly once — which is also what lets two consecutive jumps
/// target the same heading.
struct PreviewNavigation: Equatable {
    let id: UUID
    /// The heading's anchor slug — the same `id=` the HTML renderer gives
    /// the heading (see `MarkdownParser.slug`).
    let slug: String
}

// MARK: - SwiftUI preview

struct MarkdownWebView: NSViewRepresentable {
    let text: String
    let title: String
    /// Optional scroll request; `nil` means "no jump requested".
    var navigation: PreviewNavigation? = nil
    /// Called (on the next runloop turn) once `navigation` has been
    /// performed, so the owner can clear the request from its state. The
    /// coordinator's own dedupe (`lastNavigationID`) dies with the pane —
    /// if a performed request lingered in the owner's `@State` across a
    /// Split → Edit → Split round-trip, the recreated coordinator would
    /// replay it and scroll the preview back, unprompted.
    var onNavigationHandled: ((UUID) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.update(text: text, title: title, dark: colorScheme == .dark)
        return context.coordinator.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(text: text, title: title, dark: colorScheme == .dark)
        context.coordinator.navigate(to: navigation, onHandled: onNavigationHandled)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        private let assets = MdAssetSchemeHandler()
        private var loadedOnce = false
        private var lastKey: String?
        private var savedScrollY: Double = 0
        private var pending: DispatchWorkItem?
        /// The last `PreviewNavigation.id` already performed (see `navigate`).
        private var lastNavigationID: UUID?

        override init() {
            let config = WKWebViewConfiguration()
            config.setURLSchemeHandler(assets, forURLScheme: MdAssetSchemeHandler.scheme)
            webView = WKWebView(frame: .zero, configuration: config)
            super.init()
            webView.navigationDelegate = self
            // Let the CSS paper colour show instead of a white flash on reload.
            webView.setValue(false, forKey: "drawsBackground")
        }

        /// Re-render when the text, title, or theme changes. The first render
        /// loads immediately; later ones debounce so live typing in Split mode
        /// doesn't reload (and re-run the diagram engines) on every keystroke.
        func update(text: String, title: String, dark: Bool) {
            let key = "\(dark)|\(title)|\(text)"
            guard key != lastKey else { return }
            lastKey = key
            assets.html = MarkdownHTML.document(text, title: title, dark: dark)
            pending?.cancel()
            if !loadedOnce {
                loadedOnce = true
                webView.load(URLRequest(url: MdAssetSchemeHandler.indexURL))
            } else {
                let work = DispatchWorkItem { [weak self] in self?.reloadPreservingScroll() }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
        }

        /// Scroll the rendered document to a heading anchor — exactly once
        /// per request id. Slugs contain only letters, digits, `-` and `_`
        /// (see `MarkdownParser.slug`) — never quotes, backslashes or tag
        /// characters — so interpolating one straight into the script is
        /// safe. Optional chaining makes a stale slug (heading just deleted,
        /// reload still debouncing) a silent no-op.
        func navigate(to navigation: PreviewNavigation?, onHandled: ((UUID) -> Void)? = nil) {
            guard let navigation, navigation.id != lastNavigationID else { return }
            lastNavigationID = navigation.id
            webView.evaluateJavaScript(
                "document.getElementById('\(navigation.slug)')?.scrollIntoView(true)",
                completionHandler: nil)
            // Report consumption on the next turn — `navigate` runs inside
            // a SwiftUI view update, where mutating state is illegal — so
            // the owner can clear the one-shot request for good.
            if let onHandled {
                DispatchQueue.main.async { onHandled(navigation.id) }
            }
        }

        private func reloadPreservingScroll() {
            webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
                self?.savedScrollY = (value as? Double) ?? 0
                self?.webView.reload()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard savedScrollY > 0 else { return }
            webView.evaluateJavaScript("window.scrollTo(0, \(savedScrollY))", completionHandler: nil)
        }

        // A tapped link never *navigates* the preview itself: in-document
        // anchors scroll it, http/https open in the browser, and everything
        // else (javascript:, data:, file:, …) is simply cancelled — so a
        // malicious `[x](javascript:…)` link can't run in this
        // network-capable WebView. Internal loads/reloads are `.other` and pass.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                let url = navigationAction.request.url
                // In-document anchor hops — `[…](#section)` onto the
                // GitHub-style heading ids the renderer emits — resolve to
                // our own `mdassets://…#fragment` origin; allowing them just
                // scrolls the page (WebKit treats a fragment-only hop as
                // same-document, nothing reloads).
                if let url, url.scheme == MdAssetSchemeHandler.scheme, url.fragment != nil {
                    decisionHandler(.allow)
                    return
                }
                if let url, url.scheme == "http" || url.scheme == "https" {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
