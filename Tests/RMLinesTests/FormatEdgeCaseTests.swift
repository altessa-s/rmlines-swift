// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import Testing
@testable import RMLines

// Less common things the format carries: the second form of a highlight, the
// highlighter's own indexes for blue and orange, the nested ticked checkbox,
// the markers of typed text whose string is not text, and the stamped column
// width. The pages here are built by hand to the layout the tablet's reader
// and writer agree on.

private func block(type: UInt8, version: UInt8 = 1, _ payload: [UInt8]) -> [UInt8] {
    var out = withUnsafeBytes(of: UInt32(payload.count).littleEndian) { Array($0) }
    out += [0, version, version, type]
    return out + payload
}

private func page(_ blocks: [UInt8]...) -> Data {
    Data(RMParser.header.utf8) + Data(blocks.flatMap { $0 })
}

/// One record of the text list: a string, and the marker code when there is
/// one — the tablet writes the code only when it is not nought.
private struct Record {
    var id: WriterID
    var left: WriterID
    var text: String
    var code: UInt32?
    var deleted: UInt32 = 0
    /// Bytes the value claims beyond what it holds, and the bytes that stand
    /// after the record in the list — a malformed record, for the bounds.
    var overclaim: UInt32 = 0
    var trailing: [UInt8] = []
}

private func rootText(_ records: [Record], width: Float = 936, settingsWidth: Float? = nil) -> [UInt8] {
    var list = RMBinaryWriter()
    list.append(varuint: UInt64(records.count))
    for record in records {
        var value = RMBinaryWriter()
        value.append(string: record.text)
        if let code = record.code {
            value.appendTag(index: 2, type: 0x4)
            value.append(uint32: code)
        }
        var item = RMBinaryWriter()
        item.appendID(index: 2, record.id)
        item.appendID(index: 3, record.left)
        item.appendID(index: 4, (0, 0))
        item.appendTag(index: 5, type: 0x4)
        item.append(uint32: record.deleted)
        item.appendTag(index: 6, type: 0xC)
        item.append(uint32: UInt32(value.bytes.count) + record.overclaim)
        item.append(contentsOf: value.bytes)
        list.appendBlock(index: 0, item.bytes)
        list.append(contentsOf: record.trailing)
    }
    var inner = RMBinaryWriter()
    inner.appendBlock(index: 1, list.bytes)
    var items = RMBinaryWriter()
    items.appendBlock(index: 1, inner.bytes)

    var text = RMBinaryWriter()
    text.appendID(index: 1, (0, 0))
    text.appendBlock(index: 2, items.bytes)
    var position = RMBinaryWriter()
    position.append(double: Double(-width / 2))
    position.append(double: 234)
    text.appendBlock(index: 3, position.bytes)
    text.appendTag(index: 4, type: 0x4)
    text.append(float: width)
    if let settingsWidth {
        var stamped = RMBinaryWriter()
        stamped.appendStamped(index: 1, by: (1, 2), float: settingsWidth)
        text.appendBlock(index: 5, stamped.bytes)
    }
    return block(type: 0x07, text.bytes)
}

@Test("A link's opening marker adds no letters, and the text past it stays in order")
func linkMarkersAreNotText() throws {
    // `ab`, the link `cd` and `e`. The opening marker's string is the
    // address; read as text it would land on the page, and counted as
    // characters it would move the cursor past `cd`'s `left`.
    let records = [
        Record(id: (1, 10), left: (0, 0), text: "ab"),
        Record(id: (1, 12), left: (1, 11), text: "https://example.com", code: 5),
        Record(id: (1, 13), left: (1, 12), text: "cd"),
        Record(id: (1, 15), left: (1, 14), text: "", code: 6),
        Record(id: (1, 16), left: (1, 15), text: "e"),
    ]
    // Shuffled, so that only the `left` links can put them back in order.
    let parsed = try RMParser.parsePage(page(rootText([records[2], records[4], records[0], records[3], records[1]])))
    #expect(parsed.text?.lines == ["abcde"])
}

@Test("An image in the flow of the text is one object replacement character")
func inlineImageIsOneCharacter() throws {
    let records = [
        Record(id: (1, 20), left: (0, 0), text: "x\n"),
        Record(id: (1, 22), left: (1, 21), text: "{0a418e1a-1111-4222-8333-444455556666}", code: 0xFFFF_FFFF),
        Record(id: (1, 23), left: (1, 22), text: "\ny"),
    ]
    let parsed = try RMParser.parsePage(page(rootText(records)))
    #expect(parsed.text?.lines == ["x", "\u{FFFC}", "y"])
}

@Test("A code of nought is plain text")
func codeZeroIsText() throws {
    let parsed = try RMParser.parsePage(page(rootText([
        Record(id: (1, 30), left: (0, 0), text: "plain", code: 0),
    ])))
    #expect(parsed.text?.lines == ["plain"])
}

@Test("A value that claims more than its record holds finds no marker past it")
func markerOutsideTheRecordIsIgnored() throws {
    // `24 05 00 00 00` — a link's opening code — lying past the record's end,
    // inside the list. Read as this record's marker it would turn `plain`
    // into nothing.
    let parsed = try RMParser.parsePage(page(rootText([
        Record(id: (1, 60), left: (0, 0), text: "plain", overclaim: 5, trailing: [0x24, 0x05, 0, 0, 0]),
    ])))
    #expect(parsed.text?.lines == ["plain"])
}

@Test("The stamped width of the settings wins over the legacy one")
func settingsWidthWins() throws {
    let records = [Record(id: (1, 40), left: (0, 0), text: "w")]
    let stamped = try RMParser.parsePage(page(rootText(records, width: 936, settingsWidth: 1152)))
    #expect(stamped.text?.columnWidth == 1152)
    let legacy = try RMParser.parsePage(page(rootText(records, width: 936)))
    #expect(legacy.text?.columnWidth == 936)
    // A settings width that is no width leaves the legacy one standing.
    let zero = try RMParser.parsePage(page(rootText(records, width: 740, settingsWidth: 0)))
    #expect(zero.text?.columnWidth == 740)
}

/// A highlight's block: the preamble, then the value with the colour, one
/// rectangle and whatever tail the case asks for.
private func glyph(color: UInt32, firstLast: Bool, argb: UInt32?) -> [UInt8] {
    var rectangles = RMBinaryWriter()
    rectangles.append(varuint: 1)
    for number in [10.0, 20.0, 30.0, 40.0] { rectangles.append(double: number) }

    var value = RMBinaryWriter()
    value.append(1)                                       // value type: glyph
    if !firstLast {
        value.appendTag(index: 2, type: 0x4)
        value.append(uint32: 0)
        value.appendTag(index: 3, type: 0x4)
        value.append(uint32: 4)
    }
    value.appendTag(index: 4, type: 0x4)
    value.append(uint32: color)
    value.appendBlock(index: 6, rectangles.bytes)
    if firstLast {
        value.appendID(index: 7, (1, 300))
        value.appendID(index: 8, (1, 304))
        value.appendTag(index: 9, type: 0x1)
        value.append(1)
    }
    if let argb {
        value.appendTag(index: 10, type: 0x4)
        value.append(uint32: argb)
    }

    var item = RMBinaryWriter()
    item.appendID(index: 1, (0, 11))
    item.appendID(index: 2, (1, 50))
    item.appendID(index: 3, (0, 0))
    item.appendID(index: 4, (0, 0))
    item.appendTag(index: 5, type: 0x4)
    item.append(uint32: 0)
    item.appendBlock(index: 6, value.bytes)
    return block(type: 0x03, item.bytes)
}

@Test("Both forms of a highlight keep their explicit colour")
func highlightFormsKeepArgb() throws {
    for firstLast in [false, true] {
        let parsed = try RMParser.parsePage(page(glyph(color: 9, firstLast: firstLast, argb: 0xFFBE_EAFE)))
        #expect(parsed.highlights.count == 1)
        #expect(parsed.highlights.first?.argb == 0xFFBE_EAFE, "first/last form: \(firstLast)")
        #expect(parsed.highlights.first?.rectangles == [CGRect(x: 10, y: 20, width: 30, height: 40)])
    }
}

@Test("The highlighter's blue and orange read under their own indexes")
func highlighterIndexes() throws {
    let blue = try RMParser.parsePage(page(glyph(color: 14, firstLast: true, argb: nil)))
    #expect(blue.highlights.first?.color == .highlighterBlue)
    #expect(blue.highlights.first?.argb == nil)

    let written = try RMWriter.page(
        RMPageDraft(
            author: UUID(),
            sheet: .init(screenWidth: 1404, screenHeight: 1872, canvasWidth: 1404, canvasHeight: 1872),
            column: .init(.medium),
            paragraphs: [],
            strokes: [
                RMPageDraft.Stroke(tool: .highlighter2, color: .highlighterOrange, points: [
                    RMPageDraft.Point(x: 0, y: 0),
                    RMPageDraft.Point(x: 10, y: 0),
                ]),
            ]
        )
    )
    #expect(try RMParser.parsePage(written).strokes.first?.color == .highlighterOrange)
}

@Test("A nested ticked checkbox is a checkbox item and keeps its level")
func nestedTickedCheckbox() {
    #expect(ParagraphStyle(rawValue: 9) == .checkboxCheckedNested)
    #expect(ParagraphStyle.checkboxCheckedNested.listFamily == .checkbox)
    #expect(ParagraphStyle.checkboxCheckedNested.isListItem)
    #expect(ParagraphFormat(raw: 9, second: 3, third: 0x12).level == 3)
    #expect(ParagraphStyle(rawValue: 12) == .imageBlock)
    #expect(!ParagraphStyle.imageBlock.isListItem)
}

// MARK: - Sample pages

// Pages written on the tablet. The highlighter's blue and orange are written
// as their own indexes with no `argb`, and a highlight over typed text comes
// in the second form — `first`/`last`/`includeLastId` instead of
// `start`/`length`.

private func samplePage(_ name: String) throws -> RMPage {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "rm", subdirectory: "Fixtures"))
    return try RMParser.parsePage(Data(contentsOf: url))
}

@Test("A sample page's blue and orange highlighter strokes keep their colours")
func sampleHighlighterIndexes() throws {
    let page = try samplePage("highlighter-blue-orange")
    #expect(page.skippedBlocks == 0)
    let highlighter = page.strokes.filter { $0.tool == .highlighter2 }
    #expect(highlighter.filter { $0.color == .highlighterBlue }.count == 2)
    #expect(highlighter.filter { $0.color == .highlighterOrange }.count == 2)
    #expect(highlighter.allSatisfy { $0.argb == nil }, "the tablet writes the index alone")
    // The shader keeps index 9 and the whole colour in `argb`.
    let shader = page.strokes.filter { $0.tool == .shader }
    #expect(shader.count == 3)
    #expect(shader.allSatisfy { $0.color == .highlight && $0.argb != nil })
}

@Test("A sample page's highlights in the second form keep their explicit colour")
func sampleSecondFormHighlights() throws {
    let page = try samplePage("glyph-first-last-text")
    #expect(page.skippedBlocks == 0)
    #expect(page.highlights.count == 2)
    #expect(page.highlights.allSatisfy { $0.color == .green && $0.argb == 0xFF00_0000 })
    // The text's width, from the stamped settings, equal to the legacy copy.
    #expect(page.text?.columnWidth == 740)
    #expect(page.text?.formats[2]?.style == .checkbox)
}

@Test("A sample page's checkboxes are shown ticked, partial or unticked as the tablet shows them")
func sampleCheckboxStates() throws {
    // Two first-level items, each with two nested ones: under the first both
    // are ticked, under the second one of two. The tablet draws the first
    // parent ticked and struck through, the second with a dash —
    // while both keep style 6.
    let text = try #require(try samplePage("checkbox-states").text)
    #expect(text.formats[1]?.style == .checkbox)
    #expect(text.formats[1]?.hasTickedNestedItems == true)
    #expect(text.checkboxState(ofLine: 1) == .ticked)
    #expect(text.formats[2]?.style == .checkboxCheckedNested)
    #expect(text.checkboxState(ofLine: 2) == .ticked)
    #expect(text.checkboxState(ofLine: 3) == .partial)
    #expect(text.checkboxState(ofLine: 4) == .unticked)
    #expect(text.checkboxState(ofLine: 5) == .ticked)
    #expect(text.checkboxState(ofLine: 0) == nil, "plain text has no checkbox")
    // A parent with nothing ticked under it carries no `tag 3` at all.
    #expect(text.formats[6]?.third == nil)
    #expect(text.formats[6]?.hasTickedNestedItems == false)
    #expect(text.checkboxState(ofLine: 6) == .unticked)
    #expect((7...9).allSatisfy { text.checkboxState(ofLine: $0) == .unticked })
    #expect((1...5).allSatisfy { text.formats[$0]?.level == ($0 == 1 || $0 == 3 ? 1 : 2) })
}

@Test("Without state bits a parent reads its nested items, and the style alone still ticks a leaf")
func checkboxStateRules() {
    let text = TextBlock(
        originX: 0,
        originY: 0,
        lines: ["parent", "child", "old-style ticked"],
        formats: [
            // A page without the state bits: the parent says nothing,
            // its nested item is ticked by style alone.
            0: ParagraphFormat(raw: 6),
            1: ParagraphFormat(raw: 9, second: 3, third: 0x011),
            2: ParagraphFormat(style: .checkboxChecked),
        ]
    )
    #expect(text.checkboxState(ofLine: 0) == .partial)
    #expect(text.checkboxState(ofLine: 1) == .ticked)
    #expect(text.checkboxState(ofLine: 2) == .ticked)
}

@Test("The pieces of an erased shader stroke name the stroke they were cut from")
func samplePiecesCarryTheirSource() throws {
    // A shader stroke `1:17` cut by the eraser, one of its pieces cut again;
    // a separate shader stroke `1:16` beside it; later shader strokes in
    // another colour; ballpoint lines over them.
    let page = try samplePage("shader-erased")
    #expect(page.skippedBlocks == 0)
    let source = SceneItemID(author: 1, counter: 17)
    let pieces = page.strokes.filter { $0.sourceId == source }
    #expect(pieces.count == 4)
    #expect(pieces.allSatisfy { $0.tool == .shader })
    // Every other stroke carries none — the separate shader stroke included.
    #expect(page.strokes.filter { $0.sourceId == nil }.count == page.strokes.count - 4)
    #expect(page.strokes.first { $0.id == SceneItemID(author: 1, counter: 16) }?.sourceId == nil)
}

@Test("A sample ballpoint stroke keeps the pen's speed, which the tablet's ink reads")
func sampleBallpointSpeed() throws {
    // The tablet thins the second ballpoint's ink by the speed field, so
    // the reader must keep it — whole numbers, as the `uint16` was written.
    let page = try samplePage("shader-erased")
    let points = page.strokes.filter { $0.tool == .ballpoint2 }.flatMap(\.points)
    #expect(!points.isEmpty)
    #expect(points.contains { $0.speed > 0 })
    #expect(points.allSatisfy { $0.speed >= 0 && $0.speed <= 65535 && $0.speed.rounded() == $0.speed })
}
