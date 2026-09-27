//
//  PreviewRetryPolicyTests.swift
//  mdTests
//
//  `PreviewRetryPolicy` — what the preview does when its web content
//  process dies. The type is pure counting, so every transition the pane
//  can make is pinned here: one death is reloaded, a second one in a row
//  gives up, a third says nothing at all, a successful render of the
//  document starts the count over, and the next edit lifts the give-up
//  and buys exactly one more attempt without touching the count — the
//  rule md (iOS) and md (Android) pin with the same two cases.
//
//  The wiring these decisions drive lives in `MarkdownWebView.Coordinator`
//  (`webViewWebContentProcessDidTerminate`, `didFinish`, `renderDidComplete`,
//  `update`): killing a real `WKWebView`'s web process is not something a
//  unit test can ask for, which is exactly why the decision is not in the
//  view.
//
//  What *can* be pinned about the wiring, and is, at the bottom of this
//  file: **which event the count is reset on**. A correct counter fed the
//  wrong event is a runaway, and the counter's own tests cannot see it —
//  `didFinish` arrives at the main frame's load event, before `md-init.js`
//  has started a single renderer, so resetting there clears the count for
//  the very document that is about to kill the web process. The reset
//  belongs on the render-complete signal the page posts once every engine
//  has run, and the last test here takes that signal from a real WebView
//  rendering a real diagram.
//

import AppKit
import WebKit
import XCTest
@testable import md

final class PreviewRetryPolicyTests: XCTestCase {

    // MARK: - The two-strike rule

    func testFirstTerminationReloads() {
        var policy = PreviewRetryPolicy()
        XCTAssertEqual(policy.failures, 0)
        XCTAssertFalse(policy.hasGivenUp)
        XCTAssertEqual(policy.contentProcessDidTerminate(), .reload)
        XCTAssertEqual(policy.failures, 1)
        XCTAssertFalse(policy.hasGivenUp, "one death is bad luck, not a verdict")
    }

    func testSecondTerminationInARowGivesUp() {
        var policy = PreviewRetryPolicy()
        XCTAssertEqual(policy.contentProcessDidTerminate(), .reload)
        XCTAssertEqual(policy.contentProcessDidTerminate(), .giveUp)
        XCTAssertTrue(policy.hasGivenUp)
        XCTAssertEqual(policy.failures, PreviewRetryPolicy.limit)
    }

    func testAfterGivingUpNothingIsRetriedAndNothingIsShownTwice() {
        var policy = PreviewRetryPolicy()
        _ = policy.contentProcessDidTerminate()
        XCTAssertEqual(policy.contentProcessDidTerminate(), .giveUp)
        // The notice is shown once. Whatever happens to the pane after
        // that, md neither reloads nor says it again.
        XCTAssertEqual(policy.contentProcessDidTerminate(), .ignore)
        XCTAssertEqual(policy.contentProcessDidTerminate(), .ignore)
        XCTAssertEqual(policy.failures, PreviewRetryPolicy.limit,
                       "an ignored death is not counted either")
    }

    // MARK: - What resets the count

    func testARenderBetweenTwoDeathsMakesThemBothFirstDeaths() {
        var policy = PreviewRetryPolicy()
        XCTAssertEqual(policy.contentProcessDidTerminate(), .reload)
        policy.renderDidFinish()
        XCTAssertEqual(policy.failures, 0)
        // Not consecutive: the reload worked, so this is bad luck again.
        XCTAssertEqual(policy.contentProcessDidTerminate(), .reload)
        XCTAssertFalse(policy.hasGivenUp)
    }

    func testARenderAfterGivingUpStartsTheCountOver() {
        var policy = PreviewRetryPolicy()
        _ = policy.contentProcessDidTerminate()
        XCTAssertEqual(policy.contentProcessDidTerminate(), .giveUp)
        policy.renderDidFinish()
        XCTAssertFalse(policy.hasGivenUp)
        XCTAssertEqual(policy.contentProcessDidTerminate(), .reload)
    }

    /// An edit takes the pane out of having given up — the notice promises
    /// exactly that — and the load it triggers is the attempt. It does not
    /// put the count back to zero: only a page that finished rendering is
    /// evidence that the document can be rendered at all, so a death after
    /// the edit brings the line straight back instead of starting a fresh
    /// pair of reloads. In Split mode this arrives on every keystroke.
    func testEditingTheDocumentTakesThePolicyOutOfGivingUpButBuysOneAttempt() {
        var policy = PreviewRetryPolicy()
        _ = policy.contentProcessDidTerminate()
        XCTAssertEqual(policy.contentProcessDidTerminate(), .giveUp)
        XCTAssertTrue(policy.hasGivenUp)
        // Fix the diagram that was killing the process and the pane comes
        // back by itself — no button, no relaunch.
        policy.documentDidChange()
        XCTAssertFalse(policy.hasGivenUp)
        XCTAssertEqual(policy.failures, PreviewRetryPolicy.limit,
                       "nothing rendered, so the run of failures still stands")
        // …but if that load dies too, it is the line again, not a reload.
        XCTAssertEqual(policy.contentProcessDidTerminate(), .giveUp)
        XCTAssertTrue(policy.hasGivenUp)
    }

    /// Typing does not buy an unbounded retry: however many keystrokes land
    /// between two deaths, the second is still the second.
    func testKeystrokesCannotRefillTheRetryBudget() {
        var policy = PreviewRetryPolicy()
        XCTAssertEqual(policy.contentProcessDidTerminate(), .reload)
        for _ in 0..<50 { policy.documentDidChange() }
        XCTAssertEqual(policy.failures, 1)
        XCTAssertEqual(policy.contentProcessDidTerminate(), .giveUp)
    }

    func testResettingAnUntroubledPolicyChangesNothing() {
        var policy = PreviewRetryPolicy()
        policy.renderDidFinish()
        policy.documentDidChange()
        XCTAssertEqual(policy, PreviewRetryPolicy())
    }

    // MARK: - A full run

    func testTheWholeSequenceADocumentThatKillsTheProcessEveryTime() {
        var policy = PreviewRetryPolicy()
        // Open it: dead, reload.
        XCTAssertEqual(policy.contentProcessDidTerminate(), .reload)
        // Dead again on the reload: stop, one line.
        XCTAssertEqual(policy.contentProcessDidTerminate(), .giveUp)
        // The pane sits on the notice; nothing loops.
        XCTAssertEqual(policy.contentProcessDidTerminate(), .ignore)
        // The writer edits the offending diagram: the edit's own load is
        // the one attempt this buys.
        policy.documentDidChange()
        XCTAssertFalse(policy.hasGivenUp)
        // …and this time it renders.
        policy.renderDidFinish()
        XCTAssertEqual(policy, PreviewRetryPolicy(), "back where it started")
    }

    // MARK: - The pane feeds the counter the right event

    /// A completed *navigation* is not a rendered document. WebKit delivers
    /// `didFinish` at the main frame's load event; `md-init.js` only starts
    /// the renderers on that same event, and then awaits Mermaid, Graphviz
    /// and a 7 MB dynamic import before anything is laid out. The document
    /// the policy exists for — one whose diagram runs the layout engine out
    /// of room — dies strictly after `didFinish`.
    @MainActor
    func testACompletedNavigationDoesNotCountAsARenderedDocument() {
        let coordinator = MarkdownWebView.Coordinator()
        let delegate: WKNavigationDelegate = coordinator

        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        XCTAssertEqual(coordinator.retry.failures, 1)

        delegate.webView?(coordinator.webView, didFinish: nil)
        XCTAssertEqual(coordinator.retry.failures, 1,
                       "the page loaded, but no engine has run yet")

        coordinator.renderDidComplete()
        XCTAssertEqual(coordinator.retry.failures, 0,
                       "a finished render is what proves the document is survivable")
    }

    /// The runaway the policy was written to prevent, expressed as the pane
    /// actually experiences it: load, navigation completes, engines run,
    /// process dies — twice. The second death has to be the last.
    @MainActor
    func testTwoDeathsAfterCompletedNavigationsGiveUpInsteadOfLoopingForEver() {
        let coordinator = MarkdownWebView.Coordinator()
        let delegate: WKNavigationDelegate = coordinator

        delegate.webView?(coordinator.webView, didFinish: nil)
        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        XCTAssertFalse(coordinator.retry.hasGivenUp, "one death is bad luck")

        // The reload's navigation completes — and the same diagram kills it
        // again on the way out.
        delegate.webView?(coordinator.webView, didFinish: nil)
        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        XCTAssertTrue(coordinator.retry.hasGivenUp,
                      "the pane would reload for ever and never show the notice")
    }

    /// The give-up notice renders like any other page and posts the same
    /// completion signal; taking it for the document's own render would
    /// make md forget it had given up.
    @MainActor
    func testTheNoticesOwnRenderDoesNotClearTheCount() {
        let coordinator = MarkdownWebView.Coordinator()
        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        XCTAssertTrue(coordinator.retry.hasGivenUp)

        coordinator.renderDidComplete()
        XCTAssertTrue(coordinator.retry.hasGivenUp,
                      "the notice page reported itself as the document")

        // The next edit is what brings the pane back.
        coordinator.update(text: "fixed", title: "t", dark: false)
        XCTAssertFalse(coordinator.retry.hasGivenUp)
    }

    /// End to end: the signal the reset now hangs on really does arrive,
    /// from the real preview page, over the real message handler, after a
    /// real diagram engine has run. A reset that no message ever reaches
    /// would look exactly like a healthy pane until the day the process
    /// died twice.
    @MainActor
    func testTheRealPreviewPageReportsItsRenderToTheCoordinator() async throws {
        let coordinator = MarkdownWebView.Coordinator()
        // Off-screen host window: the layout engines need the web view to
        // actually lay out (the same reason `RichRenderTests` parks one).
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = coordinator.webView
        window.orderBack(nil)
        defer { window.contentView = nil }

        coordinator.update(text: "```dot\ndigraph G { a -> b; }\n```", title: "retry", dark: false)
        // A death before the first render: the count is 1 and the pane has
        // reloaded the same document.
        coordinator.webViewWebContentProcessDidTerminate(coordinator.webView)
        XCTAssertEqual(coordinator.retry.failures, 1)

        let deadline = Date().addingTimeInterval(40)
        while coordinator.retry.failures > 0, Date() < deadline {
            await Task.yield()
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(coordinator.retry.failures, 0,
                       "the page's render-complete signal never reached the coordinator")
    }

    // MARK: - The notice

    func testTheNoticeIsOneQuietLine() {
        let notice = PreviewRetryPolicy.noticeSource
        XCTAssertFalse(notice.isEmpty)
        XCTAssertFalse(notice.contains("\n"), "one line, not a paragraph")
        XCTAssertFalse(notice.contains("\r"))
        // Markdown, not HTML: it is rendered by the same pipeline as the
        // document, so it can carry no markup the renderer does not own.
        XCTAssertFalse(notice.contains("<"))
        XCTAssertFalse(notice.contains(">"))
    }

    func testTheNoticeRendersAsAPlainPageWithNoEngines() {
        // The give-up page is built with `MarkdownHTML.document`, like any
        // other preview. It must not drag in the very engines that may
        // have killed the web process in the first place.
        let html = MarkdownHTML.document(PreviewRetryPolicy.noticeSource,
                                         title: "Untitled", dark: false)
        XCTAssertTrue(html.contains("The preview stopped unexpectedly"))
        // The emphasis is real markup, so the line arrives rendered rather
        // than as a row of asterisks.
        XCTAssertTrue(html.contains("<em>"))
        for engine in ["rich/katex.min.js", "rich/katex.min.css", "rich/mhchem.min.js",
                       "rich/mermaid.min.js", "rich/viz-global.js", "rich/highlight.min.js"] {
            XCTAssertFalse(html.contains(engine),
                           "the notice page pulled in \(engine)")
        }
    }

    /// Edit, then Preview again: a *new* pane — a new coordinator — over the
    /// same document's recovery. It must come back to the notice, not to a
    /// fresh attempt; before 2026-09-27 every mode switch started over.
    func testAGiveUpSurvivesANewPaneForTheSameDocument() {
        let recovery = PreviewRecovery()
        let first = MarkdownWebView.Coordinator(recovery: recovery)
        first.update(text: "# Hello", title: "Hello", dark: false)
        first.webViewWebContentProcessDidTerminate(first.webView)
        first.webViewWebContentProcessDidTerminate(first.webView)
        XCTAssertTrue(recovery.retry.hasGivenUp)

        let again = MarkdownWebView.Coordinator(recovery: recovery)
        again.update(text: "# Hello", title: "Hello", dark: false)
        XCTAssertTrue(again.retry.hasGivenUp, "the same document is no change")

        again.update(text: "# Hello, edited", title: "Hello", dark: false)
        XCTAssertFalse(again.retry.hasGivenUp, "an edit lifts it")
        XCTAssertEqual(again.retry.failures, PreviewRetryPolicy.limit, "one attempt, not a fresh budget")
    }
}
