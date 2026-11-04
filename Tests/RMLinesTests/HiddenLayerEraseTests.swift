// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import Testing
@testable import RMLines

// The marker on a layer the user hid on the tablet: not drawn, so not on
// the page `parsePage` answers with — and still on the tablet, where showing
// the layer brings it back. An erase of every mark has to find it.

/// A layer node, hidden or shown, and its link into the root.
private func layer(_ node: WriterID, hidden: Bool, link: WriterID) -> [UInt8] {
    var state = RMBinaryWriter()
    state.appendID(index: 1, node)
    if hidden { state.appendStamped(index: 3, by: (1, 90), u8: 0) }
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

/// A stroke of `tool` under `parent`, two points long.
private func stroke(_ id: WriterID, parent: WriterID, tool: PenTool) -> [UInt8] {
    var value = RMBinaryWriter()
    value.append(0x03)
    value.appendTag(index: 1, type: 0x4)
    value.append(uint32: UInt32(tool.rawValue))
    value.appendTag(index: 2, type: 0x4)
    value.append(uint32: 0)
    value.appendTag(index: 3, type: 0x8)
    value.append(double: 1)
    value.appendTag(index: 4, type: 0x4)
    value.append(float: 0)
    var points = RMBinaryWriter()
    for x: Float in [0, 100] {
        points.append(float: x)
        points.append(float: 200)
        points.append(uint16: 0)
        points.append(uint16: 60)
        points.append(0)
        points.append(255)
    }
    value.appendBlock(index: 5, points.bytes)
    var line = RMBinaryWriter()
    line.appendID(index: 1, parent)
    line.appendID(index: 2, id)
    line.appendID(index: 3, (0, 0))
    line.appendID(index: 4, (0, 0))
    line.appendTag(index: 5, type: 0x4)
    line.append(uint32: 0)
    line.appendBlock(index: 6, value.bytes)
    return writerBlock(5, minVersion: 2, currentVersion: 2, line.bytes)
}

/// A layer taken out of the tree: the record that removes it.
private func removal(of node: WriterID) -> [UInt8] {
    var record = RMBinaryWriter()
    record.appendID(index: 1, (1, 95))
    record.appendID(index: 2, node)
    record.appendTag(index: 3, type: 1)
    record.append(0)
    return writerBlock(1, record.bytes)
}

/// A node put back into the tree under `parent`: a fresh record whose tag 2
/// names the node, as the tablet writes when it moves typed text and the
/// handwriting anchored to it.
private func reinsertion(of node: WriterID, under parent: WriterID) -> [UInt8] {
    var record = RMBinaryWriter()
    record.appendID(index: 1, (1, 96))
    record.appendID(index: 2, node)
    record.appendTag(index: 3, type: 1)
    record.append(1)
    var place = RMBinaryWriter()
    place.appendID(index: 1, parent)
    record.appendBlock(index: 4, place.bytes)
    return writerBlock(1, record.bytes)
}

/// A group item under `parent` that names `child`.
private func link(_ child: WriterID, under parent: WriterID, item: WriterID) -> [UInt8] {
    var group = RMBinaryWriter()
    group.appendID(index: 1, parent)
    group.appendID(index: 2, item)
    group.appendID(index: 3, (0, 0))
    group.appendID(index: 4, (0, 0))
    group.appendTag(index: 5, type: 4)
    group.append(uint32: 0)
    var value = RMBinaryWriter()
    value.append(2)
    value.appendID(index: 2, child)
    group.appendBlock(index: 6, value.bytes)
    return writerBlock(4, group.bytes)
}

private func page(_ blocks: [UInt8]...) -> Data {
    Data(Array(RMParser.header.utf8) + blocks.joined())
}

@Suite("Erasing the marker on hidden layers")
struct HiddenLayerEraseTests {
    let shown: WriterID = (1, 11)
    let hidden: WriterID = (1, 21)

    private func twoLayers() -> Data {
        page(
            layer(shown, hidden: false, link: (1, 12)),
            layer(hidden, hidden: true, link: (1, 22)),
            stroke((1, 30), parent: shown, tool: .highlighter2),
            stroke((1, 31), parent: hidden, tool: .highlighter2),
            stroke((1, 32), parent: hidden, tool: .fineliner2)
        )
    }

    @Test("The marker on a hidden layer is found, the pen beside it is not")
    func findsTheHiddenMarker() throws {
        let data = twoLayers()
        let drawn = try RMParser.parsePage(data)
        // Drawn: the shown layer's marker alone.
        #expect(drawn.strokes.map(\.id) == [SceneItemID(author: 1, counter: 30)])
        #expect(drawn.skippedBlocks == 0)
        #expect(try RMEditor.highlighterItems(in: data) == [
            SceneItemID(author: 1, counter: 30), SceneItemID(author: 1, counter: 31),
        ])
    }

    @Test("The marker on a hidden layer is erased, and the layer keeps its pen")
    func erasesTheHiddenMarker() throws {
        let data = twoLayers()
        let marks = try RMEditor.highlighterItems(in: data)
        let edited = try RMEditor.erasing(marks, in: data)
        #expect(try RMEditor.highlighterItems(in: edited).isEmpty)
        #expect(try RMParser.parsePage(edited).strokes.isEmpty)
        #expect(try RMParser.parsePage(edited).skippedBlocks == 0)

        // Shown again, the layer holds the pen and nothing of the marker.
        let shownAgain = page(
            layer(shown, hidden: false, link: (1, 12)),
            layer(hidden, hidden: false, link: (1, 22)),
            [UInt8](edited.dropFirst(RMParser.header.utf8.count + twoLayersPreambleLength()))
        )
        #expect(try RMParser.parsePage(shownAgain).strokes.map(\.id) == [SceneItemID(author: 1, counter: 32)])
    }

    /// The bytes the two layer declarations take at the head of the page.
    private func twoLayersPreambleLength() -> Int {
        layer(shown, hidden: false, link: (1, 12)).count + layer(hidden, hidden: true, link: (1, 22)).count
    }

    @Test("A layer taken out of the tree is not searched: nothing brings it back")
    func skipsARemovedLayer() throws {
        let data = page(
            layer(hidden, hidden: false, link: (1, 22)),
            removal(of: hidden),
            stroke((1, 31), parent: hidden, tool: .highlighter2)
        )
        #expect(try RMEditor.highlighterItems(in: data).isEmpty)
    }

    @Test("A layer taken out and put back is drawn and searched again")
    func drawsAReinsertedLayer() throws {
        let data = page(
            layer(hidden, hidden: false, link: (1, 22)),
            removal(of: hidden),
            reinsertion(of: hidden, under: (0, 1)),
            stroke((1, 31), parent: hidden, tool: .highlighter2)
        )
        let drawn = try RMParser.parsePage(data)
        #expect(drawn.strokes.map(\.id) == [SceneItemID(author: 1, counter: 31)])
        #expect(drawn.skippedBlocks == 0)
        #expect(try RMEditor.highlighterItems(in: data) == [SceneItemID(author: 1, counter: 31)])
    }

    @Test("A group moved under a layer later removed goes with that layer")
    func dropsAGroupMovedUnderARemovedLayer() throws {
        let group: WriterID = (1, 41)
        let data = page(
            layer(shown, hidden: false, link: (1, 12)),
            layer(hidden, hidden: false, link: (1, 22)),
            link(group, under: shown, item: (1, 42)),
            reinsertion(of: group, under: hidden),
            removal(of: hidden),
            stroke((1, 31), parent: group, tool: .highlighter2)
        )
        #expect(try RMParser.parsePage(data).strokes.isEmpty)
        #expect(try RMEditor.highlighterItems(in: data).isEmpty)
    }

    @Test("A group moved out of a layer later removed stays")
    func keepsAGroupMovedOutOfARemovedLayer() throws {
        let group: WriterID = (1, 41)
        let data = page(
            layer(shown, hidden: false, link: (1, 12)),
            layer(hidden, hidden: false, link: (1, 22)),
            link(group, under: hidden, item: (1, 42)),
            reinsertion(of: group, under: shown),
            removal(of: hidden),
            stroke((1, 31), parent: group, tool: .highlighter2)
        )
        #expect(try RMParser.parsePage(data).strokes.map(\.id) == [SceneItemID(author: 1, counter: 31)])
        #expect(try RMEditor.highlighterItems(in: data) == [SceneItemID(author: 1, counter: 31)])
    }

    @Test("A group moved and linked under its new layer is drawn there, once")
    func drawsAMovedGroupFromItsNewLayer() throws {
        let group: WriterID = (1, 41)
        let data = page(
            layer(shown, hidden: false, link: (1, 12)),
            layer(hidden, hidden: true, link: (1, 22)),
            link(group, under: hidden, item: (1, 42)),
            link(group, under: shown, item: (1, 43)),
            reinsertion(of: group, under: shown),
            stroke((1, 31), parent: group, tool: .fineliner2)
        )
        // Under the shown layer now: the stale link into the hidden one
        // neither hides it nor draws it a second time.
        #expect(try RMParser.parsePage(data).strokes.map(\.id) == [SceneItemID(author: 1, counter: 31)])
    }

    @Test("A tree record whose parent runs past its block does not read")
    func refusesATruncatedTreeParent() throws {
        var record = RMBinaryWriter()
        record.appendID(index: 1, (1, 96))
        record.appendID(index: 2, hidden)
        record.appendTag(index: 3, type: 1)
        record.append(1)
        record.appendTag(index: 4, type: 0xC)
        let data = page(
            layer(hidden, hidden: false, link: (1, 22)),
            writerBlock(1, record.bytes),
            stroke((1, 31), parent: hidden, tool: .fineliner2)
        )
        let drawn = try RMParser.parsePage(data)
        #expect(drawn.skippedBlocks == 1)
        #expect(drawn.strokes.map(\.id) == [SceneItemID(author: 1, counter: 31)])
    }

    @Test("A group nested in a removed layer is as gone as the layer")
    func skipsWhatIsUnderARemovedLayer() throws {
        let nested: WriterID = (1, 41)
        var link = RMBinaryWriter()
        link.appendID(index: 1, hidden)
        link.appendID(index: 2, (1, 42))
        link.appendID(index: 3, (0, 0))
        link.appendID(index: 4, (0, 0))
        link.appendTag(index: 5, type: 4)
        link.append(uint32: 0)
        var value = RMBinaryWriter()
        value.append(2)
        value.appendID(index: 2, nested)
        link.appendBlock(index: 6, value.bytes)
        let data = page(
            layer(hidden, hidden: false, link: (1, 22)),
            writerBlock(4, link.bytes),
            removal(of: hidden),
            stroke((1, 31), parent: nested, tool: .highlighter2)
        )
        #expect(try RMEditor.highlighterItems(in: data).isEmpty)
    }

    @Test("A page with a block that will not read is refused, not answered in part")
    func refusesAnIncompletePage() throws {
        var broken = stroke((1, 33), parent: shown, tool: .highlighter2)
        // The value's type byte turned into something no stroke is.
        let valueType = try #require(broken.firstIndex(of: 0x03))
        broken[valueType] = 0x7E
        let data = page(
            layer(shown, hidden: false, link: (1, 12)),
            stroke((1, 30), parent: shown, tool: .highlighter2),
            broken
        )
        #expect(try RMParser.parsePage(data).skippedBlocks == 1)
        #expect(throws: RMEditor.EditError.incompletePage(1)) {
            try RMEditor.highlighterItems(in: data)
        }
    }

    @Test("Highlights over a text layer are found with the strokes")
    func findsGlyphHighlights() throws {
        let url = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures/v6-samples/Wikipedia_highlighted_p1.rm")
        let data = try Data(contentsOf: url)
        let drawn = try RMParser.parsePage(data)
        #expect(try RMEditor.highlighterItems(in: data) == Set(drawn.highlights.compactMap(\.id)))
    }
}
