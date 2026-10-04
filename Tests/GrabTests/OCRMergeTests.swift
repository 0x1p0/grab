import XCTest
@testable import Grab

final class OCRMergeTests: XCTestCase {
    private func line(_ t: String, _ y: CGFloat, x: CGFloat = 60, w: CGFloat = 460) -> TextLayout.Line {
        TextLayout.Line(text: t, rect: CGRect(x: x, y: y, width: w, height: 16), words: [])
    }

    /// The document pass dropped the first line of a paragraph; the line pass had it.
    func testMissingLineJoinsItsParagraph() {
        var doc = TextLayout()
        doc.paragraphs = [TextLayout.Paragraph(text: "segment. Margins improved", rect: CGRect(x: 60, y: 284, width: 460, height: 16),
                                               lines: [line("segment. Margins improved", 284)])]
        var lines = TextLayout()
        lines.paragraphs = TextReader.cluster([line("Revenue grew 23% year over year", 264), line("segment. Margins improved", 284)])
        TextReader.merge(missingFrom: lines, into: &doc)
        XCTAssertEqual(doc.paragraphs.count, 1)
        XCTAssertEqual(doc.paragraphs[0].text, "Revenue grew 23% year over year\nsegment. Margins improved")
        XCTAssertNotNil(doc.hit(CGPoint(x: 200, y: 270)))
    }

    /// Lines the document pass already has aren't duplicated, and unrelated text
    /// elsewhere becomes its own paragraph.
    func testNoDuplicatesAndSeparateParagraphs() {
        var doc = TextLayout()
        doc.paragraphs = [TextLayout.Paragraph(text: "Title", rect: CGRect(x: 60, y: 100, width: 200, height: 16), lines: [line("Title", 100, w: 200)])]
        var lines = TextLayout()
        lines.paragraphs = TextReader.cluster([line("Title", 101, w: 198), line("Sidebar note", 400, x: 700, w: 150)])
        TextReader.merge(missingFrom: lines, into: &doc)
        XCTAssertEqual(doc.paragraphs.map(\.text), ["Title", "Sidebar note"])
    }

    @MainActor
    func testStrayGlyphsAreNotText() {
        XCTAssertFalse(Session.meaningful("٢"))
        XCTAssertFalse(Session.meaningful("•"))
        XCTAssertTrue(Session.meaningful("OK"))
        XCTAssertTrue(Session.meaningful("Revenue grew"))
    }
}
