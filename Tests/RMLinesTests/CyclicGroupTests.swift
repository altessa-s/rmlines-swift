// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import Testing
@testable import RMLines

@Test("Hidden and removed groups tolerate cyclic links", arguments: [false, true], [false, true])
func cyclicGroups(hidden: Bool, twoNodes: Bool) throws {
    func group(parent: WriterID, id: WriterID, child: WriterID) -> [UInt8] {
        var body = RMBinaryWriter()
        body.appendID(index: 1, parent)
        body.appendID(index: 2, id)
        body.appendID(index: 3, (0, 0))
        body.appendID(index: 4, (0, 0))
        body.appendTag(index: 5, type: 4)
        body.append(uint32: 0)
        var value = RMBinaryWriter()
        value.append(2)
        value.appendID(index: 2, child)
        body.appendBlock(index: 6, value.bytes)
        return writerBlock(4, body.bytes)
    }

    var state = RMBinaryWriter()
    let blockType: UInt8
    if hidden {
        state.appendID(index: 1, (1, 11))
        state.appendStamped(index: 3, by: (1, 20), u8: 0)
        blockType = 2
    } else {
        state.appendID(index: 1, (1, 20))
        state.appendID(index: 2, (1, 11))
        state.appendTag(index: 3, type: 1)
        state.append(0)
        blockType = 1
    }
    var bytes = Array(RMParser.header.utf8)
    bytes += writerBlock(blockType, state.bytes)
    bytes += group(parent: (0, 1), id: (1, 12), child: (1, 11))
    bytes += group(parent: (1, 11), id: (1, 13), child: twoNodes ? (1, 14) : (1, 11))
    if twoNodes {
        bytes += group(parent: (1, 14), id: (1, 15), child: (1, 11))
    }

    let page = try RMParser.parsePage(Data(bytes))
    #expect(page.strokes.isEmpty)
    #expect(page.images.isEmpty)
    #expect(page.skippedBlocks == 0)
}
