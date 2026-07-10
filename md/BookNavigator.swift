//
//  BookNavigator.swift
//  md
//
//  Created by nettrash on 08/07/2026.
//
//  Writer mode. A "book" is nothing more than a folder the writer picks —
//  its subfolders are chapters, and the Markdown (.md / .markdown / .txt)
//  files inside are articles. The navigator is a small auxiliary window
//  (`Window("Book")` in `mdApp`) that lists the book in reading order and
//  opens any article as a normal document window, so the writer can hop
//  between scenes without a single open panel.
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
//  pipeline a document export uses; Export as EPUB… builds the same
//  reading order as an EPUB 3 instead (see `EPUBExport`).
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
    /// "no silent failures" convention as the export alerts.
    private static func presentError(_ message: String, informative: String) {
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
    /// `folder` must lie inside the book — its access rights come from the
    /// root scope started here.
    static func createArticle(named name: String, in folder: URL) -> Bool {
        guard let root = beginAccess() else { return false }
        defer { endAccess(root) }
        let url = folder.appendingPathComponent(name).appendingPathExtension("md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? Data("# \(name)\n".utf8).write(to: url)) != nil
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

    /// Read the open book for the EPUB export — display names and sources
    /// in the same reading order as the PDF compile, but kept structured:
    /// the EPUB gives every article and chapter heading its own file (see
    /// `EPUBExport`). Returns nil after alerting when there is no book or
    /// an article cannot be read.
    static func readEPUBBook() -> EPUBBook? {
        guard let book = loadBook(), let root = beginAccess() else {
            presentError("Could not export EPUB",
                         informative: "No book is open, or the book folder is not accessible.")
            return nil
        }
        defer { endAccess(root) }
        func read(_ article: BookArticle) -> EPUBBook.Article? {
            guard let text = readArticle(article.url) else {
                presentError("Could not export EPUB",
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

// MARK: - Navigator window

struct BookNavigator: View {
    /// The stored bookmark, observed so this window refreshes itself
    /// whenever *any* window opens or closes a book — the value change
    /// flows through UserDefaults.
    @AppStorage(BookLibrary.bookmarkKey) private var storedBookmark = ""
    @Environment(\.openDocument) private var openDocument
    /// Captured so a compiled book's PDF matches this window's appearance,
    /// exactly as a document export matches its window's.
    @Environment(\.colorScheme) private var colorScheme

    /// The current disk snapshot; nil shows the "no book" placeholder.
    @State private var book: Book?

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

    var body: some View {
        Group {
            if let book {
                list(for: book)
            } else {
                emptyState
            }
        }
        .background(Typewriter.paper.ignoresSafeArea())
        .frame(minWidth: 260, minHeight: 320)
        .navigationTitle(book?.name ?? "Book")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    chapterName = ""
                    isNamingChapter = true
                } label: {
                    Label("New Chapter…", systemImage: "folder.badge.plus")
                }
                .disabled(book == nil)
                .help("Create a new chapter folder in the book")
            }
            // Compile the whole book to one PDF or EPUB — same menu idiom
            // as the document windows' share menu.
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        compileBook(export: false)
                    } label: {
                        Label("Share as PDF", systemImage: "doc.richtext")
                    }
                    Button {
                        compileBook(export: true)
                    } label: {
                        Label("Export as PDF…", systemImage: "square.and.arrow.down")
                    }
                    Divider()
                    Button {
                        exportEPUB()
                    } label: {
                        Label("Export as EPUB…", systemImage: "book.closed")
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .menuIndicator(.hidden)
                .disabled(book == nil)
                .help("Compile the whole book into one PDF or EPUB")
            }
        }
        .onAppear(perform: reload)
        .onChange(of: storedBookmark) { reload() }
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

    // MARK: Content

    private func list(for book: Book) -> some View {
        List {
            // Top-level articles first — the book's front matter — then the
            // chapters, each as its own section. Chapter headers carry the
            // same management menu as the rows; a chapter's sibling group
            // is the book's chapter list, renumbered inside the root.
            Section {
                articleRows(book.articles, in: book.root)
                newArticleButton(in: book.root)
            }
            ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                Section {
                    articleRows(chapter.articles, in: chapter.url)
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
        // Let the typewriter paper show through instead of the default
        // list background.
        .scrollContentBackground(.hidden)
    }

    /// The rows for one sibling group of articles — the unit Move Up /
    /// Move Down reorder within.
    private func articleRows(_ articles: [BookArticle], in folder: URL) -> some View {
        ForEach(Array(articles.enumerated()), id: \.element.id) { index, article in
            Button {
                open(article)
            } label: {
                Label(article.name, systemImage: "doc.text")
                    .font(Typewriter.font(13))
            }
            .buttonStyle(.plain)
            .contextMenu {
                managementMenu(for: article.url, named: article.name,
                               isChapter: false, index: index,
                               of: articles.map { $0.url.lastPathComponent },
                               in: folder)
            }
        }
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

    // MARK: Actions

    /// Re-list the book from disk. Cheap by design, so every mutation just
    /// calls this instead of patching the snapshot in place.
    private func reload() {
        book = BookLibrary.loadBook()
    }

    /// Open an article as a regular document window. The open runs under
    /// the book root's security scope: the article URL lives inside the
    /// user-picked folder, and the sandbox only honours it while that scope
    /// is active. Once the document architecture has the file open it
    /// maintains access on its own (open-file state plus the recents
    /// bookmark it keeps), so the scope ends right after.
    private func open(_ article: BookArticle) {
        Task {
            guard let root = BookLibrary.beginAccess() else { return }
            defer { BookLibrary.endAccess(root) }
            try? await openDocument(at: article.url)
        }
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
        _ = BookLibrary.createArticle(named: name, in: folder)
        reload()
    }

    /// Swap the item with its displayed neighbour and materialize the new
    /// order on disk (see `BookLibrary.renumberPlan`). Impossible moves are
    /// disabled in the menu; the plan's range guard makes them no-ops
    /// regardless.
    private func move(_ from: Int, to: Int, of siblings: [String], in folder: URL) {
        _ = BookLibrary.applyRenames(BookLibrary.renumberPlan(siblings, moving: from, to: to),
                                     in: folder)
        reload()
    }

    /// An empty name is a cancel in spirit — quietly ignored, like the
    /// creation prompts; everything else `BookLibrary.renameItem` vets.
    private func performRename() {
        let stem = renameName.trimmingCharacters(in: .whitespaces)
        guard !stem.isEmpty, let url = renameURL else { return }
        _ = BookLibrary.renameItem(at: url, toDisplayName: stem)
        reload()
    }

    private func performDelete() {
        guard let url = deleteURL else { return }
        _ = BookLibrary.deleteItem(at: url)
        reload()
    }

    /// Compile the whole book and hand it to the same PDF pipeline as a
    /// document export — title page, chapter pages and per-article pages
    /// come from `BookLibrary.compile`; the PDF Layout setting applies as
    /// usual, and the PDF is named after the book.
    private func compileBook(export: Bool) {
        guard let compiled = BookLibrary.compileBookSource() else { return }
        Task {
            if export {
                await DocumentExport.exportPDF(source: compiled.source, title: compiled.title,
                                               dark: colorScheme == .dark)
            } else {
                await DocumentExport.sharePDF(source: compiled.source, title: compiled.title,
                                              dark: colorScheme == .dark)
            }
        }
    }

    /// Read the book and hand it to the EPUB builder (`EPUBExport`) —
    /// same reading order as the PDF compile, saved where the user
    /// chooses, named "<book>.epub".
    private func exportEPUB() {
        guard let book = BookLibrary.readEPUBBook() else { return }
        Task { await DocumentExport.exportEPUB(book: book) }
    }
}
