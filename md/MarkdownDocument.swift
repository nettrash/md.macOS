//
//  MarkdownDocument.swift
//  md
//
//  Created by nettrash on 28/06/2026.
//
//  The `FileDocument` that backs every editor window. A Markdown file is
//  just UTF-8 text, so the model is a single `String`. Reading and
//  writing therefore reduce to "decode the bytes" / "encode the string"
//  — no wrappers, no temp files, no security-scoped bookmarks; the
//  document architecture owns the file coordination on every platform.
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The Markdown content type. `net.daringfireball.markdown` is the
    /// canonical identifier declared by the system on Apple platforms
    /// (and re-declared as an *imported* type in our Info.plist, since
    /// the type is owned by Daring Fireball, not us). It conforms to
    /// `public.plain-text`, so files we save are ordinary text.
    static let markdown = UTType(importedAs: "net.daringfireball.markdown")

    /// PlantUML source (`.puml`). The format is owned by the PlantUML
    /// project and the system declares no identifier for it, so we import
    /// one in Info.plist that conforms to `public.plain-text` — a `.puml`
    /// file is ordinary UTF-8 text and opens in the editor just like a
    /// `.md` file, with no special handling.
    static let plantUML = UTType(importedAs: "net.sourceforge.plantuml.puml")

    /// Graphviz DOT source (`.gv`). Like PlantUML it is ordinary UTF-8 text
    /// with no system-declared identifier, so we import one conforming to
    /// `public.plain-text`.
    ///
    /// Only `.gv` is claimed, deliberately — DOT's other extension, `.dot`,
    /// is already system-declared as `com.microsoft.word.dot` (a Word
    /// template, which does *not* conform to plain text). Claiming it too
    /// would leave the extension ambiguous and could offer md as a handler
    /// for real Word templates, so a `.dot` file has to be renamed `.gv` to
    /// open. Fenced ```dot blocks inside a Markdown document are unaffected.
    static let graphvizDOT = UTType(importedAs: "org.graphviz.dot")

    /// TextBundle (`.textbundle`) — a directory *package* carrying `text.md`,
    /// `info.json` and an `assets/` folder. It conforms to `com.apple.package`,
    /// which is what makes the document architecture hand us a *directory*
    /// `FileWrapper` to read the text out of (see `MarkdownDocument.init`).
    /// Read-only for the app (not in `writableContentTypes`): the document is
    /// only the text, so saving one back would drop its `assets/` — forbidden.
    static let textBundle = UTType(importedAs: "org.textbundle.package")

    /// TextPack (`.textpack`) — a zipped TextBundle. It conforms to
    /// `public.zip-archive`, so it arrives as ordinary file bytes we unzip in
    /// memory. Read-only for the same reason as `.textbundle`.
    static let textPack = UTType(importedAs: "org.textbundle.pack")
}

/// Decoding and encoding for the plain-text files the app edits — shared by
/// the document architecture (`MarkdownDocument`) and the book workspace's
/// in-place article editor (`BookArticleSession`), so both sides read and
/// round-trip a file's bytes identically.
enum PlainTextCodec {

    /// Try to decode `data` as text, returning the matched encoding.
    /// UTF-16 is only considered behind an explicit BOM — without one,
    /// `String(data:encoding:.utf16)` happily pairs up the bytes of many
    /// legacy single-byte files (BOM-less CP1251 prose, say) into CJK
    /// mojibake, and the next save would bake that corruption in. The
    /// BOM'd decode strips the BOM and `data(using: .utf16)` writes one
    /// back, so such files round-trip. The single-byte trials run most- to
    /// least-specific; `.isoLatin1` maps every byte, so it round-trips
    /// arbitrary bytes losslessly as a last resort.
    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return (text, .utf16)
        }
        for encoding: String.Encoding in [.utf8, .windowsCP1251, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return (text, encoding) }
        }
        return nil
    }

    /// Encode `text` for saving, preferring the encoding the file was read
    /// in so a save round-trips instead of silently rewriting the file as
    /// UTF-8. If the edited text no longer fits it (an emoji typed into a
    /// Windows-1251 file), upgrade to UTF-8 so the new characters survive —
    /// and *report* the encoding actually used, so the caller can remember
    /// the upgrade rather than re-attempting the failed encoding on every
    /// subsequent autosave.
    static func encode(_ text: String, preferred: String.Encoding) -> (data: Data, encoding: String.Encoding) {
        if let data = text.data(using: preferred) { return (data, preferred) }
        return (Data(text.utf8), .utf8)
    }
}

struct MarkdownDocument: FileDocument {
    /// The raw Markdown source. This is the single source of truth the
    /// editor binds to and the previewer renders.
    var text: String

    /// The encoding the file was read in, so a save round-trips in the
    /// file's original encoding instead of silently rewriting it as UTF-8.
    private var encoding: String.Encoding

    init(text: String = "") {
        self.text = text
        self.encoding = .utf8
    }

    /// Markdown is the document type we own, but we also read and write
    /// plain text so the app can open and round-trip a `.txt` the user
    /// drops on it without silently rewriting its extension.
    ///
    /// TextBundle / TextPack are **readable only** — deliberately absent from
    /// `writableContentTypes`: a bundle can carry an `assets/` folder this
    /// single-`String` document has no room for, so saving one back would drop
    /// its images (house rule: nothing the author has vanishes). Opening one
    /// imports its `text.md` for viewing / editing; producing a bundle is the
    /// explicit Export action (see `DocumentExport.exportTextBundle`).
    static var readableContentTypes: [UTType] {
        [.markdown, .plainText, .plantUML, .graphvizDOT, .textBundle, .textPack]
    }
    static var writableContentTypes: [UTType] { [.markdown, .plainText, .plantUML, .graphvizDOT] }

    init(configuration: ReadConfiguration) throws {
        // A `.textbundle` is a directory *package*, so the architecture hands
        // us a directory `FileWrapper` (its `regularFileContents` is nil): read
        // the bundle's `text.md` out of it. `ReadConfiguration.file` is a
        // `FileWrapper` all the same — only the assumption that it wraps a
        // regular file changes.
        if configuration.file.isDirectory {
            guard let (decoded, enc) = TextBundle.textFromBundle(configuration.file) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            text = decoded
            encoding = enc
            return
        }

        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        // A `.textpack` is that bundle zipped — unzip in memory and read its
        // nested `text.md`. A pack that won't unzip is a genuinely corrupt
        // file, so it is *not* fed to the plain-text decoder below: that path's
        // Latin-1 last resort maps any byte, so it would "succeed" and show the
        // raw zip as mojibake instead of reporting the real error.
        if configuration.contentType.conforms(to: .textPack) {
            guard let (decoded, enc) = TextBundle.textFromPack(data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            text = decoded
            encoding = enc
            return
        }

        // Decode strictly (see `PlainTextCodec.decode`). Using the lossy
        // `String(decoding:as:UTF8.self)` would replace every non-UTF-8
        // byte with U+FFFD and then bake that corruption into the file on
        // the next autosave — silent data loss for a legacy-encoded
        // (Cyrillic, Latin-1, UTF-16) text file opened in place.
        guard let (decoded, enc) = PlainTextCodec.decode(data) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        text = decoded
        encoding = enc
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Round-trip in the file's original encoding, upgrading to UTF-8
        // only when the edited text no longer fits it (see
        // `PlainTextCodec.encode`).
        return FileWrapper(regularFileWithContents: PlainTextCodec.encode(text, preferred: encoding).data)
    }
}
