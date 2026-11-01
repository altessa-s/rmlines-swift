// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMLines
import Testing

// The writer against the parser: a draft written and read back must answer
// with the same text, styles, strokes and anchors. This is one half of the
// writer's proof; the other half is the tablet itself, because only the
// tablet can say a page is acceptable.
@Suite("The page writer")
struct RMWriterTests {
    private func sampleDraft() -> RMPageDraft {
        RMPageDraft(
            author: UUID(),
            sheet: RMPageDraft.Sheet(
                screenWidth: 1404,
                screenHeight: 1872,
                canvasWidth: 1404,
                canvasHeight: 1872
            ),
            column: RMPageDraft.Column(width: 936, setting: 1),
            paragraphs: [
                RMPageDraft.Paragraph("Heading", style: 2),
                RMPageDraft.Paragraph("Plain body"),
                RMPageDraft.Paragraph("Bold words", bold: true),
            ],
            strokes: [
                RMPageDraft.Stroke(tool: .fineliner2, color: .black, points: [
                    RMPageDraft.Point(x: 0, y: 100),
                    RMPageDraft.Point(x: 50, y: 100),
                    RMPageDraft.Point(x: 100, y: 100),
                ]),
            ],
            marks: [
                RMPageDraft.Mark(
                    anchor: .firstCharacter(paragraph: 1),
                    penOrigin: -464,
                    stroke: RMPageDraft.Stroke(tool: .fineliner2, color: .red, points: [
                        RMPageDraft.Point(x: 0, y: -10),
                        RMPageDraft.Point(x: 40, y: -10),
                    ])
                ),
            ]
        )
    }

    @Test("A written page parses back with its text, styles and strokes")
    func writtenPageRoundTrips() throws {
        let page = try RMParser.parsePage(RMWriter.page(sampleDraft()))
        let text = try #require(page.text)
        #expect(text.lines.count == 3)
        #expect(text.formats.count == 1)
        #expect(page.strokes.count == 2)
    }

    @Test("A placed image survives the round trip with its file and corners")
    func imagesSurviveTheRoundTrip() throws {
        var draft = sampleDraft()
        draft.images = [
            RMPageDraft.Image(
                file: "0a418e1a-1111-4222-8333-444455556666.png",
                key: Array(0 ..< 16),
                x: -50,
                y: 100,
                width: 120,
                height: 80
            ),
        ]
        let page = try RMParser.parsePage(RMWriter.page(draft))
        let image = try #require(page.images.first)
        #expect(image.file == "0a418e1a-1111-4222-8333-444455556666.png")
        #expect(image.vertices.count == 4)
        #expect(image.vertices.first?.x == -50)
        #expect(image.vertices.first?.y == 100)
        // Both strokes stand before the image: it joined the chain last.
        #expect(image.strokesBefore == 2)
    }

    @Test("An image-only page carries no text block, as the tablet writes one")
    func imageOnlyPageHasNoText() throws {
        let draft = RMPageDraft(
            author: UUID(),
            sheet: RMPageDraft.Sheet(
                screenWidth: 1404,
                screenHeight: 1872,
                canvasWidth: 1404,
                canvasHeight: 1872
            ),
            column: RMPageDraft.Column(width: 936, setting: 1),
            paragraphs: [],
            images: [
                RMPageDraft.Image(
                    file: "0a418e1a-1111-4222-8333-444455556666.png",
                    key: Array(0 ..< 16),
                    x: -60,
                    y: 200,
                    width: 120,
                    height: 160
                ),
            ]
        )
        let page = try RMParser.parsePage(RMWriter.page(draft))
        #expect(page.text == nil)
        #expect(page.images.count == 1)
        #expect(page.strokes.isEmpty)
    }

    @Test("An anchored image parses back fastened to its paragraph")
    func anchoredImagesSurviveTheRoundTrip() throws {
        var draft = sampleDraft()
        draft.images = [
            RMPageDraft.Image(
                file: "0a418e1a-1111-4222-8333-444455556666.png",
                key: Array(0 ..< 16),
                x: 40,
                y: 30,
                width: 120,
                height: 80,
                anchor: .firstCharacter(paragraph: 1),
                penOrigin: -464
            ),
        ]
        let page = try RMParser.parsePage(RMWriter.page(draft))
        let image = try #require(page.images.first)
        let anchor = try #require(image.anchor)
        #expect(anchor.paragraph == 1)
        #expect(anchor.originX == -464)
        // The vertices stay the pen's: where they land is the layout's to
        // say, and the parser does not lay text out.
        #expect(image.vertices.first?.x == 40)
        #expect(image.vertices.first?.y == 30)
    }

    @Test("A loose stroke stays loose and a mark stays anchored")
    func anchorsSurviveTheRoundTrip() throws {
        let page = try RMParser.parsePage(RMWriter.page(sampleDraft()))
        let loose = try #require(page.strokes.first)
        #expect(loose.anchor == nil)
        #expect(loose.tool == .fineliner2)
        #expect(loose.color == .black)
        #expect(loose.points.count == 3)
        let marked = try #require(page.strokes.last)
        let anchor = try #require(marked.anchor)
        #expect(anchor.paragraph == 1)
        #expect(marked.color == .red)
        #expect(marked.points.count == 2)
    }

    // The file counts characters as Unicode scalars and spells the length of
    // a record in bytes, and outside ASCII the two are different numbers.
    // Every fixture above is ASCII, where they agree — which is exactly the
    // condition under which a confusion between them would go unseen.
    @Test("Text outside ASCII round-trips, and the anchors after it still land")
    func nonASCIITextSurvivesTheRoundTrip() throws {
        var draft = sampleDraft()
        draft.paragraphs = [
            RMPageDraft.Paragraph("Привет, мир", style: 2),
            RMPageDraft.Paragraph("Ελληνικά and English"),
            RMPageDraft.Paragraph("絵文字 🖋 emoji"),
        ]
        draft.marks = [
            RMPageDraft.Mark(
                anchor: .firstCharacter(paragraph: 2),
                penOrigin: -464,
                stroke: RMPageDraft.Stroke(tool: .fineliner2, color: .red, points: [
                    RMPageDraft.Point(x: 0, y: -10),
                ])
            ),
        ]
        let page = try RMParser.parsePage(RMWriter.page(draft))
        let text = try #require(page.text)
        #expect(text.lines == ["Привет, мир", "Ελληνικά and English", "絵文字 🖋 emoji"])
        #expect(page.skippedBlocks == 0)
        let marked = try #require(page.strokes.last)
        #expect(try #require(marked.anchor).paragraph == 2, "the mark found its paragraph")
    }

    // A draft this writer cannot honour is refused, and refused as an error.
    // This package ships as a framework inside somebody else's process: a
    // trap there takes the host down, and the host can neither catch it nor
    // fall back to anything.
    @Test("Ink fastened to a paragraph that is not there is an error, not a crash")
    func anAnchorPastTheTextIsRefused() throws {
        var draft = sampleDraft()
        draft.marks = [
            RMPageDraft.Mark(
                anchor: .firstCharacter(paragraph: 99),
                penOrigin: 0,
                stroke: RMPageDraft.Stroke(tool: .fineliner2, color: .black, points: [
                    RMPageDraft.Point(x: 0, y: 0),
                ])
            ),
        ]
        #expect(throws: WriteError.anchorOutOfRange(paragraph: 99)) { try RMWriter.page(draft) }

        var withImage = sampleDraft()
        withImage.images = [
            RMPageDraft.Image(
                file: "a.png", key: Array(0 ..< 16), x: 0, y: 0, width: 10, height: 10,
                anchor: .firstCharacter(paragraph: 42), penOrigin: 0
            ),
        ]
        #expect(throws: WriteError.anchorOutOfRange(paragraph: 42)) { try RMWriter.page(withImage) }
    }

    // A `precondition` on the draft's field would end the host process, so
    // the key is refused where the other refusals are, before a byte is
    // written.
    @Test("An image keyed by anything but sixteen bytes is an error, not a crash")
    func aShortImageKeyIsRefused() throws {
        var draft = sampleDraft()
        draft.images = [
            RMPageDraft.Image(
                file: "a.png", key: Array(0 ..< 15), x: 0, y: 0, width: 10, height: 10
            ),
        ]
        #expect(throws: WriteError.imageKeyNotSixteenBytes(count: 15)) { try RMWriter.page(draft) }

        // Set after the fact, the same: the model holds what it is given, and
        // it is the writer that says no.
        var resized = sampleDraft()
        resized.images = [
            RMPageDraft.Image(
                file: "a.png", key: Array(0 ..< 16), x: 0, y: 0, width: 10, height: 10
            ),
        ]
        resized.images[0].key = Array(0 ..< 17)
        #expect(throws: WriteError.imageKeyNotSixteenBytes(count: 17)) { try RMWriter.page(resized) }
    }

    // A block states its length in 32 bits, and a draft past that is refused
    // before a byte is laid out rather than trapping on the conversion. Four
    // gibibytes of draft is no test fixture, so the bound is lowered for it.
    @Test("A draft too large for the format is an error, not a trap")
    func aDraftTooLargeIsRefused() throws {
        var draft = sampleDraft()
        draft.paragraphs = [RMPageDraft.Paragraph(String(repeating: "a", count: 20_000))]
        #expect(throws: WriteError.pageTooLarge(limit: 10_000)) {
            try checkSizeFits(draft, limit: 10_000)
        }
        var picture = sampleDraft()
        picture.images = [
            RMPageDraft.Image(
                file: String(repeating: "f", count: 20_000), key: Array(0 ..< 16),
                x: 0, y: 0, width: 10, height: 10
            ),
        ]
        #expect(throws: WriteError.pageTooLarge(limit: 10_000)) {
            try checkSizeFits(picture, limit: 10_000)
        }
        // At the real bound an ordinary page is nowhere near it.
        try checkSizeFits(sampleDraft())
        _ = try RMWriter.page(sampleDraft())
    }

    // The two sentinels name no paragraph and can never fail to resolve, so a
    // page with no text at all still takes ink hung before and after it.
    @Test("The sentinels resolve on a page with no paragraphs")
    func sentinelAnchorsAlwaysResolve() throws {
        var draft = sampleDraft()
        draft.paragraphs = []
        draft.marks = [.beforeText, .afterText].map { anchor in
            RMPageDraft.Mark(
                anchor: anchor,
                penOrigin: 0,
                stroke: RMPageDraft.Stroke(tool: .fineliner2, color: .black, points: [
                    RMPageDraft.Point(x: 0, y: 0),
                ])
            )
        }
        let page = try RMParser.parsePage(RMWriter.page(draft))
        #expect(page.strokes.count == 3, "one loose stroke and the two marks")
    }

    // Past these the identifier ranges in `DraftID` run into one another and
    // two items are handed one counter — and the file cannot tell two
    // meanings of one counter apart.
    @Test("More items than the counter ranges can name is an error, not a collision")
    func countersThatWouldCollideAreRefused() throws {
        let stroke = RMPageDraft.Stroke(tool: .fineliner2, color: .black, points: [
            RMPageDraft.Point(x: 0, y: 0),
        ])

        var tooManyMarks = sampleDraft()
        tooManyMarks.marks = Array(
            repeating: RMPageDraft.Mark(
                anchor: .beforeText, penOrigin: 0, stroke: stroke
            ),
            count: DraftID.markLimit + 1
        )
        #expect(throws: WriteError.tooManyToNumber(what: "marks", limit: DraftID.markLimit)) {
            try RMWriter.page(tooManyMarks)
        }

        var tooManyStrokes = sampleDraft()
        tooManyStrokes.strokes = Array(repeating: stroke, count: DraftID.looseStrokeLimit + 1)
        #expect(
            throws: WriteError.tooManyToNumber(
                what: "strokes", limit: DraftID.looseStrokeLimit
            )
        ) { try RMWriter.page(tooManyStrokes) }

        var tooMuchText = sampleDraft()
        tooMuchText.paragraphs = [
            RMPageDraft.Paragraph(String(repeating: "a", count: DraftID.characterLimit)),
        ]
        #expect(
            throws: WriteError.tooManyToNumber(
                what: "characters", limit: DraftID.characterLimit
            )
        ) { try RMWriter.page(tooMuchText) }
    }

    // The same draft has to write the same bytes. A page whose text carries
    // a bold or an italic stretch names a second author; a fresh `UUID()`
    // for it on every call would make two writes of one draft differ, rule
    // out a byte-level regression test, and show content-addressed storage
    // a change where there is none.
    @Test("One draft writes one page, byte for byte, however often it is written")
    func theWriterIsDeterministic() throws {
        var plain = sampleDraft()
        plain.paragraphs = [RMPageDraft.Paragraph("No faces here")]
        plain.marks = []
        #expect(try RMWriter.page(plain) == RMWriter.page(plain))

        // The case at stake: faces bring the second author.
        var faced = sampleDraft()
        faced.paragraphs = [
            RMPageDraft.Paragraph("Bold", bold: true),
            RMPageDraft.Paragraph("Italic", italic: true),
        ]
        #expect(try RMWriter.page(faced) == RMWriter.page(faced))

        // Two drafts alike but for the author write different pages, which is
        // what says the derived author really is derived from that one.
        var other = faced
        other.author = UUID()
        #expect(try RMWriter.page(faced) != RMWriter.page(other))
    }

    @Test("A draft that names its own marks author is taken at its word")
    func anExplicitMarksAuthorIsUsed() throws {
        var faced = sampleDraft()
        faced.paragraphs = [RMPageDraft.Paragraph("Bold", bold: true)]
        faced.marks = []

        var named = faced
        named.marksAuthor = UUID(uuidString: "0A418E1A-1111-4222-8333-444455556666")
        #expect(try RMWriter.page(named) == RMWriter.page(named), "and still deterministic")
        #expect(
            try RMWriter.page(named) != RMWriter.page(faced),
            "a named author is not the derived one"
        )

        // A page with no faces names no second author at all, so the field
        // changes nothing there.
        var plain = sampleDraft()
        plain.paragraphs = [RMPageDraft.Paragraph("No faces here")]
        plain.marks = []
        var plainNamed = plain
        plainNamed.marksAuthor = UUID()
        #expect(try RMWriter.page(plain) == RMWriter.page(plainNamed))
    }

    // And the ranges themselves: a limit that does not match where the next
    // range begins is a collision waiting for the draft that reaches it.
    @Test("Each identifier range ends where the next one begins")
    func theRangesAbut() {
        #expect(DraftID.firstCharacter + UInt64(DraftID.characterLimit) == DraftID.firstMark)
        #expect(
            DraftID.firstMark + UInt64(DraftID.markLimit) * DraftID.markStride
                == DraftID.firstLooseStroke
        )
        #expect(
            DraftID.firstLooseStroke + UInt64(DraftID.looseStrokeLimit) == DraftID.firstImage
        )
    }
}
