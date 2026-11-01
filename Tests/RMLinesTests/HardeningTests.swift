// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import Testing
@testable import RMLines

// What a page says twice, or says with a number that is not one: the newer of
// two visibility edits wins, a value that is not a number does not reach the
// page, and two styles on one line resolve the same way on every run.

private func page(_ blocks: [UInt8]...) -> Data {
    Data(Array(RMParser.header.utf8) + blocks.joined())
}

/// A layer under the root: its node and its link.
private func layer(_ node: WriterID, link: WriterID) -> [UInt8] {
    var state = RMBinaryWriter()
    state.appendID(index: 1, node)
    var group = RMBinaryWriter()
    group.appendID(index: 1, (0, 1))
    group.appendID(index: 2, link)
    group.appendID(index: 3, (0, 0))
    group.appendID(index: 4, (0, 0))
    group.appendTag(index: 5, type: 4)
    group.append(uint32: 0)
    var value = RMBinaryWriter()
    value.append(2)
    value.appendID(index: 2, node)
    group.appendBlock(index: 6, value.bytes)
    return writerBlock(2, state.bytes) + writerBlock(4, group.bytes)
}

/// One edit of a node's visibility, stamped.
private func visibility(of node: WriterID, by stamp: WriterID, visible: Bool) -> [UInt8] {
    var state = RMBinaryWriter()
    state.appendID(index: 1, node)
    state.appendStamped(index: 3, by: stamp, u8: visible ? 1 : 0)
    return writerBlock(2, state.bytes)
}

/// A stroke under `parent` with the given thickness and point bytes, in point
/// format `version`.
private func stroke(
    _ id: WriterID,
    parent: WriterID,
    thickness: Double = 1,
    version: UInt8 = 2,
    points: [UInt8]
) -> [UInt8] {
    var value = RMBinaryWriter()
    value.append(0x03)
    value.appendTag(index: 1, type: 0x4)
    value.append(uint32: UInt32(PenTool.fineliner2.rawValue))
    value.appendTag(index: 2, type: 0x4)
    value.append(uint32: 0)
    value.appendTag(index: 3, type: 0x8)
    value.append(double: thickness)
    value.appendTag(index: 4, type: 0x4)
    value.append(float: 0)
    value.appendBlock(index: 5, points)
    var line = RMBinaryWriter()
    line.appendID(index: 1, parent)
    line.appendID(index: 2, id)
    line.appendID(index: 3, (0, 0))
    line.appendID(index: 4, (0, 0))
    line.appendTag(index: 5, type: 0x4)
    line.append(uint32: 0)
    line.appendBlock(index: 6, value.bytes)
    return writerBlock(5, minVersion: version, currentVersion: version, line.bytes)
}

private func pointV2() -> [UInt8] {
    var point = RMBinaryWriter()
    point.append(float: 1)
    point.append(float: 2)
    point.append(uint16: 0)
    point.append(uint16: 12)
    point.append(0)
    point.append(100)
    return point.bytes
}

private func pointV1(speed: Float = 2.5, width: Float = 3, pressure: Float = 0.5) -> [UInt8] {
    var point = RMBinaryWriter()
    point.append(float: 1)
    point.append(float: 2)
    point.append(float: speed)
    point.append(float: 0)
    point.append(float: width)
    point.append(float: pressure)
    return point.bytes
}

private let shown: WriterID = (1, 11)

// MARK: - Visibility

@Test("The newer of two visibility edits wins, whatever order the file holds them in")
func visibilityTakesTheNewestEdit() throws {
    let older: WriterID = (1, 90)
    let newer: WriterID = (1, 95)
    let cases: [(edits: [(WriterID, Bool)], drawn: Bool)] = [
        ([(older, false), (newer, true)], true),   // hidden, then shown again
        ([(newer, true), (older, false)], true),   // an old hide arriving late
        ([(older, true), (newer, false)], false),  // shown, then hidden
        ([(newer, false), (older, true)], false),  // an old show arriving late
    ]
    for (index, entry) in cases.enumerated() {
        var blocks = [layer(shown, link: (1, 12))]
        blocks += entry.edits.map { visibility(of: shown, by: $0.0, visible: $0.1) }
        blocks.append(stroke((1, 30), parent: shown, points: pointV2()))
        let parsed = try RMParser.parsePage(page(Array(blocks.joined())))
        #expect(parsed.strokes.count == (entry.drawn ? 1 : 0), "case \(index)")
        #expect(parsed.skippedBlocks == 0, "case \(index): visibility is not a loss")
    }
}

// MARK: - Numbers that are not numbers

@Test("A stroke whose thickness is not a number is a counted loss")
func aNaNThicknessCostsItsStroke() throws {
    for thickness in [Double.nan, .infinity, -.infinity] {
        let parsed = try RMParser.parsePage(page(
            layer(shown, link: (1, 12)),
            stroke((1, 30), parent: shown, thickness: thickness, points: pointV2())
        ))
        #expect(parsed.strokes.isEmpty, "\(thickness)")
        #expect(parsed.skippedBlocks == 1, "\(thickness)")
    }
}

@Test("A version-one point whose pen is not a number costs its stroke")
func aNaNPenCostsItsStroke() throws {
    for points in [pointV1(width: .nan), pointV1(pressure: .infinity), pointV1(width: .greatestFiniteMagnitude)] {
        let parsed = try RMParser.parsePage(page(
            layer(shown, link: (1, 12)),
            stroke((1, 30), parent: shown, version: 1, points: points)
        ))
        #expect(parsed.strokes.isEmpty)
        #expect(parsed.skippedBlocks == 1)
    }
}

@Test("A version-one speed that is no number reads as nought, and the stroke is drawn")
func aNaNSpeedReadsAsNought() throws {
    let cases: [(Float, Float)] = [(2.5, 10), (.greatestFiniteMagnitude, 0), (.infinity, 0), (.nan, 0)]
    for (speed, expected) in cases {
        let parsed = try RMParser.parsePage(page(
            layer(shown, link: (1, 12)),
            stroke((1, 30), parent: shown, version: 1, points: pointV1(speed: speed))
        ))
        let point = try #require(parsed.strokes.first?.points.first, "\(speed)")
        #expect(point.speed == expected, "\(speed)")
    }
}

// MARK: - Text

/// A root text block with its records and its paragraph styles, in the order
/// given.
private func rootText(
    _ records: [(id: WriterID, left: WriterID, text: String)],
    styles: [(key: WriterID, raw: UInt8)] = []
) -> [UInt8] {
    var list = RMBinaryWriter()
    list.append(varuint: UInt64(records.count))
    for record in records {
        var value = RMBinaryWriter()
        value.append(string: record.text)
        var item = RMBinaryWriter()
        item.appendID(index: 2, record.id)
        item.appendID(index: 3, record.left)
        item.appendID(index: 4, (0, 0))
        item.appendTag(index: 5, type: 0x4)
        item.append(uint32: 0)
        item.appendBlock(index: 6, value.bytes)
        list.appendBlock(index: 0, item.bytes)
    }
    var inner = RMBinaryWriter()
    inner.appendBlock(index: 1, list.bytes)

    var styleList = RMBinaryWriter()
    styleList.append(varuint: UInt64(styles.count))
    for style in styles {
        styleList.appendBareID(style.key)
        styleList.appendID(index: 1, (1, 5))
        var value = RMBinaryWriter()
        value.appendTag(index: 1, type: 0x1)
        value.append(style.raw)
        styleList.appendBlock(index: 2, value.bytes)
    }
    var styleInner = RMBinaryWriter()
    styleInner.appendBlock(index: 1, styleList.bytes)

    var both = RMBinaryWriter()
    both.appendBlock(index: 1, inner.bytes)
    both.appendBlock(index: 2, styleInner.bytes)

    var text = RMBinaryWriter()
    text.appendID(index: 1, (0, 0))
    text.appendBlock(index: 2, both.bytes)
    var position = RMBinaryWriter()
    position.append(double: -468)
    position.append(double: 234)
    text.appendBlock(index: 3, position.bytes)
    return writerBlock(7, text.bytes)
}

@Test("Two styles on one line resolve by file order: the later one wins")
func twoStylesOnOneLineTakeTheLater() throws {
    // "ab\ncd": the 'a' (1:20) and the newline (1:22) are both in paragraph 0,
    // so a style keyed by either belongs to line 1.
    let records: [(id: WriterID, left: WriterID, text: String)] = [((1, 20), (0, 0), "ab\ncd")]
    for (first, second) in [((1, 20), (1, 22)), ((1, 22), (1, 20))] as [(WriterID, WriterID)] {
        let parsed = try RMParser.parsePage(page(rootText(
            records,
            styles: [(key: first, raw: ParagraphStyle.heading.rawValue),
                     (key: second, raw: ParagraphStyle.subheading.rawValue)]
        )))
        let text = try #require(parsed.text)
        #expect(text.lines == ["ab", "cd"])
        #expect(text.formats[1]?.raw == ParagraphStyle.subheading.rawValue, "keys \(first), \(second)")
    }
}

@Test("A tree node whose horizontal is not a number keeps its anchor and loses only the horizontal")
func aNaNOriginIsLeftUnset() throws {
    let node: WriterID = (1, 40)
    for spelled in ["stamped", "bare"] {
        var state = RMBinaryWriter()
        state.appendID(index: 1, node)
        var anchor = RMBinaryWriter()
        anchor.appendID(index: 1, (1, 140))
        anchor.appendID(index: 2, (1, 21))
        state.appendBlock(index: 7, anchor.bytes)
        if spelled == "stamped" {
            state.appendStamped(index: 10, by: (1, 141), float: .nan)
        } else {
            state.appendTag(index: 10, type: 0x4)
            state.append(float: .nan)
        }
        var group = RMBinaryWriter()
        group.appendID(index: 1, shown)
        group.appendID(index: 2, (1, 41))
        group.appendID(index: 3, (0, 0))
        group.appendID(index: 4, (0, 0))
        group.appendTag(index: 5, type: 4)
        group.append(uint32: 0)
        var value = RMBinaryWriter()
        value.append(2)
        value.appendID(index: 2, node)
        group.appendBlock(index: 6, value.bytes)

        let parsed = try RMParser.parsePage(page(
            rootText([((1, 20), (0, 0), "abc")]),
            layer(shown, link: (1, 12)),
            writerBlock(2, state.bytes),
            writerBlock(4, group.bytes),
            stroke((1, 50), parent: node, points: pointV2())
        ))
        let stroke = try #require(parsed.strokes.first, "\(spelled)")
        #expect(stroke.anchor?.paragraph == 0 && stroke.anchor?.offset == 2, "\(spelled)")
        #expect(stroke.anchor?.originX == nil, "\(spelled)")
    }
}
