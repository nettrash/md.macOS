//
//  mdTests.swift
//  mdTests
//
//  Created by nettrash on 29/06/2026.
//
//  Unit tests for the block-level Markdown parser and the HTML export. They
//  are the pieces with non-trivial logic (the views are declarative), so
//  they get the coverage: headings, paragraphs, lists, fences, quotes,
//  tables, rules and the edge cases that separate them, plus the HTML
//  serialization used by print / share. All of it is platform-independent,
//  so this file is shared verbatim with the iOS edition (minus that app's
//  in-app rename, which macOS doesn't need — the native `NSDocument`
//  document architecture provides Rename / Move To).
//

import XCTest
import AppKit
@testable import md

final class mdTests: XCTestCase {

    // MARK: helpers

    private func parse(_ s: String) -> [MarkdownBlock.Kind] {
        MarkdownParser.parse(s).map(\.kind)
    }

    // MARK: headings

    func testHeadingLevels() {
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            guard case let .heading(l, text)? = parse("\(hashes) Title").first else {
                return XCTFail("expected heading for level \(level)")
            }
            XCTAssertEqual(l, level)
            XCTAssertEqual(text, "Title")
        }
    }

    func testHeadingRequiresSpace() {
        // `#Title` (no space) is a paragraph, not a heading.
        guard case .paragraph = parse("#Title").first else {
            return XCTFail("expected paragraph")
        }
    }

    func testHeadingSevenHashesIsParagraph() {
        guard case .paragraph = parse("####### too deep").first else {
            return XCTFail("expected paragraph for 7 hashes")
        }
    }

    func testHeadingClosingHashesStripped() {
        guard case let .heading(_, text)? = parse("## Title ##").first else {
            return XCTFail("expected heading")
        }
        XCTAssertEqual(text, "Title")
    }

    // MARK: paragraphs

    func testParagraphPreservesSoftBreaks() {
        guard case let .paragraph(text)? = parse("line one\nline two").first else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(text, "line one\nline two")
    }

    func testBlankLineSeparatesParagraphs() {
        let kinds = parse("first\n\nsecond")
        XCTAssertEqual(kinds.count, 2)
        if case .paragraph = kinds[0], case .paragraph = kinds[1] {} else {
            XCTFail("expected two paragraphs")
        }
    }

    // MARK: lists

    func testUnorderedList() {
        guard case let .list(ordered, items)? = parse("- a\n- b\n* c").first else {
            return XCTFail("expected list")
        }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.map(\.text), ["a", "b", "c"])
    }

    func testOrderedList() {
        guard case let .list(ordered, items)? = parse("1. one\n2. two\n3) three").first else {
            return XCTFail("expected list")
        }
        XCTAssertTrue(ordered)
        XCTAssertEqual(items.map(\.ordinal), [1, 2, 3])
    }

    func testNestedListLevels() {
        guard case let .list(_, items)? = parse("- top\n  - nested\n    - deeper").first else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(items.map(\.level), [0, 1, 2])
    }

    func testTaskList() {
        guard case let .list(_, items)? = parse("- [ ] todo\n- [x] done\n- [X] also").first else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(items.map(\.task), [false, true, true])
        XCTAssertEqual(items.map(\.text), ["todo", "done", "also"])
    }

    // MARK: code fences

    func testFencedCodeWithLanguage() {
        guard case let .codeBlock(lang, code)? = parse("```swift\nlet x = 1\n```").first else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(code, "let x = 1")
    }

    func testTildeFence() {
        guard case let .codeBlock(_, code)? = parse("~~~\nplain\n~~~").first else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(code, "plain")
    }

    func testFenceContentIsNotInterpreted() {
        // A `#` inside a fence is code, not a heading.
        guard case let .codeBlock(_, code)? = parse("```\n# not a heading\n```").first else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(code, "# not a heading")
    }

    func testUnclosedFenceConsumesToEnd() {
        guard case let .codeBlock(_, code)? = parse("```\na\nb").first else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(code, "a\nb")
    }

    func testIndentedFenceStripsIndent() {
        guard case let .codeBlock(_, code)? = parse("  ```\n  indented\n  ```").first else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(code, "indented")
    }

    // MARK: block quotes

    func testBlockQuote() {
        guard case let .quote(inner)? = parse("> quoted\n> text").first else {
            return XCTFail("expected quote")
        }
        guard case let .paragraph(text)? = inner.first?.kind else {
            return XCTFail("expected paragraph inside quote")
        }
        XCTAssertEqual(text, "quoted\ntext")
    }

    func testNestedBlockQuote() {
        guard case let .quote(inner)? = parse("> > deep").first else {
            return XCTFail("expected quote")
        }
        guard case .quote = inner.first?.kind else {
            return XCTFail("expected nested quote")
        }
    }

    // MARK: thematic breaks

    func testThematicBreaks() {
        for rule in ["---", "***", "___", "- - -", "****"] {
            guard case .thematicBreak? = parse(rule).first else {
                return XCTFail("expected thematic break for \(rule)")
            }
        }
    }

    func testDashesUnderTextAreNotRuleWhenTooShort() {
        // Two dashes is not a rule; it's a paragraph.
        guard case .paragraph? = parse("--").first else {
            return XCTFail("expected paragraph for two dashes")
        }
    }

    // MARK: tables

    func testTableParsing() {
        let md = """
        | Name | Age |
        | :--- | ---: |
        | Ann  | 30 |
        | Bob  | 25 |
        """
        guard case let .table(header, alignments, rows)? = parse(md).first else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(header, ["Name", "Age"])
        XCTAssertEqual(alignments, [.leading, .trailing])
        XCTAssertEqual(rows, [["Ann", "30"], ["Bob", "25"]])
    }

    func testTableCenterAlignment() {
        let md = "| A | B |\n|:-:|:-:|\n| 1 | 2 |"
        guard case let .table(_, alignments, _)? = parse(md).first else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(alignments, [.center, .center])
    }

    func testTableEscapedPipe() {
        let md = "| Col |\n| --- |\n| a \\| b |"
        guard case let .table(_, _, rows)? = parse(md).first else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(rows, [["a | b"]])
    }

    func testNotATableWithoutDelimiterRow() {
        // A line with pipes but no delimiter below is a paragraph.
        guard case .paragraph? = parse("a | b | c\nx | y | z").first else {
            return XCTFail("expected paragraph")
        }
    }

    // MARK: mixed document

    func testMixedDocumentBlockSequence() {
        let md = """
        # Title

        Intro paragraph.

        - one
        - two

        > a quote

        ```
        code
        ```

        ---
        """
        let kinds = parse(md)
        XCTAssertEqual(kinds.count, 6)
        guard case .heading = kinds[0] else { return XCTFail("0 heading") }
        guard case .paragraph = kinds[1] else { return XCTFail("1 paragraph") }
        guard case .list = kinds[2] else { return XCTFail("2 list") }
        guard case .quote = kinds[3] else { return XCTFail("3 quote") }
        guard case .codeBlock = kinds[4] else { return XCTFail("4 code") }
        guard case .thematicBreak = kinds[5] else { return XCTFail("5 rule") }
    }

    // MARK: setext headings (regression — review finding)

    func testSetextHeadings() {
        guard case let .heading(l1, t1)? = parse("My Title\n===").first else {
            return XCTFail("expected H1")
        }
        XCTAssertEqual(l1, 1)
        XCTAssertEqual(t1, "My Title")

        let h2 = parse("My Title\n---")
        guard case let .heading(l2, t2)? = h2.first else { return XCTFail("expected H2") }
        XCTAssertEqual(l2, 2)
        XCTAssertEqual(t2, "My Title")
        // The underline must NOT also emit a spurious thematic break.
        XCTAssertEqual(h2.count, 1)
    }

    func testStandaloneRuleStillParsesAfterSetextChange() {
        guard case .thematicBreak? = parse("---").first else {
            return XCTFail("a standalone --- is still a rule")
        }
    }

    // MARK: list continuation (regression — review finding)

    func testListItemContinuationIsAbsorbed() {
        let blocks = parse("- First item\n  with continuation\n- Second item")
        XCTAssertEqual(blocks.count, 1, "should be one list, not list+paragraph+list")
        guard case let .list(_, items)? = blocks.first else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].text, "First item with continuation")
        XCTAssertEqual(items[1].text, "Second item")
    }

    // MARK: heading trailing '#' (regression — review finding)

    func testHeadingPreservesTrailingHashInWord() {
        guard case let .heading(_, text)? = parse("# C#").first else {
            return XCTFail("expected heading")
        }
        XCTAssertEqual(text, "C#")
        guard case let .heading(_, t2)? = parse("# F# notes").first else {
            return XCTFail("expected heading")
        }
        XCTAssertEqual(t2, "F# notes")
    }

    // MARK: tab-indented lists (regression — review finding)

    func testTabIndentedNestedListRecognised() {
        guard case let .list(_, items)? = parse("- top\n\t- nested").first else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(items.map(\.text), ["top", "nested"])
        XCTAssertGreaterThan(items[1].level, items[0].level)
    }

    // MARK: deep block-quote recursion is bounded (regression — crash)

    func testDeeplyNestedQuoteDoesNotOverflow() {
        let input = String(repeating: ">", count: 5000) + " deep"
        let blocks = MarkdownParser.parse(input)   // must return, not crash
        XCTAssertFalse(blocks.isEmpty)
        guard case .quote? = blocks.first?.kind else {
            return XCTFail("expected a quote block")
        }
    }

    // MARK: HTML serialization (print / PDF / share-rendered)

    func testHTMLWrapsDocument() {
        let html = MarkdownHTML.document("# Title", title: "Doc", dark: false)
        XCTAssertTrue(html.contains("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("<title>Doc</title>"))
        XCTAssertTrue(html.contains("<h1 id=\"title\">Title</h1>"))
    }

    func testHTMLEscapesSpecialCharacters() {
        let html = MarkdownHTML.document("a < b & c > d", title: "t", dark: false)
        XCTAssertTrue(html.contains("a &lt; b &amp; c &gt; d"))
    }

    func testHTMLInlineEmphasis() {
        let html = MarkdownHTML.document("**bold** and *italic* and ~~gone~~", title: "t", dark: false)
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<del>gone</del>"))
    }

    func testHTMLCodeSpanIsEscapedAndNotReinterpreted() {
        let html = MarkdownHTML.document("`a < *b* > c`", title: "t", dark: false)
        XCTAssertTrue(html.contains("<code>a &lt; *b* &gt; c</code>"))
        // The `*` inside the code span must stay literal, not become <em>.
        XCTAssertFalse(html.contains("<em>b</em>"))
    }

    func testHTMLLink() {
        let html = MarkdownHTML.document("[site](https://nettrash.me)", title: "t", dark: false)
        XCTAssertTrue(html.contains("<a href=\"https://nettrash.me\">site</a>"))
    }

    func testHTMLLinkWithTitle() {
        let html = MarkdownHTML.document("[site](https://nettrash.me \"Hover title\")",
                                         title: "t", dark: false)
        XCTAssertTrue(html.contains("<a href=\"https://nettrash.me\" title=\"Hover title\">site</a>"))
    }

    func testHTMLImage() {
        let html = MarkdownHTML.document("![Alt text](https://nettrash.me/favicon.ico)",
                                         title: "t", dark: false)
        XCTAssertTrue(html.contains("<img src=\"https://nettrash.me/favicon.ico\" alt=\"Alt text\">"))
    }

    func testHTMLImageWithTitle() {
        let html = MarkdownHTML.document("![Alt](https://nettrash.me/favicon.ico \"The favicon\")",
                                         title: "t", dark: false)
        XCTAssertTrue(html.contains(
            "<img src=\"https://nettrash.me/favicon.ico\" alt=\"Alt\" title=\"The favicon\">"))
    }

    func testHTMLLinkedImage() {
        // The image pass must run before the link pass, so `[![…](…)](…)`
        // nests the <img> inside the <a> instead of the link eating the label.
        let html = MarkdownHTML.document(
            "[![badge](https://nettrash.me/favicon.ico)](https://nettrash.me)",
            title: "t", dark: false)
        XCTAssertTrue(html.contains(
            "<a href=\"https://nettrash.me\"><img src=\"https://nettrash.me/favicon.ico\" alt=\"badge\"></a>"))
    }

    func testHTMLUnderscoreInWordIsNotItalic() {
        // snake_case must survive (underscore italic is word-boundary only).
        let html = MarkdownHTML.document("call some_long_name now", title: "t", dark: false)
        XCTAssertFalse(html.contains("<em>"))
    }

    func testHTMLTableAlignmentsAndCells() {
        let html = MarkdownHTML.document("| A | B |\n|:-:|--:|\n| 1 | 2 |", title: "t", dark: false)
        XCTAssertTrue(html.contains("text-align:center"))
        XCTAssertTrue(html.contains("text-align:right"))
        XCTAssertTrue(html.contains("<td"))
    }

    func testHTMLThemeVariantsDiffer() {
        let light = MarkdownHTML.document("hi", title: "t", dark: false)
        let dark = MarkdownHTML.document("hi", title: "t", dark: true)
        XCTAssertNotEqual(light, dark)
        XCTAssertTrue(dark.contains("color-scheme: dark"))
        // Backgrounds must be forced to print so the theme survives to PDF.
        XCTAssertTrue(dark.contains("print-color-adjust: exact"))
    }

    // MARK: rich blocks — math / Mermaid / PlantUML (v1.1)

    func testHTMLMermaidBlockEmitsContainer() {
        let html = MarkdownHTML.document("```mermaid\ngraph TD\nA-->B\n```", title: "t", dark: false)
        XCTAssertTrue(html.contains("<pre class=\"mermaid\">"))
        XCTAssertTrue(html.contains("graph TD"))
        // A mermaid fence must NOT become an ordinary code block.
        XCTAssertFalse(html.contains("<pre><code>graph TD"))
        // And the Mermaid engine is pulled in, but not KaTeX/PlantUML.
        XCTAssertTrue(html.contains("mermaid.min.js"))
        XCTAssertFalse(html.contains("katex.min.js"))
        XCTAssertFalse(html.contains("viz-global.js"))
    }

    func testHTMLPlantumlBlockEmitsContainer() {
        let html = MarkdownHTML.document("```plantuml\n@startuml\nA->B\n@enduml\n```", title: "t", dark: false)
        XCTAssertTrue(html.contains("<div class=\"plantuml\">"))
        XCTAssertTrue(html.contains("@startuml"))
        // PlantUML needs Viz/Graphviz; the engine itself is imported lazily by md-init.js.
        XCTAssertTrue(html.contains("viz-global.js"))
    }

    func testHTMLMathFenceEmitsDisplayMath() {
        let html = MarkdownHTML.document("```math\n\\int_0^1 x\\,dx\n```", title: "t", dark: false)
        XCTAssertTrue(html.contains("class=\"md-mathd\""))
        XCTAssertTrue(html.contains("\\int_0^1"))
        XCTAssertTrue(html.contains("katex.min.js"))
    }

    func testHTMLInlineMathIsNotMangledByEmphasis() {
        // A `*` inside inline math must stay literal, not become <em>.
        let html = MarkdownHTML.document("total $a*b*c$ units", title: "t", dark: false)
        XCTAssertTrue(html.contains("class=\"md-mathi\""))
        XCTAssertTrue(html.contains("a*b*c"))
        XCTAssertFalse(html.contains("<em>"))
        XCTAssertTrue(html.contains("katex.min.js"))
    }

    func testHTMLDisplayMathSpanPreserved() {
        let html = MarkdownHTML.document("$$x^2 + y^2$$", title: "t", dark: false)
        XCTAssertTrue(html.contains("class=\"md-mathd\""))
        XCTAssertTrue(html.contains("x^2 + y^2"))
    }

    func testHTMLCurrencyDollarsAreNotMath() {
        // "$5 and $10" is prose, not a formula; leave it be (KaTeX is still
        // included heuristically, but the text must not be treated as a span).
        let html = MarkdownHTML.document("it costs $5 and $10 today", title: "t", dark: false)
        XCTAssertTrue(html.contains("$5 and $10"))
        XCTAssertFalse(html.contains("class=\"md-mathi\""))
        XCTAssertFalse(html.contains("katex.min.js"))
    }

    func testHTMLPlainDocumentStaysLight() {
        // No rich content → none of the heavy engines are included; md-init.js
        // (tiny, always present) still runs and flags render-complete.
        let html = MarkdownHTML.document("# Just text\n\nA paragraph.", title: "t", dark: false)
        XCTAssertFalse(html.contains("katex.min.js"))
        XCTAssertFalse(html.contains("mermaid.min.js"))
        XCTAssertFalse(html.contains("viz-global.js"))
        XCTAssertTrue(html.contains("rich/md-init.js"))
    }

    func testHTMLCodeSpanDollarIsNotMath() {
        // `$x$` inside a code span stays literal code, not a formula.
        let html = MarkdownHTML.document("use `$x$` here", title: "t", dark: false)
        XCTAssertTrue(html.contains("<code>$x$</code>"))
    }

    // MARK: Page breaks, notes & outline

    func testPageBreakParses() {
        let blocks = MarkdownParser.parse("before\n\n\\newpage\n\nafter")
        XCTAssertEqual(blocks.count, 3)
        guard case .pageBreak = blocks[1].kind else { return XCTFail("Expected a page break") }
    }

    func testPageBreakVariantInterruptsParagraph() {
        // `\pagebreak` works too, and a marker interrupts a paragraph run.
        let blocks = MarkdownParser.parse("line one\n\\pagebreak\nline two")
        XCTAssertEqual(blocks.count, 3)
        guard case .pageBreak = blocks[1].kind else { return XCTFail("Expected a page break") }
    }

    func testNoteCommentBecomesNoteBlock() {
        let blocks = MarkdownParser.parse("<!-- note: check the intro -->")
        XCTAssertEqual(blocks.count, 1)
        guard case let .note(text) = blocks[0].kind else { return XCTFail("Expected a note") }
        XCTAssertEqual(text, "check the intro")
    }

    func testPlainCommentIsDropped() {
        // A non-note HTML comment vanishes entirely — no block, no output.
        let blocks = MarkdownParser.parse("a\n\n<!-- just a comment -->\n\nb")
        XCTAssertEqual(blocks.count, 2)
    }

    func testMultilineNote() {
        let blocks = MarkdownParser.parse("<!-- note: first\nsecond -->")
        guard case let .note(text) = blocks.first?.kind else { return XCTFail("Expected a note") }
        XCTAssertTrue(text.contains("first"))
        XCTAssertTrue(text.contains("second"))
    }

    func testOutlineLevelsSlugsAndLines() {
        let source = "# One\n\ntext\n\n## Two\n\n```\n# not a heading\n```\n\nSetext\n---"
        let outline = MarkdownParser.outline(source)
        XCTAssertEqual(outline.count, 3)
        XCTAssertEqual(outline[0].level, 1)
        XCTAssertEqual(outline[0].slug, "one")
        XCTAssertEqual(outline[0].line, 0)
        XCTAssertEqual(outline[1].slug, "two")
        XCTAssertEqual(outline[2].level, 2)          // setext `---` underline
        XCTAssertEqual(outline[2].text, "Setext")
        XCTAssertEqual(outline[2].line, 10)
    }

    func testDuplicateHeadingSlugsAreDeduped() {
        let outline = MarkdownParser.outline("# Same\n\n# Same")
        XCTAssertEqual(outline.map(\.slug), ["same", "same-1"])
    }

    func testOutlineSkipsUnderlineAfterMultiLineParagraph() {
        // `---` after a 2+-line paragraph is a rule, not a setext heading —
        // parse() and outline() must agree, or the Contents menu would list
        // a phantom entry and desync every later anchor slug.
        XCTAssertTrue(MarkdownParser.outline("line1\nline2\n---").isEmpty)
        XCTAssertEqual(MarkdownParser.outline("only\n---").count, 1)
    }

    func testSlugDropsPunctuationLikeGitHub() {
        var used: [String: Int] = [:]
        XCTAssertEqual(MarkdownParser.slug(for: "C# & F#!", used: &used), "c--f")
    }

    func testNotesHelperFindsLine() {
        let notes = MarkdownParser.notes("start\n\n<!-- note: fix me -->\n\nend")
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].text, "fix me")
        XCTAssertEqual(notes[0].line, 2)
    }

    func testHTMLHeadingsCarryAnchorIds() {
        let html = MarkdownHTML.document("# My Title\n\n# My Title", title: "t", dark: false)
        XCTAssertTrue(html.contains("<h1 id=\"my-title\">"))
        XCTAssertTrue(html.contains("<h1 id=\"my-title-1\">"))
    }

    func testHTMLPageBreakMarkerAndExportCSS() {
        let preview = MarkdownHTML.document("a\n\n\\newpage\n\nb", title: "t", dark: false)
        XCTAssertTrue(preview.contains("md-pagebreak"))
        XCTAssertFalse(preview.contains("break-after: page"))
        let export = MarkdownHTML.document("a\n\n\\newpage\n\nb", title: "t", dark: false, export: true)
        XCTAssertTrue(export.contains("break-after: page"))
    }

    func testExportPageIsPlainWhiteAndAlwaysLight() {
        // Print / PDF pages keep their own single color: no paper tint
        // (which would end mid-page next to the white A4 margins), and the
        // light palette even from a dark window — dark cream-on-carbon is
        // a screen theme, unreadable as cream-on-white.
        let export = MarkdownHTML.document("hello", title: "t", dark: true, export: true)
        XCTAssertTrue(export.contains("background: #FFFFFF"), "The page background is plain white")
        XCTAssertTrue(export.contains("color-scheme: light"), "Export always renders light")
        XCTAssertFalse(export.contains("#241E18"), "No dark-paper color anywhere in an export")
        XCTAssertTrue(export.contains("data-md-dark=\"0\""),
                      "The rich renderers (Mermaid theme) see the light mode too")
        // The on-screen preview still honors the window's appearance.
        let preview = MarkdownHTML.document("hello", title: "t", dark: true)
        XCTAssertTrue(preview.contains("background: #241E18"), "Dark preview keeps the carbon paper")
        XCTAssertTrue(preview.contains("data-md-dark=\"1\""))
    }

    func testRawPlantUMLDocumentRendersAsDiagram() {
        // An opened `.puml` is bare diagram source with no ```plantuml fence.
        // It must render as one PlantUML diagram — a `.plantuml` container that
        // md-init.js turns into an SVG — not as Markdown text, which would show
        // the `@startuml…` source as paragraphs and never draw anything.
        let puml = "@startuml\nAlice -> Bob: hi\nBob --> Alice: hi\n@enduml\n"
        let html = MarkdownHTML.document(puml, title: "d", dark: false)
        XCTAssertTrue(html.contains("<div class=\"plantuml\">"),
                      "Raw PlantUML renders through the .plantuml container")
        XCTAssertTrue(html.contains("rich/viz-global.js"),
                      "The PlantUML engine's Viz dependency is pulled in")
        XCTAssertFalse(html.contains("<p>@startuml"),
                       "The source must not be parsed as Markdown paragraphs")

        // Detection skips PlantUML line comments and blank lines before the
        // opener, and recognizes any @start… diagram, not only @startuml.
        XCTAssertTrue(MarkdownHTML.isRawPlantUML("' header comment\n\n@startmindmap\n* root\n@endmindmap"))
        XCTAssertTrue(MarkdownHTML.isRawPlantUML("   \n@startuml\n@enduml"))

        // A normal Markdown document is untouched: not a whole-document diagram,
        // and `@startuml` mentioned mid-prose is not a false positive.
        XCTAssertFalse(MarkdownHTML.isRawPlantUML("# Title\n\nSome prose about @startuml in passing."))
        let md = MarkdownHTML.document("# Title\n\nHello.", title: "d", dark: false)
        XCTAssertFalse(md.contains("<div class=\"plantuml\">"))
        XCTAssertTrue(md.contains("<h1"))
    }

    func testHTMLOmitsAuthorNotes() {
        let html = MarkdownHTML.document("visible\n\n<!-- note: secret draft thought -->",
                                         title: "t", dark: false)
        XCTAssertTrue(html.contains("visible"))
        XCTAssertFalse(html.contains("secret draft thought"))
    }

    // MARK: Book management (rename / reorder planning)

    func testRenumberPlanMaterializesAMoveDown() {
        // a moves below b; c is already right, so only two renames.
        let plan = BookLibrary.renumberPlan(["01-a.md", "02-b.md", "03-c.md"], moving: 0, to: 1)
        XCTAssertEqual(plan.map { $0.from }, ["02-b.md", "01-a.md"])
        XCTAssertEqual(plan.map { $0.to }, ["01-b.md", "02-a.md"])
    }

    func testRenumberPlanPrefixesUnprefixedSiblings() {
        // Unprefixed and loosely-prefixed names all end up with the
        // canonical zero-padded prefix; display names survive.
        let plan = BookLibrary.renumberPlan(["1. intro.md", "notes.md", "02-end.md"],
                                            moving: 2, to: 1)
        XCTAssertEqual(plan.map { $0.from }, ["1. intro.md", "notes.md"])
        XCTAssertEqual(plan.map { $0.to }, ["01-intro.md", "03-notes.md"])
    }

    func testRenumberPlanHandlesChapterFolders() {
        // Chapters have no extension, and a dot in a folder name is part
        // of the name — not a format to preserve separately.
        let plan = BookLibrary.renumberPlan(["Drafts", "01-Final"], moving: 1, to: 0)
        XCTAssertEqual(plan.map { $0.from }, ["Drafts"])
        XCTAssertEqual(plan.map { $0.to }, ["02-Drafts"])
    }

    func testRenumberPlanSwapsIdenticalStems() {
        // Trading places between same-stem names yields renames that pass
        // through each other — the executor stages via temporary names so
        // this never collides on disk.
        let plan = BookLibrary.renumberPlan(["01-a.md", "02-a.md"], moving: 0, to: 1)
        XCTAssertEqual(plan.map { $0.from }, ["02-a.md", "01-a.md"])
        XCTAssertEqual(plan.map { $0.to }, ["01-a.md", "02-a.md"])
    }

    func testRenumberPlanRejectsImpossibleMoves() {
        XCTAssertTrue(BookLibrary.renumberPlan(["01-a.md"], moving: 0, to: -1).isEmpty)
        XCTAssertTrue(BookLibrary.renumberPlan(["01-a.md"], moving: 0, to: 1).isEmpty)
        XCTAssertTrue(BookLibrary.renumberPlan(["01-a.md"], moving: 0, to: 0).isEmpty)
        XCTAssertTrue(BookLibrary.renumberPlan([], moving: 0, to: 0).isEmpty)
    }

    func testRenamedNameKeepsPrefixAndExtension() {
        XCTAssertEqual(BookLibrary.renamedName("01-Draft.md", toDisplayName: "Final"),
                       "01-Final.md")
        XCTAssertEqual(BookLibrary.renamedName("2. setup.markdown", toDisplayName: "config"),
                       "2. config.markdown")
        XCTAssertEqual(BookLibrary.renamedName("notes.md", toDisplayName: "journal"),
                       "journal.md")
        XCTAssertEqual(BookLibrary.renamedName("02-Getting Started", toDisplayName: "Basics"),
                       "02-Basics")
    }

    func testDisplayNameStripsPrefixAndExtension() {
        XCTAssertEqual(BookLibrary.displayName("01-Preface.md"), "Preface")
        XCTAssertEqual(BookLibrary.displayName("02-Getting Started"), "Getting Started")
        // An all-number name has nothing else to show — it stays whole.
        XCTAssertEqual(BookLibrary.displayName("01.md"), "01")
    }

    // MARK: Book compilation (the whole book as one Markdown source)

    func testCompileBeginsWithTitlePage() {
        let out = BookLibrary.compile(bookName: "My Book",
                                      parts: [.article(text: "Hello.")])
        XCTAssertTrue(out.hasPrefix("# My Book\n\n\\newpage\n\n"),
                      "The title page comes first, on a page of its own")
        XCTAssertTrue(out.hasSuffix("Hello."))
    }

    func testCompileOrdersPartsAndPagesEveryOne() {
        // Reading order in, one page per part out: chapter headings on
        // their own page, `\newpage` between all parts, text verbatim.
        let out = BookLibrary.compile(bookName: "B", parts: [
            .article(text: "Front matter."),
            .chapter(name: "One"),
            .article(text: "First.\n\n---\n\nStill first."),
            .article(text: "Second."),
        ])
        XCTAssertEqual(out, """
        # B

        \\newpage

        Front matter.

        \\newpage

        # One

        \\newpage

        First.

        ---

        Still first.

        \\newpage

        Second.
        """)
        // The article's own `---` stays an ordinary rule — only the
        // compiler's `\newpage` markers cut pages.
        let breaks = MarkdownParser.parse(out).filter {
            if case .pageBreak = $0.kind { return true }
            return false
        }
        XCTAssertEqual(breaks.count, 4, "One page cut per part, none from the rule")
    }

    func testCompileOfEmptyBookIsJustTheTitlePage() {
        XCTAssertEqual(BookLibrary.compile(bookName: "Empty", parts: []), "# Empty")
    }

    // MARK: EPUB export (container / XHTML / package)

    func testZipWriterProducesValidStoredArchive() {
        var zip = EPUBZipWriter()
        zip.add("mimetype", Data("application/epub+zip".utf8))
        zip.add("OEBPS/a.txt", Data("hello".utf8))
        let data = zip.finish()
        // Local file header signature "PK\3\4" at byte 0.
        XCTAssertEqual([UInt8](data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        // Compression method (bytes 8–9) is 0: stored, as EPUB requires
        // of the mimetype.
        XCTAssertEqual(data[8], 0)
        XCTAssertEqual(data[9], 0)
        // The FIRST entry is the mimetype, its bytes verbatim right after
        // the 30-byte header and 8-byte name.
        XCTAssertEqual(String(data: data.subdata(in: 30..<38), encoding: .utf8), "mimetype")
        XCTAssertEqual(String(data: data.subdata(in: 38..<58), encoding: .utf8),
                       "application/epub+zip")
        // End-of-central-directory record closes the archive.
        XCTAssertEqual([UInt8](data.suffix(22).prefix(4)), [0x50, 0x4B, 0x05, 0x06])
    }

    func testZipWriterCRC32MatchesKnownVector() {
        // The canonical CRC-32 check value ("123456789" → 0xCBF43926).
        XCTAssertEqual(EPUBZipWriter.crc32(Data("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(EPUBZipWriter.crc32(Data()), 0)
    }

    func testXHTMLFixerMakesWellFormedMarkup() {
        let fixed = EPUBExport.xhtmlBody("""
        <p>a<br>b</p>
        <hr>
        <img src="x.png" alt="pic">
        <div class="md-list"><span class="md-marker">&bull;</span></div>
        <script type="module" src="rich/md-init.js"></script>
        """)
        XCTAssertTrue(fixed.contains("<br/>"))
        XCTAssertTrue(fixed.contains("<hr/>"))
        XCTAssertTrue(fixed.contains("<img src=\"x.png\" alt=\"pic\"/>"))
        XCTAssertTrue(fixed.contains("&#8226;"), "named entities become numeric")
        XCTAssertFalse(fixed.contains("&bull;"))
        XCTAssertFalse(fixed.contains("<script"), "engine references are stripped")
    }

    func testRichElementsBecomeImages() {
        let html = "<p>x <span class=\"md-mathi\">a^2</span> y</p>\n<pre class=\"mermaid\">graph TD</pre>"
        let out = EPUBExport.replacingRichElements(in: html, with: [
            "<img src=\"images/m0.png\" alt=\"formula\"/>",
            "<img src=\"images/m1.png\" alt=\"diagram\"/>",
        ])
        XCTAssertEqual(out, "<p>x <img src=\"images/m0.png\" alt=\"formula\"/> y</p>\n"
                       + "<img src=\"images/m1.png\" alt=\"diagram\"/>")
    }

    func testOPFCarriesMetadataManifestAndSpine() {
        let opf = EPUBExport.opf(title: "A & B", identifier: "urn:uuid:TEST",
                                 modified: "2026-07-10T00:00:00Z",
                                 units: ["unit-000.xhtml", "unit-001.xhtml"],
                                 images: ["images/unit-001-rich-0.png"])
        XCTAssertTrue(opf.contains("<dc:title>A &amp; B</dc:title>"))
        XCTAssertTrue(opf.contains("<dc:language>en</dc:language>"))
        XCTAssertTrue(opf.contains("<dc:identifier id=\"bookid\">urn:uuid:TEST</dc:identifier>"))
        XCTAssertTrue(opf.contains("<meta property=\"dcterms:modified\">2026-07-10T00:00:00Z</meta>"))
        XCTAssertTrue(opf.contains("properties=\"nav\""))
        XCTAssertTrue(opf.contains(
            "<item id=\"u1\" href=\"unit-001.xhtml\" media-type=\"application/xhtml+xml\"/>"))
        XCTAssertTrue(opf.contains(
            "<item id=\"i0\" href=\"images/unit-001-rich-0.png\" media-type=\"image/png\"/>"))
        // The spine follows the unit order — the reading order.
        let first = opf.range(of: "<itemref idref=\"u0\"/>")
        let second = opf.range(of: "<itemref idref=\"u1\"/>")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertTrue(first!.lowerBound < second!.lowerBound)
    }

    func testNavListsRootArticlesThenNestedChapters() {
        let nav = EPUBExport.nav(title: "Book", entries: [
            .init(title: "Intro", file: "unit-001.xhtml"),
            .init(title: "Chapter One", file: "unit-002.xhtml", children: [
                .init(title: "First", file: "unit-003.xhtml"),
            ]),
        ])
        XCTAssertTrue(nav.contains("epub:type=\"toc\""))
        XCTAssertTrue(nav.contains("<a href=\"unit-001.xhtml\">Intro</a>"))
        // The chapter's articles nest inside the chapter's own item.
        XCTAssertTrue(nav.contains("<li><a href=\"unit-002.xhtml\">Chapter One</a>\n<ol>"))
        XCTAssertTrue(nav.contains("<a href=\"unit-003.xhtml\">First</a>"))
    }

    // MARK: Book workspace — reading order & selection remapping

    /// A book snapshot straight from URLs — the listing is not under test.
    private func makeBook(root: String, articles: [String], chapters: [(String, [String])]) -> Book {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        return Book(
            root: rootURL,
            articles: articles.map { BookArticle(url: rootURL.appendingPathComponent($0)) },
            chapters: chapters.map { name, files in
                let chapterURL = rootURL.appendingPathComponent(name, isDirectory: true)
                return BookChapter(url: chapterURL,
                                   articles: files.map { BookArticle(url: chapterURL.appendingPathComponent($0)) })
            })
    }

    func testReadingOrderIsRootArticlesThenChapters() {
        let book = makeBook(root: "/tmp/Book",
                            articles: ["01-Preface.md"],
                            chapters: [("02-One", ["01-a.md", "02-b.md"]),
                                       ("03-Two", ["01-c.md"])])
        XCTAssertEqual(BookLibrary.readingOrder(of: book).map(\.name),
                       ["01-Preface", "01-a", "02-b", "01-c"])
    }

    func testReadingOrderOfEmptyBookIsEmpty() {
        let book = makeBook(root: "/tmp/Book", articles: [], chapters: [("02-One", [])])
        XCTAssertTrue(BookLibrary.readingOrder(of: book).isEmpty)
    }

    func testDestinationFollowsARenamedArticle() {
        let folder = URL(fileURLWithPath: "/tmp/Book", isDirectory: true)
        let moved = BookLibrary.destination(of: folder.appendingPathComponent("02-Draft.md"),
                                            afterRenamesIn: folder,
                                            plan: [(from: "02-Draft.md", to: "01-Draft.md"),
                                                   (from: "01-Intro.md", to: "02-Intro.md")])
        XCTAssertEqual(moved.lastPathComponent, "01-Draft.md")
    }

    func testDestinationFollowsAnArticleInsideARenamedChapter() {
        let root = URL(fileURLWithPath: "/tmp/Book", isDirectory: true)
        let article = root.appendingPathComponent("03-Middle").appendingPathComponent("01-Scene.md")
        let moved = BookLibrary.destination(of: article, afterRenamesIn: root,
                                            plan: [(from: "03-Middle", to: "02-Middle")])
        XCTAssertEqual(moved.path, "/tmp/Book/02-Middle/01-Scene.md")
    }

    func testDestinationLeavesUntouchedURLsAlone() {
        let root = URL(fileURLWithPath: "/tmp/Book", isDirectory: true)
        let plan = [(from: "01-a.md", to: "02-a.md")]
        // A sibling the plan doesn't mention…
        let bystander = root.appendingPathComponent("03-c.md")
        XCTAssertEqual(BookLibrary.destination(of: bystander, afterRenamesIn: root, plan: plan),
                       bystander.standardizedFileURL)
        // …and anything outside the folder entirely.
        let outside = URL(fileURLWithPath: "/tmp/Elsewhere/01-a.md")
        XCTAssertEqual(BookLibrary.destination(of: outside, afterRenamesIn: root, plan: plan),
                       outside)
    }

    // MARK: Plain-text codec (shared by documents and the book editor)

    func testCodecDecodesUTF8() {
        let decoded = PlainTextCodec.decode(Data("# Привет\n".utf8))
        XCTAssertEqual(decoded?.text, "# Привет\n")
        XCTAssertEqual(decoded?.encoding, .utf8)
    }

    func testCodecDoesNotMistakeBOMlessCP1251ForUTF16() {
        // Cyrillic prose in Windows-1251 — even-length and BOM-less, the
        // shape a naive UTF-16 trial happily (and wrongly) accepts as CJK
        // mojibake. It must decode as CP1251 and round-trip byte-exactly.
        let original = "Привет, мир!"
        let data = original.data(using: .windowsCP1251)!
        let decoded = PlainTextCodec.decode(data)
        XCTAssertEqual(decoded?.text, original)
        XCTAssertEqual(decoded?.encoding, .windowsCP1251)
        XCTAssertEqual(PlainTextCodec.encode(decoded!.text, preferred: decoded!.encoding).data, data)
    }

    func testCodecRoundTripsBOMedUTF16() {
        let original = "# Chapter\n"
        let data = original.data(using: .utf16)! // data(using:) writes a BOM
        let decoded = PlainTextCodec.decode(data)
        XCTAssertEqual(decoded?.text, original)
        XCTAssertEqual(decoded?.encoding, .utf16)
        // Re-encoding restores a BOM'd UTF-16 file, not a silently
        // rewritten one.
        XCTAssertEqual(String(data: PlainTextCodec.encode(original, preferred: .utf16).data,
                              encoding: .utf16), original)
    }

    func testCodecUpgradesToUTF8AndSaysSo() {
        // An emoji cannot live in CP1251: the encode must fall back to
        // UTF-8 *and report it*, so an autosaving caller updates its
        // remembered encoding instead of failing the same way every save.
        let (data, encoding) = PlainTextCodec.encode("Привет 🙂", preferred: .windowsCP1251)
        XCTAssertEqual(encoding, .utf8)
        XCTAssertEqual(String(data: data, encoding: .utf8), "Привет 🙂")
    }

    // MARK: Writing stats (the workspace footer)

    func testWordCountIsLocaleAwareNotAWhitespaceSplit() {
        XCTAssertEqual(WritingStats.words(in: ""), 0)
        XCTAssertEqual(WritingStats.words(in: "   \n\n"), 0)
        XCTAssertEqual(WritingStats.words(in: "Hello, world!"), 2)
        // An apostrophe joins a word; a dash alone is none.
        XCTAssertEqual(WritingStats.words(in: "it's — done"), 2)
        XCTAssertEqual(WritingStats.words(in: "One\ntwo\n\nthree"), 3)
    }

    // MARK: Book article session (in-place editing round-trip)

    /// A scratch book folder on disk; the session is exercised against it
    /// without any sandbox scope (the test seam `openBook(unscopedRoot:)`).
    @MainActor
    private func makeSessionBook() throws -> (root: URL, article: URL, session: BookArticleSession) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let article = root.appendingPathComponent("01-Scene.md")
        try Data("# Scene\n".utf8).write(to: article)
        let session = BookArticleSession()
        session.openBook(unscopedRoot: root)
        return (root, article, session)
    }

    @MainActor
    func testSessionLoadsEditsAndFlushesToDisk() throws {
        let (_, article, session) = try makeSessionBook()
        XCTAssertTrue(session.select(article))
        XCTAssertEqual(session.text, "# Scene\n")
        XCTAssertEqual(session.editingURL, article.standardizedFileURL)

        session.edit("# Scene\n\nIt was a dark and stormy night.\n")
        XCTAssertTrue(session.dirty)
        XCTAssertTrue(session.flushNow())
        XCTAssertFalse(session.dirty)
        XCTAssertEqual(try String(contentsOf: article, encoding: .utf8),
                       "# Scene\n\nIt was a dark and stormy night.\n")
        session.closeBook()
    }

    @MainActor
    func testSessionSelectionChangeSavesTheOutgoingArticle() throws {
        let (root, article, session) = try makeSessionBook()
        let second = root.appendingPathComponent("02-Scene.md")
        try Data("# Second\n".utf8).write(to: second)

        XCTAssertTrue(session.select(article))
        session.edit("# Scene, revised\n")
        XCTAssertTrue(session.select(second))
        // Moving on flushed the first article and loaded the second.
        XCTAssertEqual(try String(contentsOf: article, encoding: .utf8), "# Scene, revised\n")
        XCTAssertEqual(session.text, "# Second\n")
        session.closeBook()
    }

    @MainActor
    func testSessionRefusesToClobberAFileChangedUnderIt() throws {
        let (_, article, session) = try makeSessionBook()
        XCTAssertTrue(session.select(article))
        session.edit("# Mine\n")
        // Someone else rewrites the file (different size, so the staleness
        // check cannot be fooled by coarse timestamps).
        try Data("# Theirs, and much longer than before\n".utf8).write(to: article)

        XCTAssertFalse(session.flushNow())
        XCTAssertTrue(session.conflicted)
        // Neither side was lost: theirs is on disk, mine is in the buffer.
        XCTAssertEqual(try String(contentsOf: article, encoding: .utf8),
                       "# Theirs, and much longer than before\n")
        XCTAssertEqual(session.text, "# Mine\n")

        // The writer decides: Keep My Version writes the buffer out.
        session.resolveConflictKeepingMine()
        XCTAssertFalse(session.conflicted)
        XCTAssertEqual(try String(contentsOf: article, encoding: .utf8), "# Mine\n")
        session.closeBook()
    }

    @MainActor
    func testSessionReloadResolutionDiscardsTheBuffer() throws {
        let (_, article, session) = try makeSessionBook()
        XCTAssertTrue(session.select(article))
        session.edit("# Mine\n")
        try Data("# Theirs, and much longer than before\n".utf8).write(to: article)
        XCTAssertFalse(session.flushNow())
        XCTAssertTrue(session.conflicted)

        session.resolveConflictReloading()
        XCTAssertFalse(session.conflicted)
        XCTAssertEqual(session.text, "# Theirs, and much longer than before\n")
        // Nothing dirty remains, so closing writes nothing.
        session.closeBook()
        XCTAssertEqual(try String(contentsOf: article, encoding: .utf8),
                       "# Theirs, and much longer than before\n")
    }

    @MainActor
    func testSessionCloseBookFlushesPendingEdits() throws {
        let (_, article, session) = try makeSessionBook()
        XCTAssertTrue(session.select(article))
        session.edit("# Closing time\n")
        session.closeBook()
        XCTAssertEqual(try String(contentsOf: article, encoding: .utf8), "# Closing time\n")
    }

    // MARK: Reading order — the ordered() comparator itself

    func testOrderedPutsNumberedNamesFirstInNumericOrder() {
        // Numeric, not lexicographic: 2 before 10; numbered before not.
        XCTAssertTrue(BookLibrary.ordered("2. setup", "10-ending"))
        XCTAssertFalse(BookLibrary.ordered("10-ending", "2. setup"))
        XCTAssertTrue(BookLibrary.ordered("01-intro", "appendix"))
        XCTAssertFalse(BookLibrary.ordered("appendix", "01-intro"))
    }

    func testOrderedFallsBackToFinderAlphabetical() {
        XCTAssertTrue(BookLibrary.ordered("apple", "Banana"))
        XCTAssertFalse(BookLibrary.ordered("Banana", "apple"))
        // Equal leading numbers tie-break alphabetically too.
        XCTAssertTrue(BookLibrary.ordered("01-a", "01-b"))
    }

    func testOrderedTreatsOverflowingDigitRunsAsUnnumbered() {
        // A digit run too long for Int must not trap — it sorts as an
        // unnumbered name instead.
        XCTAssertTrue(BookLibrary.ordered("1-x", "99999999999999999999-y"))
        XCTAssertFalse(BookLibrary.ordered("99999999999999999999-y", "1-x"))
    }

    @MainActor
    func testSessionCleanFlushLeavesTheFileUntouched() throws {
        // flushNow runs on every selection change and window focus; a
        // clean session must not rewrite (and re-stamp) the file each time.
        let (_, article, session) = try makeSessionBook()
        XCTAssertTrue(session.select(article))
        let before = try FileManager.default.attributesOfItem(atPath: article.path)[.modificationDate] as? Date
        // Make sure a spurious rewrite could not land on the same stamp.
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertTrue(session.flushNow())

        let after = try FileManager.default.attributesOfItem(atPath: article.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
        session.closeBook()
    }

    @MainActor
    func testSessionDeselectFlushesAndFullyDetaches() throws {
        // select(nil) is the prelude of every managed file operation
        // (rename / reorder / delete / create): it must flush the buffer
        // and fully let go of the file before anything moves on disk.
        let (_, article, session) = try makeSessionBook()
        XCTAssertTrue(session.select(article))
        session.edit("# Detached\n")

        XCTAssertTrue(session.select(nil))
        XCTAssertEqual(try String(contentsOf: article, encoding: .utf8), "# Detached\n")
        XCTAssertNil(session.editingURL)
        XCTAssertEqual(session.stage, .empty)
        XCTAssertEqual(session.text, "")
        XCTAssertFalse(session.dirty)
        session.closeBook()
    }

    @MainActor
    func testSessionFailedFlushAbortsTheSelectionChange() throws {
        // The sidebar reverts its selection when select() returns false,
        // on the contract that the session still holds the unsaved article.
        let (root, article, session) = try makeSessionBook()
        let second = root.appendingPathComponent("02-Scene.md")
        try Data("# Second\n".utf8).write(to: second)
        XCTAssertTrue(session.select(article))
        session.edit("# Unsaved\n")
        // Make the write fail: the article file itself becomes read-only.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: article.path)

        XCTAssertFalse(session.select(second))
        XCTAssertEqual(session.editingURL, article.standardizedFileURL)
        XCTAssertEqual(session.text, "# Unsaved\n")
        XCTAssertTrue(session.dirty)
        XCTAssertNotNil(session.saveErrorText)

        // Once the file is writable again the same move succeeds.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: article.path)
        XCTAssertTrue(session.select(second))
        XCTAssertEqual(try String(contentsOf: article, encoding: .utf8), "# Unsaved\n")
        session.closeBook()
    }

    @MainActor
    func testSessionHandOffForExternalOpenSavesThenStepsAside() throws {
        // Opening the edited article in its own window must ship the
        // buffer to disk first — the new window reads the file — and leave
        // the session in handoff so there is never a second writer.
        let (_, article, session) = try makeSessionBook()
        XCTAssertTrue(session.select(article))
        session.edit("# For the window\n")

        XCTAssertTrue(session.handOffForExternalOpen())
        XCTAssertEqual(try String(contentsOf: article, encoding: .utf8), "# For the window\n")
        XCTAssertEqual(session.stage, .handoff(article.standardizedFileURL))
        XCTAssertNil(session.editingURL)
        session.closeBook()
    }

    @MainActor
    func testSessionStepsAsideWhileADocumentOwnsTheArticle() throws {
        // The two-writers guard: while an NSDocument window has the file,
        // selecting it in the book yields a handoff, and the session
        // reclaims it once the document goes away.
        let (_, article, session) = try makeSessionBook()
        let document = NSDocument()
        document.fileURL = article
        NSDocumentController.shared.addDocument(document)

        XCTAssertTrue(session.select(article))
        XCTAssertEqual(session.stage, .handoff(article.standardizedFileURL))
        XCTAssertNil(session.editingURL)

        NSDocumentController.shared.removeDocument(document)
        session.recheckOwnership()
        XCTAssertEqual(session.editingURL, article.standardizedFileURL)
        XCTAssertEqual(session.text, "# Scene\n")
        session.closeBook()
    }

    @MainActor
    func testSessionRescueCopyParksTheBufferWithoutOverwriting() throws {
        // The quit-time last resort: when the regular write cannot land,
        // the buffer goes to a fresh "(rescued)" sibling, clobbering
        // nothing.
        let (root, article, session) = try makeSessionBook()
        XCTAssertTrue(session.select(article))
        session.edit("# Mine\n")
        // Occupy the first rescue name to prove the copy never overwrites.
        let taken = root.appendingPathComponent("01-Scene (rescued).md")
        try Data("occupied".utf8).write(to: taken)

        let rescued = try XCTUnwrap(session.writeRescueCopy(for: article))
        XCTAssertEqual(rescued.lastPathComponent, "01-Scene (rescued 2).md")
        XCTAssertEqual(try String(contentsOf: rescued, encoding: .utf8), "# Mine\n")
        XCTAssertEqual(try String(contentsOf: taken, encoding: .utf8), "occupied")
        // The rescue is a copy, not a save: the buffer is still dirty.
        XCTAssertTrue(session.dirty)
        session.closeBook()
    }

    @MainActor
    func testBookFlushGateSavesTheBufferBeforeCompile() throws {
        // The File menu's book output actions can't reach the session
        // directly — the flush travels as a synchronous notification, and
        // the buffer must be on disk by the time the post returns.
        let (_, article, session) = try makeSessionBook()
        XCTAssertTrue(session.select(article))
        session.edit("# Through the gate\n")

        let gate = BookFlushGate()
        NotificationCenter.default.post(name: BookFlushGate.request, object: gate)
        XCTAssertFalse(gate.vetoed)
        XCTAssertEqual(try String(contentsOf: article, encoding: .utf8), "# Through the gate\n")
        XCTAssertFalse(session.dirty)
        session.closeBook()
    }

    @MainActor
    func testBookFlushGateVetoesWhenTheSaveFails() throws {
        // A compile must never ship a stale page: when the flush cannot
        // land, the gate is vetoed and the output action aborts.
        let (_, article, session) = try makeSessionBook()
        XCTAssertTrue(session.select(article))
        session.edit("# Unsavable\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: article.path)

        let gate = BookFlushGate()
        NotificationCenter.default.post(name: BookFlushGate.request, object: gate)
        XCTAssertTrue(gate.vetoed)
        // Nothing was lost: the buffer is still the session's to save.
        XCTAssertEqual(session.text, "# Unsavable\n")
        XCTAssertTrue(session.dirty)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: article.path)
        session.closeBook()
        XCTAssertEqual(try String(contentsOf: article, encoding: .utf8), "# Unsavable\n")
    }

    @MainActor
    func testSessionRoundTripsLegacyEncoding() throws {
        let (root, _, session) = try makeSessionBook()
        let legacy = root.appendingPathComponent("03-Legacy.md")
        let original = "Привет, мир!"
        try original.data(using: .windowsCP1251)!.write(to: legacy)

        XCTAssertTrue(session.select(legacy))
        XCTAssertEqual(session.text, original)
        session.edit(original + " Ещё.")
        XCTAssertTrue(session.flushNow())
        // The save stayed in the file's own encoding.
        XCTAssertEqual(try Data(contentsOf: legacy),
                       (original + " Ещё.").data(using: .windowsCP1251)!)
        session.closeBook()
    }
}

// Equatable conformance for assertions on alignment arrays.
extension ColumnAlignment: Equatable {}
