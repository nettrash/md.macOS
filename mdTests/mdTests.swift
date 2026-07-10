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
}

// Equatable conformance for assertions on alignment arrays.
extension ColumnAlignment: Equatable {}
