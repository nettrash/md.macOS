//
//  BookNavigator.swift
//  md
//
//  Created by nettrash on 08/07/2026.
//
//  Writer mode. A "book" is nothing more than a folder the writer picks —
//  its subfolders are chapters, and the Markdown (.md / .markdown / .txt)
//  files inside are articles. The book window (`Window("Book")` in
//  `mdApp`) is the writing workspace: a split view with the book's
//  structure in a compact sidebar, in reading order, and the selected
//  article edited *in place* in the detail pane — Edit / Split / Preview,
//  like a document window (the in-place machinery lives in
//  `BookWorkspace.swift`). Full screen turns it into the distraction-free
//  writing mode: nothing on screen but the book. For writers who prefer
//  the old way, a share-menu toggle ("Open Articles in Separate Windows")
//  makes selection open document windows instead, and a double-click or
//  the context menu always can.
//
//  Reading order: names with a leading integer prefix ("01-intro",
//  "2. setup") come first, sorted by that number; everything else follows
//  alphabetically (Finder-style, case-insensitive). Numbering files is the
//  age-old convention for ordering a manuscript, and it needs no sidecar
//  metadata polluting the user's folder.
//
//  Sandbox: the app holds only user-selected access, and that dies with
//  the process — so the chosen folder is persisted as a security-scoped
//  bookmark (base64 in UserDefaults) and every directory listing or file
//  creation runs between start/stopAccessingSecurityScopedResource on the
//  book root.
//
//  Management is right-click, the Mac idiom: every chapter and article row
//  carries a context menu with Rename…, Move Up / Move Down and Delete….
//  A move materializes the new order by renumbering the whole sibling
//  group with zero-padded prefixes ("01-", "02-", …) — explicit names on
//  disk, still no sidecar metadata. Rename edits only the display name;
//  the ordering prefix and file extension survive.
//
//  The window's share menu compiles the whole book — a title page, then
//  every chapter heading and article on its own page — into one Markdown
//  source (see `BookLibrary.compile`) and hands it to the same PDF
//  pipeline a document export uses; Export as EPUB… and Export as LaTeX…
//  walk the same reading order with its structure intact instead (see
//  `EPUBExport` and `LaTeXExport`), so a chapter stays a chapter.
//

import SwiftUI
import AppKit

// MARK: - Model

/// One article — a Markdown file in the book. Identity is the file URL.
struct BookArticle: Identifiable {
    let url: URL
    var id: URL { url }
    /// Display name: the file name without its extension.
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// One chapter — a direct subfolder of the book, with its articles already
/// in reading order.
struct BookChapter: Identifiable {
    let url: URL
    let articles: [BookArticle]
    var id: URL { url }
    /// Folders show their full name — a dot in a folder name is part of the
    /// name, not a file format to hide.
    var name: String { url.lastPathComponent }
}

/// A snapshot of the book as listed from disk. Rebuilt wholesale after
/// every change — two levels of directory listing are cheap, and a snapshot
/// avoids holding live file-system state outside the sandbox scope.
struct Book {
    let root: URL
    /// Top-level articles, shown before any chapter.
    let articles: [BookArticle]
    let chapters: [BookChapter]
    var name: String { root.lastPathComponent }
}

// MARK: - Library (bookmark persistence + disk access)

/// Everything about *where* the book lives: choosing the folder, keeping
/// access to it across launches, listing it, and creating, renaming,
/// reordering and deleting the chapters and articles inside it. UI-free
/// (bar the shared failure alert), so the File-menu commands in `mdApp`,
/// the Book toolbar menu in `DocumentView` and the navigator window all
/// share one implementation.
enum BookLibrary {

    /// The navigator's `Window` scene id (see `mdApp`).
    static let windowID = "book"

    /// UserDefaults key holding the book folder's security-scoped bookmark,
    /// base64-encoded (UserDefaults + `@AppStorage` speak String more
    /// naturally than Data). Views observe it via `@AppStorage`, so opening
    /// or closing a book from any window refreshes every other one.
    static let bookmarkKey = "md.bookBookmark"

    /// File extensions treated as articles — the same set of plain-text
    /// types the document side reads.
    static let articleExtensions: Set<String> = ["md", "markdown", "txt"]

    // MARK: Choosing / closing

    /// Create a brand-new book folder and remember it. Returns true when
    /// the folder was created and bookmarked (callers then show the
    /// navigator). One native step — a save panel — names the folder *and*
    /// places it, instead of an open panel followed by a name prompt.
    static func newBook() -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "My Book"
        panel.prompt = "Create"
        panel.canCreateDirectories = true
        panel.message = "Name your book and choose where to keep it. Chapters are folders inside it; articles are Markdown files."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try FileManager.default.createDirectory(at: url,
                                                    withIntermediateDirectories: false)
        } catch {
            // No silent failures (same convention as the export alerts):
            // the writer asked for a folder and needs to know why there
            // isn't one — it may already exist, or the volume be read-only.
            presentError("Could not create book", informative: error.localizedDescription)
            return false
        }
        // A save-panel URL carries the powerbox's sandbox grant for the
        // item created at it — read-write, same as user-selected — so the
        // security-scoped bookmark can be minted straight from the fresh
        // folder, exactly as it is for a folder picked in `chooseBook`.
        return store(url)
    }

    /// Unpack the bundled example book (see `ExampleLibrary`): ask where to
    /// put it — the same one-step save panel as `newBook` — copy the folder
    /// tree there, and remember it as the open book. Returns true when the
    /// copy landed and was bookmarked (callers then show the navigator).
    static func unpackExampleBook() -> Bool {
        let source = Bundle.main.url(forResource: "Example Book",
                                     withExtension: nil,
                                     subdirectory: "Examples")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Example Book"
        panel.prompt = "Unpack"
        panel.canCreateDirectories = true
        panel.message = "Choose where to keep the example book. It is an ordinary book folder — chapters inside, Markdown articles in each — yours to edit."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            // A bundled resource only goes missing on a corrupt install,
            // but the writer still asked for a book — report it like any
            // other failure rather than doing nothing.
            guard let source else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.copyItem(at: source, to: url)
        } catch {
            // No silent failures, same convention as `newBook`: a folder
            // with that name may already exist, or the volume be read-only.
            presentError("Could not unpack example book", informative: error.localizedDescription)
            return false
        }
        // The save-panel grant covers the copied folder just as it covers
        // the one `newBook` creates — bookmark it the same way.
        return store(url)
    }

    /// Ask the writer for a book folder and remember it. Returns true when
    /// a folder was picked and bookmarked (callers then show the navigator).
    static func chooseBook() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Book"
        panel.message = "Choose a folder to open as a book. Its subfolders are chapters; its Markdown files are articles."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return store(url)
    }

    /// Forget the book. The folder itself is untouched.
    static func closeBook() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    /// Persist the folder as a security-scoped bookmark — the only way a
    /// sandboxed app can reopen a user-picked folder after a relaunch.
    private static func store(_ url: URL) -> Bool {
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return false }
        UserDefaults.standard.set(data.base64EncodedString(), forKey: bookmarkKey)
        return true
    }

    /// The modal warning every failed book file-operation shows — the same
    /// "no silent failures" convention as the export alerts. Internal so
    /// the workspace session (`BookArticleSession`) reports its failures
    /// through the same door.
    static func presentError(_ message: String, informative: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informative
        alert.runModal()
    }

    // MARK: Scoped access

    /// Resolve the stored bookmark and *start the security scope* on the
    /// book root. Callers must balance every non-nil return with
    /// `endAccess`. Returns nil when no book is stored, the bookmark no
    /// longer resolves (folder deleted, permission revoked), or the scope
    /// is refused.
    static func beginAccess() -> URL? {
        guard let base64 = UserDefaults.standard.string(forKey: bookmarkKey),
              let data = Data(base64Encoded: base64) else { return nil }
        var stale = false
        guard let root = try? URL(resolvingBookmarkData: data,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) else { return nil }
        guard root.startAccessingSecurityScopedResource() else { return nil }
        if stale {
            // Still resolved, but the system wants the bookmark re-minted
            // (folder moved, bookmark format rotated, …). Re-creating it
            // requires the scope we just started; if it fails the old data
            // keeps working for now, so ignore the result.
            _ = store(root)
        }
        return root
    }

    static func endAccess(_ root: URL) {
        root.stopAccessingSecurityScopedResource()
    }

    // MARK: Listing

    /// List the book from disk — one level of chapters, per the model.
    /// Runs entirely under the root's security scope.
    static func loadBook() -> Book? {
        guard let root = beginAccess() else { return nil }
        defer { endAccess(root) }
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(at: root,
                                                    includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles]) else { return nil }
        var articles: [BookArticle] = []
        var chapters: [BookChapter] = []
        for url in top {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                let inner = (try? fm.contentsOfDirectory(at: url,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
                let chapterArticles = inner
                    .filter { articleExtensions.contains($0.pathExtension.lowercased()) }
                    .map { BookArticle(url: $0) }
                    .sorted { ordered($0.name, $1.name) }
                chapters.append(BookChapter(url: url, articles: chapterArticles))
            } else if articleExtensions.contains(url.pathExtension.lowercased()) {
                articles.append(BookArticle(url: url))
            }
        }
        return Book(root: root,
                    articles: articles.sorted { ordered($0.name, $1.name) },
                    chapters: chapters.sorted { ordered($0.name, $1.name) })
    }

    // MARK: Creation

    /// Create a chapter folder at the top level of the book. Fails quietly
    /// (the navigator simply shows no new row) — the folder may already
    /// exist or the name may be unusable, and Finder is the recovery tool.
    static func createChapter(named name: String) -> Bool {
        guard let root = beginAccess() else { return false }
        defer { endAccess(root) }
        let url = root.appendingPathComponent(name, isDirectory: true)
        return (try? FileManager.default.createDirectory(at: url,
                                                         withIntermediateDirectories: false)) != nil
    }

    /// Create "<name>.md" inside `folder` (the book root or a chapter),
    /// seeded with a matching level-1 heading so the new article renders
    /// sensibly the moment it opens. Never overwrites an existing file.
    /// Returns the created file's URL — the workspace selects it so the
    /// writer lands straight in the fresh article. `folder` must lie
    /// inside the book — its access rights come from the root scope
    /// started here.
    static func createArticle(named name: String, in folder: URL) -> URL? {
        guard let root = beginAccess() else { return nil }
        defer { endAccess(root) }
        let url = folder.appendingPathComponent(name).appendingPathExtension("md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try? Data("# \(name)\n".utf8).write(to: url)) != nil else { return nil }
        return url
    }

    // MARK: Managing (rename / reorder / delete)

    /// A sibling name split into its article extension (when it has one)
    /// and the rest. Only the extensions treated as articles count — a dot
    /// in a chapter (folder) name is part of the name, not a format.
    private static func splitExtension(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
              articleExtensions.contains(name[name.index(after: dot)...].lowercased())
        else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// A base name split into its ordering prefix — the leading number and
    /// its trailing separators ("01-", "2. ") — and the display stem. An
    /// all-number name keeps the number as its stem: there would be nothing
    /// left to display otherwise.
    private static func splitPrefix(_ base: String) -> (prefix: String, stem: String) {
        let digits = base.prefix(while: { $0.isASCII && $0.isNumber })
        var index = digits.endIndex
        while index < base.endIndex, "-.) ".contains(base[index]) { index = base.index(after: index) }
        guard !digits.isEmpty, index < base.endIndex else { return ("", base) }
        return (String(base[..<index]), String(base[index...]))
    }

    /// The name as the writer reads it: ordering prefix and article
    /// extension stripped — what the Rename prompt shows and edits.
    static func displayName(_ name: String) -> String {
        splitPrefix(splitExtension(name).base).stem
    }

    /// The sibling name after a rename to the display name `stem`: the
    /// ordering prefix and the extension survive untouched
    /// ("01-Draft.md" + "Final" → "01-Final.md"). Pure — the disk work
    /// lives in `renameItem`.
    static func renamedName(_ name: String, toDisplayName stem: String) -> String {
        let (base, ext) = splitExtension(name)
        return splitPrefix(base).prefix + stem + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// Rename the article or chapter at `url` to the display name `stem`.
    /// Empty and path-hostile names are rejected; collisions (an item with
    /// the resulting name already exists) surface via the shared alert.
    static func renameItem(at url: URL, toDisplayName stem: String) -> Bool {
        guard !stem.isEmpty else { return false }
        guard !stem.contains("/"), !stem.contains(":") else {
            presentError("Could not rename",
                         informative: "A name cannot contain \"/\" or \":\".")
            return false
        }
        let newName = renamedName(url.lastPathComponent, toDisplayName: stem)
        guard newName != url.lastPathComponent else { return true }
        guard let root = beginAccess() else { return false }
        defer { endAccess(root) }
        do {
            try FileManager.default.moveItem(
                at: url,
                to: url.deletingLastPathComponent().appendingPathComponent(newName))
            return true
        } catch {
            presentError("Could not rename", informative: error.localizedDescription)
            return false
        }
    }

    /// Delete the article (a file) or chapter (a folder, recursively) at
    /// `url`. Asking first is the caller's job; failures alert.
    static func deleteItem(at url: URL) -> Bool {
        guard let root = beginAccess() else { return false }
        defer { endAccess(root) }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            presentError("Could not delete", informative: error.localizedDescription)
            return false
        }
    }

    /// Pure planning for Move Up / Move Down: the sibling names in
    /// displayed order plus the requested move, in; the renames (old name →
    /// new name) that materialize the new order on disk, out. Every sibling
    /// ends up with a zero-padded two-digit prefix ("01-", "02-", …) — so
    /// unprefixed names gain one and loose prefixes ("2. ") are normalized
    /// — while display names and extensions survive. Impossible moves plan
    /// nothing. Names only, no I/O: the logic stays testable and the
    /// sandbox discipline stays in `applyRenames`.
    static func renumberPlan(_ names: [String], moving from: Int, to: Int) -> [(from: String, to: String)] {
        guard names.indices.contains(from), names.indices.contains(to), from != to else { return [] }
        var reordered = names
        reordered.insert(reordered.remove(at: from), at: to)
        return reordered.enumerated().compactMap { index, name -> (from: String, to: String)? in
            let (base, ext) = splitExtension(name)
            let renamed = String(format: "%02d-", index + 1) + splitPrefix(base).stem
                + (ext.isEmpty ? "" : ".\(ext)")
            return renamed == name ? nil : (from: name, to: renamed)
        }
    }

    /// Carry out a rename plan inside `folder` (the book root or a
    /// chapter). Two-phase — everything is staged under a hidden temporary
    /// name first — so plans that trade names between siblings
    /// ("01-a" ↔ "02-a") never collide midway, and a failure rolls the
    /// staged items back to their original names. `folder` must lie inside
    /// the book — its access rights come from the root scope started here.
    static func applyRenames(_ plan: [(from: String, to: String)], in folder: URL) -> Bool {
        guard !plan.isEmpty else { return true }
        guard let root = beginAccess() else { return false }
        defer { endAccess(root) }
        let fm = FileManager.default
        var staged: [(temp: URL, to: URL, original: URL)] = []
        do {
            for pair in plan {
                let original = folder.appendingPathComponent(pair.from)
                let temp = folder.appendingPathComponent(".md-reorder-\(UUID().uuidString)")
                try fm.moveItem(at: original, to: temp)
                staged.append((temp, folder.appendingPathComponent(pair.to), original))
            }
            for item in staged { try fm.moveItem(at: item.temp, to: item.to) }
            return true
        } catch {
            // Best effort: nothing may be left hidden under a temporary
            // name, so put whatever was staged back where it came from.
            for item in staged { try? fm.moveItem(at: item.temp, to: item.original) }
            presentError("Could not reorder", informative: error.localizedDescription)
            return false
        }
    }

    /// The whole book flattened into reading order — the top-level
    /// articles (the front matter), then each chapter's articles. This is
    /// the sequence Previous / Next Article steps through, and the same
    /// order the PDF compile and the EPUB use.
    static func readingOrder(of book: Book) -> [BookArticle] {
        book.articles + book.chapters.flatMap(\.articles)
    }

    /// Where `url` ends up after `plan` renames siblings inside `folder` —
    /// the item itself may be renamed, or one of its ancestors (an article
    /// inside a renamed chapter). URLs outside `folder`, and names the
    /// plan doesn't touch, come back unchanged. Pure, so the workspace's
    /// selection-remapping is testable without touching a disk.
    static func destination(of url: URL, afterRenamesIn folder: URL,
                            plan: [(from: String, to: String)]) -> URL {
        let folderPath = folder.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        guard urlPath.hasPrefix(folderPath + "/") else { return url }
        var components = urlPath.dropFirst(folderPath.count + 1)
            .split(separator: "/").map(String.init)
        guard let first = components.first,
              let renamed = plan.first(where: { $0.from == first })?.to else { return url }
        components[0] = renamed
        return components.reduce(folder.standardizedFileURL) { $0.appendingPathComponent($1) }
    }

    // MARK: Compilation (the whole book as one document)

    /// One already-read piece of the book, in reading order.
    enum Part {
        /// A chapter boundary — becomes a heading on its own page.
        case chapter(name: String)
        /// An article's Markdown source, verbatim.
        case article(text: String)
    }

    /// Compile the book into a single Markdown source: a title page, then
    /// every part on a page of its own — `\newpage` between them, the same
    /// marker the export pipeline splits pages on. Chapter headings get
    /// their own page before their articles; article text is untouched (a
    /// `---` inside stays an ordinary rule). Pure — strings in, string out
    /// — so the shape is testable; the file reading lives in
    /// `compileBookSource`.
    static func compile(bookName: String, parts: [Part]) -> String {
        var sections = ["# \(bookName)"]
        for part in parts {
            switch part {
            case .chapter(let name): sections.append("# \(name)")
            case .article(let text): sections.append(text)
            }
        }
        return sections.joined(separator: "\n\n\\newpage\n\n")
    }

    /// Read the open book in reading order — root articles first, then
    /// each chapter — and compile it (see `compile`). The title is the
    /// book folder's display name, which also names the exported PDF.
    /// Returns nil after alerting when there is no book or an article
    /// cannot be read.
    static func compileBookSource() -> (title: String, source: String)? {
        guard let book = loadBook(), let root = beginAccess() else {
            presentError("Could not compile book",
                         informative: "No book is open, or the book folder is not accessible.")
            return nil
        }
        defer { endAccess(root) }
        var parts: [Part] = []
        func append(_ article: BookArticle) -> Bool {
            guard let text = readArticle(article.url) else {
                presentError("Could not compile book",
                             informative: "The article \"\(article.name)\" could not be read.")
                return false
            }
            parts.append(.article(text: text))
            return true
        }
        for article in book.articles {
            guard append(article) else { return nil }
        }
        for chapter in book.chapters {
            parts.append(.chapter(name: displayName(chapter.name)))
            for article in chapter.articles {
                guard append(article) else { return nil }
            }
        }
        let title = displayName(book.root.lastPathComponent)
        return (title, compile(bookName: title, parts: parts))
    }

    /// An article's text, decoded the way the document side would: UTF-8
    /// first, then Latin-1 — which maps every byte, so a compile does not
    /// die on one legacy-encoded file.
    private static func readArticle(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Read the open book in structure — display names and sources in the
    /// same reading order as the PDF compile, but with the chapter and
    /// article boundaries kept rather than flattened into one stream.
    ///
    /// Both structured exports want exactly this: the EPUB gives every
    /// article and chapter heading its own file (see `EPUBExport`), and the
    /// `.tex` turns the same boundaries into `\chapter` and `\section`.
    /// `failure` is the export naming itself in the alert, since the reader
    /// is the only thing that can tell the user *which* article it could not
    /// read. Returns nil after alerting when there is no book or an article
    /// cannot be read.
    static func readStructuredBook(failure: String) -> EPUBBook? {
        guard let book = loadBook(), let root = beginAccess() else {
            presentError(failure,
                         informative: "No book is open, or the book folder is not accessible.")
            return nil
        }
        defer { endAccess(root) }
        func read(_ article: BookArticle) -> EPUBBook.Article? {
            guard let text = readArticle(article.url) else {
                presentError(failure,
                             informative: "The article \"\(article.name)\" could not be read.")
                return nil
            }
            return EPUBBook.Article(name: displayName(article.url.lastPathComponent),
                                    markdown: text)
        }
        var articles: [EPUBBook.Article] = []
        for article in book.articles {
            guard let read = read(article) else { return nil }
            articles.append(read)
        }
        var chapters: [EPUBBook.Chapter] = []
        for chapter in book.chapters {
            var chapterArticles: [EPUBBook.Article] = []
            for article in chapter.articles {
                guard let read = read(article) else { return nil }
                chapterArticles.append(read)
            }
            chapters.append(EPUBBook.Chapter(name: displayName(chapter.name),
                                             articles: chapterArticles))
        }
        return EPUBBook(title: displayName(book.root.lastPathComponent),
                        articles: articles, chapters: chapters)
    }

    // MARK: Ordering

    /// Reading order for sibling names: anything with a leading integer
    /// sorts first, by that number ("2. setup" before "10-ending"); ties
    /// and everything else fall back to Finder-style alphabetical
    /// (`localizedStandardCompare`, which is case-insensitive).
    static func ordered(_ a: String, _ b: String) -> Bool {
        switch (leadingNumber(a), leadingNumber(b)) {
        case let (x?, y?) where x != y: return x < y
        case (.some, .none): return true
        case (.none, .some): return false
        default: return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// The integer prefix of a name, if any ("01-intro" → 1). ASCII digits
    /// only — the numbering convention, not Unicode numerals — and a run
    /// long enough to overflow `Int` counts as not numbered rather than
    /// trapping.
    private static func leadingNumber(_ name: String) -> Int? {
        let digits = name.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }
}

// MARK: - Book output (share / export / print the whole book)

/// The whole-book output actions — compile the book and hand it to the
/// same output paths as a document. App-wide, like the book itself: they
/// serve the File menu (from any window, whenever a book is open) and the
/// book window's share menu alike. Every action first asks the in-place
/// editor to save (see `BookFlushGate`), so the page the writer is looking
/// at is the page that ships; a failed save aborts — its notice is already
/// on the book window's screen. The compiled output renders through the
/// export pipeline, which is always light-on-white, so no appearance needs
/// capturing here.
@MainActor
enum BookOutput {

    /// Save the in-place editor's buffer, if any window holds one.
    private static func flushEditor() -> Bool {
        let gate = BookFlushGate()
        NotificationCenter.default.post(name: BookFlushGate.request, object: gate)
        return !gate.vetoed
    }

    /// The title page, chapter headings and articles in reading order —
    /// each starting a fresh page — through the share picker. `pageSize` is
    /// the caller's remembered trim choice (see `PageSize`): the book compile
    /// is the surface that needs it most — no print-on-demand service accepts
    /// A4 interiors.
    static func sharePDF(pageSize: PageSize = .a4) {
        guard flushEditor(), let compiled = BookLibrary.compileBookSource() else { return }
        Task { await DocumentExport.sharePDF(source: compiled.source,
                                             title: compiled.title, dark: false,
                                             pageSize: pageSize) }
    }

    /// The same compile, saved where the user chooses as "<book>.pdf".
    static func exportPDF(pageSize: PageSize = .a4) {
        guard flushEditor(), let compiled = BookLibrary.compileBookSource() else { return }
        Task { await DocumentExport.exportPDF(source: compiled.source,
                                              title: compiled.title, dark: false,
                                              pageSize: pageSize) }
    }

    /// The same compile, straight to the print panel.
    static func printBook() {
        guard flushEditor(), let compiled = BookLibrary.compileBookSource() else { return }
        Task { await DocumentExport.print(source: compiled.source,
                                          title: compiled.title, dark: false) }
    }

    /// The book as an EPUB 3 (see `EPUBExport`) — same reading order as
    /// the PDF compile, saved where the user chooses as "<book>.epub".
    static func exportEPUB() {
        guard flushEditor(),
              let book = BookLibrary.readStructuredBook(failure: "Could not export EPUB")
        else { return }
        Task { await DocumentExport.exportEPUB(book: book) }
    }

    /// The book as one `book`-class .tex — each chapter a `\chapter`, each
    /// article a `\section`, in the same reading order as the PDF compile
    /// and the EPUB. It reads the book the EPUB's way rather than the PDF's
    /// because the structure has to survive: the compiled PDF source is one
    /// flat Markdown stream, which is exactly the chapter and article
    /// boundaries `\chapter` and `\section` are made of.
    static func exportLaTeX() {
        guard flushEditor(),
              let book = BookLibrary.readStructuredBook(failure: "Could not export LaTeX")
        else { return }
        Task { await DocumentExport.exportBookLaTeX(book: book) }
    }
}

// MARK: - Book window (structure sidebar + in-place writing pane)

struct BookNavigator: View {
    /// The stored bookmark, observed so this window refreshes itself
    /// whenever *any* window opens or closes a book — the value change
    /// flows through UserDefaults.
    @AppStorage(BookLibrary.bookmarkKey) private var storedBookmark = ""
    /// The legacy behavior, kept as a choice: selecting an article opens
    /// it in its own document window instead of editing it in place.
    @AppStorage("md.bookOpensInSeparateWindows") private var opensInSeparateWindows = false
    /// The last article written in, as a path relative to the book root —
    /// relative, because the root travels behind a security-scoped
    /// bookmark that keeps resolving after the folder moves. Restored when
    /// the window opens, so the writer resumes mid-book, not at a blank
    /// pane.
    @AppStorage("md.bookLastArticle") private var lastArticlePath = ""
    /// The workspace's Edit / Split / Preview mode. App storage, not scene
    /// storage: there is exactly one book window, and the writer's chosen
    /// layout should survive a relaunch.
    ///
    /// Deliberately **one** mode for the whole book, and deliberately not the
    /// per-file memory a document window keeps (`md.viewModeMemory`, see
    /// `ViewMode.swift`): stepping ⌃⌘↓ through chapters must not keep changing
    /// the layout under a writer, least of all flipping them into Preview on
    /// the chapter they were about to write. The two stores stay disjoint —
    /// this window never writes a per-file entry.
    @AppStorage("md.bookViewMode") private var storedMode = DocumentView.Mode.split.rawValue

    /// The pane a navigation jump has brought on screen, if one has.
    ///
    /// Not persisted, and deliberately not `storedMode`. `md.bookViewMode` is
    /// `@AppStorage`, i.e. one app-wide setting for the whole book, so writing
    /// a jump into it meant that reading a single note permanently changed the
    /// layout the book comes back in — a worse version of the same mistake the
    /// document window made per file. A jump moves you; it is not a choice of
    /// layout, and only a deliberate pick is remembered.
    @State private var navigationMode: DocumentView.Mode?
    /// The trim size the book's PDF compile paginates to — A5 for a booklet,
    /// 6×9"/5×8"/5.5×8.5" for a print-on-demand paperback interior. One
    /// app-wide choice (the same `md.pdfPageSize` key the document share menu
    /// reads), remembered across launches; stored as the stable `PageSize.id`,
    /// which `PageSize.named` maps back and defaults to A4.
    @AppStorage("md.pdfPageSize") private var pdfPageSizeID = PageSize.a4.id
    @Environment(\.openDocument) private var openDocument
    /// Captured so a compiled book's PDF matches this window's appearance,
    /// exactly as a document export matches its window's.
    @Environment(\.colorScheme) private var colorScheme

    /// The one article being edited in place (see `BookWorkspace.swift`).
    @StateObject private var session = BookArticleSession()

    /// The current disk snapshot; nil shows the "no book" placeholder.
    @State private var book: Book?
    /// The sidebar's selected article. Side effects (loading it into the
    /// session, or opening a window in legacy mode) run in `onChange`.
    @State private var selection: URL?

    /// One-shot navigation requests for the panes, bumped by the Contents
    /// / Notes toolbar menus — same request-by-id idiom as `DocumentView`.
    @State private var previewNavigation: PreviewNavigation?
    @State private var editorJump: EditorJump?

    /// The article's counters, outline and notes — one cached scan shared
    /// by the footer, the toolbar menus and the Go menu, recomputed once
    /// per typing pause instead of inside every `body` pass (see
    /// `DerivedText`).
    @State private var derived = DerivedText()

    // Creation prompts — one name field each; a new article also remembers
    // which section's button was clicked, i.e. its destination folder.
    @State private var isNamingChapter = false
    @State private var chapterName = ""
    @State private var isNamingArticle = false
    @State private var articleName = ""
    @State private var articleFolder: URL?

    // Management prompts (the rows' context menus). Rename pre-fills the
    // display name — the ordering prefix and extension survive the rename —
    // and delete asks first, naming the item it is about to remove.
    @State private var isRenaming = false
    @State private var renameName = ""
    @State private var renameURL: URL?
    @State private var isConfirmingDelete = false
    @State private var deleteURL: URL?
    @State private var deleteName = ""
    @State private var deleteIsChapter = false

    /// The book's remembered layout — the preference, ignoring any jump.
    private var preferredMode: DocumentView.Mode { .init(rawValue: storedMode) ?? .split }

    /// The layout actually on screen: a navigation jump overrides the
    /// preference for as long as it lasts, without recording anything.
    private var mode: DocumentView.Mode {
        ViewModeRule.displayedMode(preferred: preferredMode, navigation: navigationMode, isWide: true)
    }

    /// Every deliberate pick goes through here, and clears the jump: choosing
    /// a layout ends the detour and is what gets remembered.
    private func select(_ mode: DocumentView.Mode) {
        navigationMode = nil
        storedMode = mode.rawValue
    }

    private var modeBinding: Binding<DocumentView.Mode> {
        Binding(get: { mode }, set: { select($0) })
    }

    var body: some View {
        Group {
            if let book {
                workspace(for: book)
            } else {
                emptyState
                    .background(Typewriter.paper.ignoresSafeArea())
                    .frame(minWidth: 260, minHeight: 320)
            }
        }
        .navigationTitle(book?.name ?? "Book")
        .navigationSubtitle(session.title)
        // Full screen IS this workspace's distraction-free writing mode —
        // the window must be able to enter it.
        .fullScreenCapable()
        .onAppear {
            session.openBook()
            reload()
            // The window can reopen with its selection state intact (the
            // scene outlives the window) while the session starts empty —
            // and a same-value selection write never fires onChange. Run
            // the side effects by hand; selectionChanged is idempotent.
            selectionChanged(selection)
        }
        // The window closing is the session's last chance to save and to
        // release the held security scope.
        .onDisappear {
            session.closeBook()
        }
        .onChange(of: storedBookmark) {
            // A different book (or none): tear the session down around the
            // old scope before touching the new bookmark.
            let previous = selection
            selection = nil
            session.closeBook()
            session.openBook()
            reload()
            // All of the above runs in one SwiftUI transaction: if the new
            // book restores the same selection value, onChange(of:
            // selection) sees no net change and never fires — reattach by
            // hand (see performManaged).
            if selection == previous { selectionChanged(selection) }
        }
        .onChange(of: selection) { _, url in
            selectionChanged(url)
        }
        // One derived-text scan per typing pause (or article switch) — the
        // restarted task cancels the sleeping one.
        .task(id: session.text) {
            derived = await derived.refreshed(from: session.text)
        }
        .alert("New Chapter", isPresented: $isNamingChapter) {
            TextField("Name", text: $chapterName)
            Button("Create") { createChapter() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A chapter is a folder. Start the name with a number (\"02 …\") to place it in the reading order.")
        }
        .alert("New Article", isPresented: $isNamingArticle) {
            TextField("Name", text: $articleName)
            Button("Create") { createArticle() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A Markdown file is created, started with a matching heading.")
        }
        .alert("Rename", isPresented: $isRenaming) {
            TextField("Name", text: $renameName)
            Button("Rename") { performRename() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the name changes — the ordering number and the file extension are kept.")
        }
        .alert("Delete \"\(deleteName)\"?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteIsChapter
                 ? "The chapter folder and every article in it will be deleted."
                 : "The article file will be deleted.")
        }
    }

    // MARK: Workspace (the split view)

    /// The writing workspace: the book's structure in a compact sidebar,
    /// the selected article front and center. The window's native full
    /// screen (the green button, ⌃⌘F) turns this into the distraction-free
    /// writing mode — nothing on screen but the book.
    private func workspace(for book: Book) -> some View {
        NavigationSplitView {
            sidebar(for: book)
                // Enough for article names; never a rival to the writing
                // area.
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail(for: book)
        }
        .frame(minWidth: 700, minHeight: 400)
    }

    // MARK: Sidebar (structure)

    private func sidebar(for book: Book) -> some View {
        // Top-level articles first — the book's front matter — then the
        // chapters, each as its own section. Chapter headers carry the
        // same management menu as the rows; a chapter's sibling group
        // is the book's chapter list, renumbered inside the root.
        List(selection: $selection) {
            Section {
                articleRows(book.articles)
                newArticleButton(in: book.root)
            }
            ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                Section {
                    articleRows(chapter.articles)
                    newArticleButton(in: chapter.url)
                } header: {
                    Text(chapter.name)
                        .contextMenu {
                            managementMenu(for: chapter.url, named: chapter.name,
                                           isChapter: true, index: index,
                                           of: book.chapters.map(\.name),
                                           in: book.root)
                        }
                }
            }
        }
        // Let the sidebar's native material show instead of the default
        // list background.
        .scrollContentBackground(.hidden)
        // The rows' menu and double-click, at the List level — the row's
        // selection value comes in as `urls`. Attaching a TapGesture to the
        // rows instead would race the table's own mouseDown: every click
        // waits out the double-click window and clicks on the label can be
        // swallowed whole, which read as "slow, and some articles don't
        // select". `primaryAction` IS the native double-click.
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first, let context = articleContext(of: url) {
                Button("Open in New Window") { openInWindow(url) }
                Divider()
                managementMenu(for: url, named: context.name,
                               isChapter: false, index: context.index,
                               of: context.siblings, in: context.folder)
            }
        } primaryAction: { urls in
            // Double-click: this article in its own window — the one-gesture
            // road to the old behavior.
            if let url = urls.first { openInWindow(url) }
        }
        .toolbar {
            // Lives over the column it acts on; it collapsing along with
            // the sidebar is the idiom, not a bug.
            ToolbarItem {
                Button {
                    chapterName = ""
                    isNamingChapter = true
                } label: {
                    Label("New Chapter…", systemImage: "folder.badge.plus")
                }
                .help("Create a new chapter folder in the book")
            }
        }
    }

    /// The rows for one sibling group of articles — the unit Move Up /
    /// Move Down reorder within. Plain tagged labels and nothing else:
    /// selection is the List's (a `Button` row — or any tap gesture — would
    /// swallow the click); the menu and double-click live on the List (see
    /// `sidebar`).
    private func articleRows(_ articles: [BookArticle]) -> some View {
        ForEach(articles) { article in
            Label(article.name, systemImage: "doc.text")
                .font(Typewriter.font(13))
                .tag(article.url)
        }
    }

    /// The sidebar context of an article URL — display name, folder, and
    /// position among its siblings, everything the management menu needs —
    /// recovered from the book snapshot, since the List-level context menu
    /// only hands over the row's selection value.
    private func articleContext(of url: URL)
        -> (name: String, folder: URL, siblings: [String], index: Int)? {
        guard let book else { return nil }
        let path = url.standardizedFileURL.path
        func context(in articles: [BookArticle], folder: URL)
            -> (name: String, folder: URL, siblings: [String], index: Int)? {
            guard let index = articles.firstIndex(where: {
                $0.url.standardizedFileURL.path == path
            }) else { return nil }
            return (articles[index].name, folder,
                    articles.map { $0.url.lastPathComponent }, index)
        }
        if let hit = context(in: book.articles, folder: book.root) { return hit }
        for chapter in book.chapters {
            if let hit = context(in: chapter.articles, folder: chapter.url) { return hit }
        }
        return nil
    }

    // MARK: Detail (the writing pane)

    @ViewBuilder
    private func detail(for book: Book) -> some View {
        Group {
            switch session.stage {
            case .empty:
                detailPlaceholder(icon: "square.and.pencil", title: "Select an Article",
                                  message: "Choose an article in the sidebar to write here. ⌃⌘↑ and ⌃⌘↓ move through the book in reading order.")
            case .editing:
                BookArticleEditor(session: session,
                                  derived: derived,
                                  previewNavigation: $previewNavigation,
                                  editorJump: $editorJump,
                                  navigationMode: navigationMode)
                    // Hand the article to the menu bar — File ▸ Print… and
                    // the Share commands — exactly as a document window
                    // does. No fileURL: "Share Source…" should offer a
                    // copy, not the live file the book is standing on.
                    .focusedSceneValue(\.activeDocument,
                                       ActiveDocument(text: session.text,
                                                      title: session.title,
                                                      fileURL: nil,
                                                      dark: colorScheme == .dark))
                    // …the mode switch, for the View-menu ⌘1/⌘2/⌘3…
                    .focusedSceneValue(\.viewModeSelection,
                                       ViewModeSelection(mode: mode,
                                                         select: { select($0) }))
                    // …and the article's outline and notes, for the Go
                    // menu — same navigation as the toolbar menus.
                    .focusedSceneValue(\.documentNavigation,
                                       DocumentNavigation(outline: derived.outline,
                                                          notes: derived.notes,
                                                          jumpToHeading: { jump(to: $0) },
                                                          jumpToNote: { jump(to: $0) }))
            case .handoff:
                VStack(spacing: 12) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Open in Its Own Window")
                        .font(Typewriter.font(17))
                    Text("\u{201C}\(session.title)\u{201D} is open as a document window, and that window owns the file while it stays open. Close it to write here again.")
                        .font(Typewriter.font(12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Show Window") { session.showOwningWindow() }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unreadable:
                detailPlaceholder(icon: "exclamationmark.triangle", title: "Could Not Read the Article",
                                  message: "\u{201C}\(session.title)\u{201D} could not be read. It may have been moved or deleted outside the book.")
            }
        }
        .background(Typewriter.paper.ignoresSafeArea())
        // Previous / Next Article, for the menu bar (⌃⌘↑ / ⌃⌘↓) — see
        // `DocumentCommands`.
        .focusedSceneValue(\.bookArticleStepper, stepper(for: book))
        .toolbar { detailToolbar }
    }

    private func detailPlaceholder(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(Typewriter.font(17))
            Text(message)
                .font(Typewriter.font(12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Detail toolbar

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        // The same mode switch as a document window. Not `.principal` —
        // inside a split view that placement fights the column layout.
        ToolbarItem {
            Picker("View Mode", selection: modeBinding) {
                ForEach(DocumentView.Mode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .disabled(session.editingURL == nil)
            .help("Switch between editing, split and preview")
        }

        // Walking the book without leaving the keyboard's reach: the menu
        // commands carry the shortcuts; these are the mouse affordance.
        ToolbarItem {
            let stepper = book.map(stepper(for:))
            ControlGroup {
                Button {
                    stepper?.previous()
                } label: {
                    Label("Previous Article", systemImage: "chevron.up")
                }
                .disabled(stepper?.canPrevious != true)
                .help("The previous article in reading order (⌃⌘↑)")
                Button {
                    stepper?.next()
                } label: {
                    Label("Next Article", systemImage: "chevron.down")
                }
                .disabled(stepper?.canNext != true)
                .help("The next article in reading order (⌃⌘↓)")
            }
        }

        // Contents / Notes for the article being written — the same
        // navigation a document window has, off the shared derived-text
        // cache rather than a parse per toolbar refresh.
        ToolbarItem {
            Menu {
                ForEach(derived.outline, id: \.line) { entry in
                    Button {
                        jump(to: entry)
                    } label: {
                        Text(String(repeating: "  ", count: max(0, entry.level - 1)) + entry.text)
                    }
                }
            } label: {
                Label("Contents", systemImage: "list.bullet")
            }
            .menuIndicator(.hidden)
            .disabled(session.editingURL == nil || derived.outline.isEmpty)
            .help("Jump to a heading")
        }
        ToolbarItem {
            Menu {
                ForEach(derived.notes, id: \.line) { note in
                    Button {
                        jump(to: note)
                    } label: {
                        Text(DocumentView.notePreview(note.text))
                    }
                }
            } label: {
                Label("Notes", systemImage: "note.text")
            }
            .menuIndicator(.hidden)
            .disabled(session.editingURL == nil || derived.notes.isEmpty)
            .help("Jump to a private author note")
        }

        // Compile the whole book to a PDF, an EPUB or paper — the same
        // actions the File menu carries (see `BookOutput`), plus the
        // menu's one behavior setting at its bottom.
        ToolbarItem {
            Menu {
                Button {
                    BookOutput.sharePDF(pageSize: PageSize.named(pdfPageSizeID))
                } label: {
                    Label("Share as PDF", systemImage: "doc.richtext")
                }
                Button {
                    BookOutput.exportPDF(pageSize: PageSize.named(pdfPageSizeID))
                } label: {
                    Label("Export as PDF…", systemImage: "square.and.arrow.down")
                }
                // The trim size the two PDF compiles use — a booklet (A5) or a
                // print-on-demand paperback (6×9", …) instead of A4. A Picker
                // in a menu is the submenu size-picker idiom; the choice is
                // remembered and shared with the document share menu.
                Picker(selection: $pdfPageSizeID) {
                    ForEach(PageSize.all) { size in
                        Text(size.label).tag(size.id)
                    }
                } label: {
                    Label("PDF Page Size", systemImage: "rectangle.portrait")
                }
                Divider()
                Button {
                    BookOutput.exportEPUB()
                } label: {
                    Label("Export as EPUB…", systemImage: "book.closed")
                }
                Button {
                    BookOutput.exportLaTeX()
                } label: {
                    Label("Export as LaTeX…", systemImage: "function")
                }
                Divider()
                Button {
                    BookOutput.printBook()
                } label: {
                    Label("Print…", systemImage: "printer")
                }
                Divider()
                Toggle("Open Articles in Separate Windows", isOn: $opensInSeparateWindows)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .help("Compile the whole book into a PDF, an EPUB, or print it")
        }
    }

    // MARK: Article navigation (Previous / Next, Contents, Notes)

    /// The Previous / Next state and actions for the current selection,
    /// published to the menu bar and mirrored by the toolbar chevrons.
    /// Disabled wholesale in the separate-windows mode: with no persistent
    /// selection there is no "current" article to step from — each press
    /// would just reopen the first one.
    private func stepper(for book: Book) -> BookArticleStepper {
        guard !opensInSeparateWindows else {
            return BookArticleStepper(canPrevious: false, canNext: false,
                                      previous: {}, next: {})
        }
        let order = BookLibrary.readingOrder(of: book).map(\.url)
        let index = orderIndex(of: selection, in: order)
        return BookArticleStepper(
            canPrevious: index.map { $0 > 0 } ?? !order.isEmpty,
            canNext: index.map { $0 < order.count - 1 } ?? !order.isEmpty,
            previous: { step(-1) },
            next: { step(1) })
    }

    /// Move the selection through the book's reading order. With nothing
    /// selected, Next enters the book from the front and Previous from
    /// the back.
    private func step(_ delta: Int) {
        guard let book else { return }
        let order = BookLibrary.readingOrder(of: book).map(\.url)
        guard !order.isEmpty else { return }
        guard let index = orderIndex(of: selection, in: order) else {
            selection = delta > 0 ? order.first : order.last
            return
        }
        let target = index + delta
        guard order.indices.contains(target) else { return }
        selection = order[target]
    }

    /// `url`'s position in `order`, compared on standardized paths — URL
    /// equality is representation-sensitive, and the selection and the
    /// listing needn't spell a path identically.
    private func orderIndex(of url: URL?, in order: [URL]) -> Int? {
        guard let path = url?.standardizedFileURL.path else { return nil }
        return order.firstIndex { $0.standardizedFileURL.path == path }
    }

    /// Jump to a heading: whichever panes are visible follow it (same
    /// rules as a document window).
    private func jump(to entry: OutlineEntry) {
        if mode != .edit {
            previewNavigation = PreviewNavigation(id: UUID(), slug: entry.slug)
        }
        if mode != .preview {
            editorJump = EditorJump(id: UUID(), line: entry.line)
        }
    }

    /// Jump to a note. Notes never render, so the target is always the
    /// editor — leaving preview-only mode first when necessary.
    private func jump(to note: NoteEntry) {
        // A jump, not a preference: bring the editor on screen without touching
        // the book's remembered layout. See `navigationMode`.
        if let nudge = ViewModeRule.navigationNudge(displayed: mode, wants: .edit) {
            navigationMode = nudge
        }
        editorJump = EditorJump(id: UUID(), line: note.line)
    }

    /// The Rename / Move / Delete menu shared by article rows and chapter
    /// headers. `siblings` are the group's file names in displayed order —
    /// exactly what `BookLibrary.renumberPlan` reorders — and `folder` is
    /// the directory they live in.
    @ViewBuilder
    private func managementMenu(for url: URL, named name: String, isChapter: Bool,
                                index: Int, of siblings: [String], in folder: URL) -> some View {
        Button("Rename…") {
            renameURL = url
            renameName = BookLibrary.displayName(url.lastPathComponent)
            isRenaming = true
        }
        Button("Move Up") { move(index, to: index - 1, of: siblings, in: folder) }
            .disabled(index == 0)
        Button("Move Down") { move(index, to: index + 1, of: siblings, in: folder) }
            .disabled(index == siblings.count - 1)
        Divider()
        Button("Delete…", role: .destructive) {
            deleteURL = url
            deleteName = name
            deleteIsChapter = isChapter
            isConfirmingDelete = true
        }
    }

    private func newArticleButton(in folder: URL) -> some View {
        Button {
            articleName = ""
            articleFolder = folder
            isNamingArticle = true
        } label: {
            Label("New Article…", systemImage: "plus")
                .font(Typewriter.font(12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No Book Open")
                .font(Typewriter.font(17))
            Text("A book is a folder: its subfolders are chapters and its Markdown files are articles.")
                .font(Typewriter.font(12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Book…") {
                // The bookmark write flips `storedBookmark`, which reloads
                // this window — no direct state handoff needed.
                _ = BookLibrary.chooseBook()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Selection

    /// The selection's side effects, run once per change. In the default
    /// mode the article loads into the in-place session; in the legacy
    /// mode the selection is only a gesture — the article opens as its own
    /// window and the highlight clears.
    private func selectionChanged(_ url: URL?) {
        // A performed jump belongs to the article it was aimed at; never
        // let one replay into the next article's panes.
        previewNavigation = nil
        editorJump = nil
        guard let url else {
            if !session.select(nil) {
                // The flush failed: keep the writer on the unsaved article
                // (its footer is showing the error) instead of abandoning
                // the buffer.
                selection = session.editingURL
            }
            return
        }
        if opensInSeparateWindows {
            selection = nil
            openInWindow(url)
            return
        }
        if session.select(url) {
            lastArticlePath = relativePath(of: url)
        } else {
            selection = session.editingURL
        }
    }

    /// `url` relative to the book root — the durable form of "where I was
    /// writing".
    private func relativePath(of url: URL) -> String {
        guard let book else { return "" }
        let rootPath = book.root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : ""
    }

    /// Open an article as a regular document window (the legacy click, the
    /// context menu, a double-click). If it is the article being edited in
    /// place, the session saves and steps aside first — the new window
    /// must never race the session for the file. The open itself runs
    /// under the book root's security scope; once the document
    /// architecture has the file open it maintains access on its own, so
    /// the scope ends right after.
    ///
    /// The window it opens is a plain document window — so it would pick up
    /// per-file view-mode memory through the ordinary `DocumentView` path
    /// unless told not to, and it is told not to: book articles are exempt
    /// from that memory on all three ports, one mode per book, whichever
    /// window an article is read in. `BookArticleOpens.mark` is the marker
    /// the landing window claims (see `ViewMode.swift`); the iPhone port
    /// marks the same way, one line before `DocumentSceneOpener.open`.
    ///
    /// What the reader sees here barely changes — a Mac window is always
    /// wide, so an unknown article resolved to Split, which is also the
    /// default an exempt window keeps. What changes is that a book of two
    /// hundred chapters can no longer evict a reader's real documents from
    /// a two-hundred-entry list, and that the three apps now agree.
    private func openInWindow(_ url: URL) {
        if session.editingURL?.standardizedFileURL.path == url.standardizedFileURL.path {
            guard session.handOffForExternalOpen() else { return }
        }
        BookArticleOpens.mark(url)
        Task {
            guard let root = BookLibrary.beginAccess() else { return }
            defer { BookLibrary.endAccess(root) }
            try? await openDocument(at: url)
        }
    }

    // MARK: Actions

    /// Re-list the book from disk and re-point the selection. Cheap by
    /// design, so every mutation just calls this instead of patching the
    /// snapshot in place. Selection, in order of preference: the caller's
    /// `preferred` URL (where a rename / move / create just put things),
    /// the current selection when it still exists, the remembered
    /// last-written article, the first article of the book.
    private func reload(preferring preferred: URL? = nil) {
        book = BookLibrary.loadBook()
        guard let book else {
            selection = nil
            return
        }
        // In the separate-windows mode the sidebar is a launcher, not a
        // selection: restoring (or auto-selecting) anything would fling
        // open document windows nobody asked for.
        guard !opensInSeparateWindows else {
            selection = nil
            return
        }
        let order = BookLibrary.readingOrder(of: book).map(\.url)
        func existing(_ url: URL?) -> URL? {
            orderIndex(of: url, in: order).map { order[$0] }
        }
        if let target = existing(preferred) {
            selection = target
        } else if let current = existing(selection) {
            if current != selection { selection = current }
        } else {
            let remembered = lastArticlePath.isEmpty
                ? nil : existing(book.root.appendingPathComponent(lastArticlePath))
            selection = remembered ?? order.first
        }
    }

    /// Run one file operation safely around the in-place editor: save and
    /// release the edited article first (aborting the operation if the
    /// save fails — the writer's buffer outranks any management action),
    /// then reload with the operation's preferred selection. The operation
    /// receives the pre-operation selection so it can remap it through
    /// whatever it renamed.
    private func performManaged(_ operation: (URL?) -> URL?) {
        let previous = selection
        guard session.select(nil) else { return }
        selection = nil
        reload(preferring: operation(previous))
        // Everything above runs in one SwiftUI transaction, so when the
        // net selection value is unchanged — the operation touched some
        // *other* item — onChange(of: selection) never fires and the
        // detached session would stay a blank pane under a highlighted
        // row. Run the reattach side effects by hand; selectionChanged is
        // idempotent for a selection the session already edits.
        if selection == previous { selectionChanged(selection) }
    }

    private func createChapter() {
        let name = chapterName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        _ = BookLibrary.createChapter(named: name)
        reload()
    }

    private func createArticle() {
        let name = articleName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let folder = articleFolder else { return }
        performManaged { previous in
            // Land the writer in the fresh article; on failure stay put.
            BookLibrary.createArticle(named: name, in: folder) ?? previous
        }
    }

    /// Swap the item with its displayed neighbour and materialize the new
    /// order on disk (see `BookLibrary.renumberPlan`). Impossible moves are
    /// disabled in the menu; the plan's range guard makes them no-ops
    /// regardless. The selection follows the renames — its own, or its
    /// chapter's.
    private func move(_ from: Int, to: Int, of siblings: [String], in folder: URL) {
        performManaged { previous in
            let plan = BookLibrary.renumberPlan(siblings, moving: from, to: to)
            guard BookLibrary.applyRenames(plan, in: folder) else { return previous }
            guard let previous else { return nil }
            return BookLibrary.destination(of: previous, afterRenamesIn: folder, plan: plan)
        }
    }

    /// An empty name is a cancel in spirit — quietly ignored, like the
    /// creation prompts; everything else `BookLibrary.renameItem` vets.
    private func performRename() {
        let stem = renameName.trimmingCharacters(in: .whitespaces)
        guard !stem.isEmpty, let url = renameURL else { return }
        performManaged { previous in
            guard BookLibrary.renameItem(at: url, toDisplayName: stem) else { return previous }
            guard let previous else { return nil }
            // Follow the selection through the rename — the renamed item
            // itself, or an article inside a renamed chapter.
            let plan = [(from: url.lastPathComponent,
                         to: BookLibrary.renamedName(url.lastPathComponent, toDisplayName: stem))]
            return BookLibrary.destination(of: previous,
                                           afterRenamesIn: url.deletingLastPathComponent(),
                                           plan: plan)
        }
    }

    private func performDelete() {
        guard let url = deleteURL else { return }
        performManaged { previous in
            // Pick the reading-order neighbor before the file disappears.
            let neighbor = deletionNeighbor(of: url)
            guard BookLibrary.deleteItem(at: url) else { return previous }
            guard let previous else { return nil }
            let deletedPath = url.standardizedFileURL.path
            let previousPath = previous.standardizedFileURL.path
            // The selection (or its whole chapter) went with the delete:
            // fall to the neighbor so the writer keeps writing.
            if previousPath == deletedPath || previousPath.hasPrefix(deletedPath + "/") {
                return neighbor
            }
            return previous
        }
    }

    /// The article the selection should fall to once everything at or
    /// under `url` is deleted: the first survivor after the deleted block
    /// in reading order, else the last one before it.
    private func deletionNeighbor(of url: URL) -> URL? {
        guard let book else { return nil }
        let order = BookLibrary.readingOrder(of: book).map(\.url)
        let deletedPath = url.standardizedFileURL.path
        func dies(_ candidate: URL) -> Bool {
            let path = candidate.standardizedFileURL.path
            return path == deletedPath || path.hasPrefix(deletedPath + "/")
        }
        guard let first = order.firstIndex(where: dies) else { return nil }
        return order[first...].first { !dies($0) } ?? order[..<first].last
    }

}
