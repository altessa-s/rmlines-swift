// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import Testing
@testable import RMLines

// What a page that will not wholly parse does. The rule the package is built
// on is that an unreadable piece is a piece and not a page: the rest is kept,
// the loss is counted, and the count is said out loud. Tested here because it
// is the difference between a notebook that opens short and a notebook that
// does not open — and because a loss that is not counted is the failure that
// is found months later in somebody's page.

/// A block envelope as the format writes one: the payload's length, three
/// version bytes, the type, then the payload.
private func block(type: UInt8, _ payload: [UInt8]) -> [UInt8] {
    var out = withUnsafeBytes(of: UInt32(payload.count).littleEndian) { Array($0) }
    out += [0, 1, 1, type]
    return out + payload
}

private func pageWithOneStroke() throws -> Data {
    try RMWriter.page(
        RMPageDraft(
            author: UUID(),
            sheet: .init(screenWidth: 1404, screenHeight: 1872, canvasWidth: 1404, canvasHeight: 1872),
            column: .init(.medium),
            paragraphs: [RMPageDraft.Paragraph("Body")],
            strokes: [
                RMPageDraft.Stroke(tool: .fineliner2, color: .black, points: [
                    RMPageDraft.Point(x: 0, y: 0),
                    RMPageDraft.Point(x: 10, y: 0),
                ]),
            ]
        )
    )
}

@Test("A stream that ends inside a field is refused, not half-read")
func truncationIsAnError() throws {
    let whole = try pageWithOneStroke()
    // Past the 43-byte header, every cut lands inside a block: the length a
    // block declares does not fit what is left, and believing it would be
    // reading somebody else's bytes as this page's.
    for cut in [60, whole.count / 2, whole.count - 1] {
        #expect(throws: ParseError.unexpectedEndOfData) {
            try RMParser.parsePage(whole.prefix(cut))
        }
    }
}

@Test("A block whose declared length runs past the file is refused")
func blockLengthPastTheEndIsAnError() {
    var bytes = [UInt8](RMParser.header.utf8)
    bytes += [0xFF, 0xFF, 0xFF, 0x7F, 0x00, 0x01, 0x01, 0x05]
    #expect(throws: ParseError.unexpectedEndOfData) { try RMParser.parsePage(Data(bytes)) }
}

@Test("A header and nothing else is an empty page, not a failure")
func aBareHeaderParses() throws {
    let page = try RMParser.parsePage(Data(RMParser.header.utf8))
    #expect(page.strokes.isEmpty)
    #expect(page.skippedBlocks == 0)
}

@Test("A block of an unknown type is stepped over and counted")
func anUnknownBlockIsCounted() throws {
    let whole = try pageWithOneStroke()
    let intact = try RMParser.parsePage(whole)
    #expect(intact.skippedBlocks == 0, "the writer's own page holds nothing we cannot read")

    // A type the format does not define. Counted, because the day one
    // appears is the day this package is behind and has to say so.
    let page = try RMParser.parsePage(whole + Data(block(type: 0x7F, [1, 2, 3, 4])))
    #expect(page.strokes.count == intact.strokes.count, "the rest of the page is kept")
    #expect(page.skippedBlocks == 1)
}

@Test("A stroke that will not parse costs the stroke and not the page")
func anUnreadableStrokeIsCounted() throws {
    // A stroke block whose payload is not a stroke: the preamble's first tag
    // is wrong, so `parseLineItem` throws before it has a point. That it is
    // also said out loud is checked in `RMLinesLogTests`, where the sink is
    // installed under the serialisation that a process-wide sink needs.
    let page = try RMParser.parsePage(
        try pageWithOneStroke() + Data(block(type: 0x05, [UInt8](repeating: 0, count: 24)))
    )
    #expect(page.strokes.count == 1, "the stroke that did parse is still on the page")
    #expect(page.skippedBlocks == 1, "and the one that did not is counted")
}

// A page with one picture and nothing else, as the writer spells it. Not
// `private`, and neither are the two corruptions below: `RMLinesLogTests`
// parses the same bytes to check that the loss reaches the sink, and the sink
// is process-wide, so that half of the test has to live in the serialised
// suite and cannot be here.
func pageWithOneImage() throws -> Data {
    try RMWriter.page(
        RMPageDraft(
            author: UUID(),
            sheet: .init(screenWidth: 1404, screenHeight: 1872, canvasWidth: 1404, canvasHeight: 1872),
            column: .init(.medium),
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
    )
}

/// The payload of the first block of `type` in a written page, found the
/// way the parser finds it: past the header, envelope by envelope.
private func payloadRange(ofBlockType type: UInt8, in bytes: [UInt8]) -> Range<Int>? {
    var offset = RMParser.header.utf8.count
    while offset + 8 <= bytes.count {
        let length = bytes[offset ..< offset + 4].enumerated().reduce(0) { total, pair in
            total | Int(pair.element) << (8 * pair.offset)
        }
        let start = offset + 8
        guard start + length <= bytes.count else { return nil }
        if bytes[offset + 7] == type { return start ..< start + length }
        offset = start + length
    }
    return nil
}

/// The first place `pattern` stands inside `range`, if it stands anywhere.
private func find(_ pattern: [UInt8], in bytes: [UInt8], within range: Range<Int>) -> Int? {
    guard pattern.count <= range.count else { return nil }
    return (range.lowerBound ... range.upperBound - pattern.count).first { start in
        bytes[start ..< start + pattern.count].elementsEqual(pattern)
    }
}

/// The written page with the vertex count of its image item damaged. The
/// count is the varuint that opens the `tag 3` sub-block of the value: the
/// writer puts sixteen floats there — four corners of `(x, y, u, v)` — and
/// this turns it into twelve, three corners, a placement nothing can be
/// drawn on.
func imagePageWithThreeCorners() throws -> Data {
    var bytes = [UInt8](try pageWithOneImage())
    let item = try #require(payloadRange(ofBlockType: 0x0F, in: bytes), "the page has an image item")
    // `3C`: tag 3, length-prefixed; `41 00 00 00`: one count byte and sixty-four
    // of floats; `10`: sixteen floats.
    let count = try #require(
        find([0x3C, 0x41, 0x00, 0x00, 0x00, 0x10], in: bytes, within: item),
        "and the vertices are where the writer put them"
    )
    bytes[count + 5] = 0x0C
    return Data(bytes)
}

/// The written page with the value type of its one group item damaged. The
/// group item links the layer into the root; its value is type `02` followed
/// by the node's identifier under `tag 2`, and this makes it a type no scene
/// item has.
func strokePageWithAMistypedGroupItem() throws -> Data {
    var bytes = [UInt8](try pageWithOneStroke())
    let item = try #require(payloadRange(ofBlockType: 0x04, in: bytes), "the page has a group item")
    // `6C`: tag 6, length-prefixed; the four bytes of length are whatever the
    // identifier takes; `02 2F`: a group's type, then tag 2 as an identifier.
    let value = try #require(
        (item.lowerBound ..< item.upperBound - 6).first { start in
            bytes[start] == 0x6C && bytes[start + 5] == 0x02 && bytes[start + 6] == 0x2F
        },
        "and the value is where the writer put it"
    )
    bytes[value + 5] = 0x09
    return Data(bytes)
}

// "Loss is numbered, deletion is not." An item whose value is there but not of
// its shape is not a tombstone — the answer for "the user erased this",
// which vanishes from the page with the count untouched. It costs the item,
// and the cost is counted.
@Test("An image item with the wrong number of corners is a counted loss, not an erasure")
func aMalformedImageItemIsCounted() throws {
    let intact = try RMParser.parsePage(try pageWithOneImage())
    #expect(intact.images.count == 1)
    #expect(intact.skippedBlocks == 0)

    let page = try RMParser.parsePage(try imagePageWithThreeCorners())
    #expect(page.images.isEmpty, "there is no placing a picture on three corners")
    #expect(page.skippedBlocks == 1, "and the picture that is not there is counted")
}

// A vertex count that claims more floats than its list holds is refused
// before a float is read: read on its word, the list would run into the
// blocks after it and take their bytes for corners.
@Test("An image whose vertex count overruns its list is a counted loss")
func anImageVertexCountPastItsListIsCounted() throws {
    var bytes = [UInt8](try pageWithOneImage())
    let item = try #require(payloadRange(ofBlockType: 0x0F, in: bytes), "the page has an image item")
    let count = try #require(
        find([0x3C, 0x41, 0x00, 0x00, 0x00, 0x10], in: bytes, within: item),
        "and the vertices are where the writer put them"
    )
    bytes[count + 5] = 0x11  // seventeen: one float past the list
    let page = try RMParser.parsePage(Data(bytes))
    #expect(page.images.isEmpty)
    #expect(page.skippedBlocks == 1)
}

@Test("A group item whose value is not a group is a counted loss, and the ink is kept")
func aMistypedGroupItemIsCounted() throws {
    let page = try RMParser.parsePage(try strokePageWithAMistypedGroupItem())
    // The layer comes unhooked from the tree and its stroke falls back to
    // file order: kept, because order is worth less than the ink.
    #expect(page.strokes.count == 1)
    #expect(page.skippedBlocks == 1)
}

// A page built to be hostile rather than broken: it parses, and the question
// is what it costs. Every text record names the same `left` and the same
// `id` and carries no characters, so the ordering walk comes back to one tie
// on every record of the page.
//
// A walk that rescans the tie is quadratic in the records, and the file
// chooses how many there are. A `.rm` arrives from a device or a sync service and is parsed inside an application and its
// extensions, in a task nothing interrupts, so that is not a slow parse but
// a hang somebody else gets to choose.
private func tiedTextPage(records: Int) -> Data {
    var rows = RMBinaryWriter()
    rows.append(varuint: UInt64(records))
    for _ in 0..<records {
        var body = RMBinaryWriter()
        body.appendID(index: 2, (0, 0))          // id
        body.appendID(index: 3, (0, 0))          // left — the walk's own start
        body.appendID(index: 4, (0, 0))          // right
        body.appendTag(index: 5, type: 0x4)
        body.append(uint32: 0)                   // nothing deleted: span 0
        var value = RMBinaryWriter()
        value.append(string: "")
        body.appendBlock(index: 6, value.bytes)
        rows.appendBlock(index: 0, body.bytes)
    }
    var list = RMBinaryWriter()
    list.appendBlock(index: 1, rows.bytes)
    var container = RMBinaryWriter()
    container.appendBlock(index: 1, list.bytes)

    var text = RMBinaryWriter()
    text.appendID(index: 1, (1, 1))
    text.appendBlock(index: 2, container.bytes)
    var position = RMBinaryWriter()
    position.append(double: -468)
    position.append(double: 234)
    text.appendBlock(index: 3, position.bytes)

    var file = RMBinaryWriter()
    file.append(contentsOf: Array(RMParser.header.utf8))
    file.append(contentsOf: writerBlock(0x07, text.bytes))
    return Data(file.bytes)
}

@Test("A page of one enormous tie is read in time proportional to its size")
func aTiedPageDoesNotHang() throws {
    let records = 20_000
    let page = tiedTextPage(records: records)

    let started = Date()
    _ = try RMParser.parsePage(page)
    let elapsed = Date().timeIntervalSince(started)

    // Generous on purpose: the deadline catches a quadratic walk, not a slow
    // machine.
    #expect(
        elapsed < 5,
        "\(records) tied records took \(elapsed)s — the ordering walk has gone quadratic"
    )
}
