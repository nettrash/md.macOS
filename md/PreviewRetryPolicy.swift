//
//  PreviewRetryPolicy.swift
//  md
//
//  Created by nettrash on 23/09/2026.
//
//  What the live preview does when the web content process that renders it
//  dies — memory pressure, a WebKit update, or a diagram engine that ran
//  away with the process. WebKit leaves the pane blank and does not reload
//  it; md does, once.
//
//  The policy is only the counting, kept away from `WKWebView` so it can be
//  tested: how many terminations have happened *in a row*, with no
//  successful render of the document between them. One is bad luck — load
//  the page again. Two in a row is a document that kills the process every
//  time, and reloading it a third time would loop: md stops and says so in
//  one quiet line. A successful render starts the count over — so the
//  writer is never stuck with a dead pane after fixing the diagram that
//  killed it. An edit lifts the give-up and buys exactly *one* more attempt
//  — the load the edit itself triggers — but leaves the count standing:
//  nothing has rendered, and in Split mode an edit arrives on every
//  keystroke, so an edit that zeroed the count would hand a reader typing
//  over a document that cannot render an endless supply of retries. The
//  same rule, in the same words, as md (iOS) and md (Android).
//
//  Only *termination* is counted. "Unresponsive" is deliberately not: a
//  long PlantUML or Graphviz layout looks exactly like a hung web process,
//  and reloading on it would kill a render that was about to finish. This
//  is the same distinction md (Windows) draws in `PreviewHost`, which acts
//  on `RenderProcessExited` and returns on everything else.
//

import Foundation

/// The preview's consecutive-failure counter. A value type with no view in
/// it: `MarkdownWebView.Coordinator` owns one and asks it what to do.
struct PreviewRetryPolicy: Equatable {

    /// What the pane should do about a termination.
    enum Response: Equatable {
        /// First death of this run: load the document again.
        case reload
        /// Second death in a row: stop retrying and show `noticeSource`.
        case giveUp
        /// md has already given up; do nothing at all.
        case ignore
    }

    /// How many terminations in a row md will absorb before it stops. The
    /// second one is the last: it is the one that shows the notice.
    static let limit = 2

    /// The one quiet line the pane shows once md has stopped retrying.
    /// Markdown, rendered through the ordinary document pipeline, so it
    /// arrives on the same paper in the same face as everything else and
    /// adds no markup of its own. One line, no diagnostics, no button: the
    /// next edit to the document tries again by itself.
    static let noticeSource = "*The preview stopped unexpectedly. Your document is unchanged — the next edit will try again.*"

    /// Terminations since the last successful render.
    private(set) var failures = 0

    /// True once `limit` terminations have happened in a row: the pane is
    /// showing the notice and further terminations are not retried. Stored
    /// rather than derived from `failures`, because an edit clears it while
    /// the count stands (see `documentDidChange`).
    private(set) var hasGivenUp = false

    init() {}

    /// The web content process died.
    mutating func contentProcessDidTerminate() -> Response {
        guard !hasGivenUp else { return .ignore }
        failures += 1
        guard failures >= Self.limit else { return .reload }
        hasGivenUp = true
        return .giveUp
    }

    /// A render of the *document* finished. Whatever went wrong is behind
    /// us: the next termination is a first one again. (The notice page's
    /// own load is not a render of the document and must not be reported
    /// here — it can never crash, and counting it would forget that md had
    /// given up.)
    mutating func renderDidFinish() {
        failures = 0
        hasGivenUp = false
    }

    /// The document (or the theme, or the article) changed: a different
    /// page is about to be loaded, and that load is one more attempt — the
    /// pane stops having given up, so the next death is answered again.
    /// The count stands, though: nothing rendered, and an edit that zeroed
    /// it would refill the budget on every keystroke in Split mode. A
    /// death after the edit therefore brings the line straight back.
    mutating func documentDidChange() { hasGivenUp = false }
}
