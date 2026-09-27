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
//  The pane also survives the death of its own web content process — see
//  `PreviewRetryPolicy`, which holds the counting, and
//  `webViewWebContentProcessDidTerminate` below, which acts on it.
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

// MARK: - Scroll sync (the preview half)

/// The JavaScript half of the Split view's scroll sync, injected per page
/// (deliberately not in the cross-platform `md-init.js`). It reports the
/// page's scroll fraction to the host (rAF-throttled), and marks
/// programmatic scrolls — the host's own sets, the navigation jumps, the
/// reload restore — with a timestamp so their echo isn't mistaken for the
/// reader's hand. Fractions are of the scrollable range: 0 = top, 1 =
/// bottom, whatever the two panes' heights.
private let scrollSyncScript = """
(function () {
    let lastProgrammatic = 0;
    function maxScroll() {
        return Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    }
    window.__mdMarkProgrammatic = function () { lastProgrammatic = Date.now(); };
    window.__mdSyncScrollTo = function (fraction) {
        lastProgrammatic = Date.now();
        window.scrollTo(0, Math.max(0, Math.min(1, fraction)) * maxScroll());
    };
    window.__mdScrollTo = function (y) {
        lastProgrammatic = Date.now();
        window.scrollTo(0, y);
    };
    let pending = false;
    window.addEventListener('scroll', function () {
        if (pending) { return; }
        pending = true;
        requestAnimationFrame(function () {
            pending = false;
            const max = maxScroll();
            window.webkit?.messageHandlers?.mdScroll?.postMessage({
                fraction: max > 0 ? window.scrollY / max : 0,
                echo: (Date.now() - lastProgrammatic) < 300
            });
        });
    }, { passive: true });
})();
"""

/// Breaks the retain cycle `WKUserContentController` → handler →
/// coordinator → web view → configuration: the controller holds its
/// message handlers strongly, so it gets this shim instead.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
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

/// The preview's recovery state for one document: the retry policy and the
/// rendered document the last pane showed. It belongs to the *document*, not
/// to the pane — `DocumentView` and `BookWorkspace` each own one and hand it
/// to every preview they build — because the pane leaves the hierarchy in
/// Edit and is rebuilt between Split and Preview. A policy kept in the pane's
/// coordinator went with it, so a preview that had given up came straight
/// back on the next visit and cost two more content-process deaths for a
/// document that had not changed (found 2026-09-27, the same defect as md for
/// iOS and md.Android).
final class PreviewRecovery {
    var retry = PreviewRetryPolicy()
    /// The last pane's document (its token and text/title/theme key). A pane
    /// built again for the same one is a mode switch, not an edit.
    var shownKey: String?
}

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
    /// Identity of the *document* being previewed. A document window shows
    /// one document for its whole life and leaves this nil; the book
    /// workspace passes the article URL, so moving the selection to another
    /// article is a fresh load — no debounce showing the old article for a
    /// beat, and no scroll position carried over from it.
    var documentToken: URL? = nil
    /// The Split view's pane link (see `ScrollSync`): the preview reports
    /// its scroll fraction there and follows the editor's.
    var scrollSync: ScrollSync? = nil
    /// The document's recovery state, owned by the caller so it outlives
    /// this pane (see `PreviewRecovery`). A preview built without one keeps
    /// its own, as before.
    var recovery: PreviewRecovery? = nil
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(recovery: recovery ?? PreviewRecovery()) }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.update(text: text, title: title, dark: colorScheme == .dark,
                                   token: documentToken)
        context.coordinator.attach(scrollSync)
        return context.coordinator.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(text: text, title: title, dark: colorScheme == .dark,
                                   token: documentToken)
        context.coordinator.attach(scrollSync)
        context.coordinator.navigate(to: navigation, onHandled: onNavigationHandled)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let webView: WKWebView
        private let assets = MdAssetSchemeHandler()
        private var loadedOnce = false
        private var lastKey: String?
        private var lastToken: URL?
        /// The title and theme the current HTML was built with — what the
        /// give-up notice is rendered with, so it lands on the same paper.
        private var lastTitle = ""
        private var lastDark = false
        private var savedScrollY: Double = 0
        /// The document's recovery state (see `PreviewRecovery`).
        let recovery: PreviewRecovery
        /// Consecutive web-content-process deaths (see `PreviewRetryPolicy`).
        /// Readable so the tests can pin which event resets it; kept on the
        /// recovery so that it outlives this coordinator.
        private(set) var retry: PreviewRetryPolicy {
            get { recovery.retry }
            set { recovery.retry = newValue }
        }
        /// True while the pane shows the give-up notice rather than the
        /// document: its own load must not be counted as a render that
        /// proves the document is fine.
        private var showingNotice = false
        private var pending: DispatchWorkItem?
        /// The last `PreviewNavigation.id` already performed (see `navigate`).
        private var lastNavigationID: UUID?
        /// The Split view's pane link, when this preview is half of one.
        private var scrollSync: ScrollSync?

        init(recovery: PreviewRecovery = PreviewRecovery()) {
            self.recovery = recovery
            let config = WKWebViewConfiguration()
            config.setURLSchemeHandler(assets, forURLScheme: MdAssetSchemeHandler.scheme)
            // The scroll-sync reporter, re-injected into every page load.
            config.userContentController.addUserScript(
                WKUserScript(source: scrollSyncScript,
                             injectionTime: .atDocumentEnd,
                             forMainFrameOnly: true))
            webView = WKWebView(frame: .zero, configuration: config)
            super.init()
            config.userContentController.add(WeakScriptMessageHandler(self), name: "mdScroll")
            // `md-init.js` posts here once every renderer has settled — see
            // `renderDidComplete`, which is where the retry count is reset.
            config.userContentController.add(WeakScriptMessageHandler(self), name: "mdRender")
            webView.navigationDelegate = self
            // Let the CSS paper colour show instead of a white flash on reload.
            webView.setValue(false, forKey: "drawsBackground")
        }

        /// (Re-)hand the sync our "follow the editor" closure — from make
        /// and update, so pane recreation always leaves the live
        /// coordinator registered.
        @MainActor func attach(_ sync: ScrollSync?) {
            scrollSync = sync
            sync?.scrollPreview = { [weak self] fraction in
                self?.webView.evaluateJavaScript("window.__mdSyncScrollTo(\(fraction))",
                                                 completionHandler: nil)
            }
        }

        /// The two things the page tells the host about: that it scrolled,
        /// and that it has finished rendering.
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            switch message.name {
            case "mdScroll": previewDidScroll(message.body)
            case "mdRender": renderDidComplete()
            default: break
            }
        }

        /// The page reported a scroll. Echoes of our own sets (and of the
        /// navigation jumps and reload restores) carry `echo: true` and go
        /// no further — only the reader's hand drives the editor.
        private func previewDidScroll(_ body: Any) {
            guard let body = body as? [String: Any],
                  (body["echo"] as? Bool) != true,
                  let fraction = body["fraction"] as? Double else { return }
            scrollSync?.previewDidScroll(to: CGFloat(fraction))
        }

        /// `md-init.js` finished: the math, the highlighting and every
        /// diagram engine have run and the page survived them. *This* is a
        /// rendered document, and the consecutive-failure count starts over.
        ///
        /// Not `didFinish`, which WebKit delivers at the main frame's load
        /// event — before `md-init.js` has started a single renderer, let
        /// alone imported the 7 MB PlantUML engine or laid a graph out.
        /// Resetting there would clear the count for the very document that
        /// is about to kill the web process, so the count could never reach
        /// `PreviewRetryPolicy.limit` and the pane would reload for ever.
        /// (Measured: the ordering is load event → `didFinish` → engines
        /// start → engines end → this.)
        ///
        /// The give-up notice renders too, and its own completion must not
        /// be taken for the document's.
        func renderDidComplete() {
            guard !showingNotice else { return }
            retry.renderDidFinish()
        }

        /// Re-render when the text, title, or theme changes. The first render
        /// loads immediately; later ones debounce so live typing in Split mode
        /// doesn't reload (and re-run the diagram engines) on every keystroke.
        /// A change of `token` — the book workspace moving to another article
        /// — also loads immediately, as a *fresh* page: the debounce would
        /// show the old article for a beat, and `reloadPreservingScroll`
        /// would carry its scroll position into the new one.
        func update(text: String, title: String, dark: Bool, token: URL? = nil) {
            let newDocument = token != lastToken
            lastToken = token
            let key = "\(dark)|\(title)|\(text)"
            guard key != lastKey || newDocument else { return }
            lastKey = key
            lastTitle = title
            lastDark = dark
            // A new pane for the document the last one showed — the writer
            // switched to Edit and back, or between Split and Preview — is
            // not an edit. If that document made the preview give up, the
            // pane shows the notice again and loads nothing else.
            let shown = "\(token?.absoluteString ?? "")|\(key)"
            let sameAsShown = shown == recovery.shownKey
            recovery.shownKey = shown
            if sameAsShown && !loadedOnce && retry.hasGivenUp {
                loadedOnce = true
                showingNotice = true
                savedScrollY = 0
                assets.html = MarkdownHTML.document(PreviewRetryPolicy.noticeSource, title: title, dark: dark)
                webView.load(URLRequest(url: MdAssetSchemeHandler.indexURL))
                return
            }
            // A different page is about to be loaded — and that load is the
            // one attempt an edit buys: a pane showing the give-up notice
            // goes back to showing the document, while the failure count
            // stands until something actually renders.
            retry.documentDidChange()
            showingNotice = false
            assets.html = MarkdownHTML.document(text, title: title, dark: dark)
            pending?.cancel()
            if !loadedOnce || newDocument {
                loadedOnce = true
                savedScrollY = 0
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
            // Marked programmatic: in Split, the editor is being jumped to
            // the same heading by its own precise request — the sync
            // relaying this scroll would drag it off by the proportional
            // approximation.
            webView.evaluateJavaScript(
                "window.__mdMarkProgrammatic?.(); document.getElementById('\(navigation.slug)')?.scrollIntoView(true)",
                completionHandler: nil)
            // Report consumption on the next turn — `navigate` runs inside
            // a SwiftUI view update, where mutating state is illegal — so
            // the owner can clear the one-shot request for good.
            if let onHandled {
                DispatchQueue.main.async { onHandled(navigation.id) }
            }
        }

        /// The web content process died and took the page with it —
        /// memory pressure, a WebKit update, or a diagram engine that ran
        /// away with it. WebKit blanks the pane and leaves it blank; this
        /// loads the same document again. A second death with no render in
        /// between is a document that kills the process every time, so md
        /// stops there and shows `PreviewRetryPolicy.noticeSource` instead
        /// of looping; a successful render starts the count over, and the
        /// next edit buys exactly one more attempt — the load `update`
        /// makes for it. There is deliberately no handler for *unresponsive*: a
        /// long PlantUML or Graphviz layout is indistinguishable from a
        /// hung process, and reloading would kill a render about to finish.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            switch retry.contentProcessDidTerminate() {
            case .reload:
                // `reload()` is not dependable on a view whose process has
                // gone; a fresh load of the same URL is. The scroll
                // position saved before the last reload still stands, so
                // the reader comes back where they were.
                pending?.cancel()
                webView.load(URLRequest(url: MdAssetSchemeHandler.indexURL))
            case .giveUp:
                pending?.cancel()
                showingNotice = true
                savedScrollY = 0
                assets.html = MarkdownHTML.document(PreviewRetryPolicy.noticeSource,
                                                    title: lastTitle, dark: lastDark)
                webView.load(URLRequest(url: MdAssetSchemeHandler.indexURL))
            case .ignore:
                break
            }
        }

        private func reloadPreservingScroll() {
            webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
                self?.savedScrollY = (value as? Double) ?? 0
                self?.webView.reload()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Deliberately *not* where the retry count is reset — the
            // renderers have not run yet (see `renderDidComplete`).
            guard savedScrollY > 0 else { return }
            // Programmatic (see the sync script): a restore must not read
            // as the reader scrolling and yank the editor around.
            webView.evaluateJavaScript("window.__mdScrollTo?.(\(savedScrollY))",
                                       completionHandler: nil)
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
