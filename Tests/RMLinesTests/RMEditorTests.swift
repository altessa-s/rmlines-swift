// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMLines
import Testing

// The editor against pages it did not write: the sample corpus, which the
// tablet did, and — where a folder of them is named in
// `RMLINES_REAL_PAGES` — the user's own. An erase has to leave the page
// reading as the tablet would have left it, and every block it was not
// asked about exactly as it was.

/// One block of a page as it lies in the bytes.
private struct Block: Equatable {
    let unknown: UInt8
    let minVersion: UInt8
    let currentVersion: UInt8
    let type: UInt8
    let body: Data
}

private func blocks(of page: Data) -> [Block] {
    let bytes = [UInt8](page)
    var offset = RMParser.header.utf8.count
    var result: [Block] = []
    while offset + 8 <= bytes.count {
        let length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        let start = offset + 8
        result.append(Block(
            unknown: bytes[offset + 4],
            minVersion: bytes[offset + 5],
            currentVersion: bytes[offset + 6],
            type: bytes[offset + 7],
            body: Data(bytes[start..<(start + length)])
        ))
        offset = start + length
    }
    return result
}

private func sample(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.resourceURL)
        .appendingPathComponent("Fixtures/v6-samples/\(name)")
    return try Data(contentsOf: url)
}

private func samples() throws -> [(name: String, data: Data)] {
    let directory = try #require(Bundle.module.resourceURL)
        .appendingPathComponent("Fixtures/v6-samples")
    return try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "rm" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
}

/// Every block of `edited` equal to its counterpart in `original`, save the
/// ones that were erased — and those in the shape the tablet leaves: the
/// same header, the body cut after the deleted length, and that length one.
private func expectOnlyErased(
    _ erased: Int, original: Data, edited: Data, _ name: String
) {
    let before = blocks(of: original)
    let after = blocks(of: edited)
    #expect(before.count == after.count, "\(name)")
    var changed = 0
    for (old, new) in zip(before, after) where old != new {
        changed += 1
        #expect(new.type == old.type && new.unknown == old.unknown, "\(name)")
        #expect(new.minVersion == old.minVersion && new.currentVersion == old.currentVersion, "\(name)")
        #expect(new.type == 0x05 || new.type == 0x03, "\(name)")
        // The preamble kept whole, the count set to one, nothing behind it.
        #expect(new.body.count < old.body.count, "\(name)")
        let kept = new.body.count - 4
        #expect(new.body.prefix(kept) == old.body.prefix(kept), "\(name)")
        #expect([UInt8](new.body.suffix(4)) == [1, 0, 0, 0], "\(name)")
        #expect([UInt8](old.body[old.body.startIndex + kept..<old.body.startIndex + kept + 4]) == [0, 0, 0, 0], "\(name)")
    }
    #expect(changed == erased, "\(name)")
}

/// A block as the page spells one: length, unknown byte, versions, type.
private func block(type: UInt8, versions: (UInt8, UInt8) = (2, 2), _ body: [UInt8]) -> [UInt8] {
    let length = UInt32(body.count)
    return [UInt8(length & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 24)]
        + [0, versions.0, versions.1, type] + body
}

private func le32(_ value: Int) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
}

/// A scene item's preamble: parent, item, left, right, deleted length.
private func preamble(item: UInt8, deleted: UInt8) -> [UInt8] {
    [0x1F, 0, 11, 0x2F, 1, item, 0x3F, 0, 0, 0x4F, 0, 0, 0x54, deleted, 0, 0, 0]
}

private func page(_ blocks: [UInt8]...) -> Data {
    Data(RMParser.header.utf8) + Data(blocks.joined())
}

@Suite("The page editor")
struct RMEditorTests {
    // A tombstone's block ends right behind its preamble, and the next
    // block begins with its length: 108 is `0x6C`, the tag of a value.
    // Read past the block, the tombstone comes back as a stroke whose value
    // is the next block's header, and is counted as lost.
    @Test(
        "A tombstone before a block 108 bytes long is a tombstone",
        arguments: [UInt8(0x05), UInt8(0x03)]
    )
    func tombstoneBeforeA108ByteBlock(type: UInt8) throws {
        let data = page(
            block(type: type, preamble(item: 20, deleted: 1)),
            // The page counters: stepped over by length, never counted.
            block(type: 0x0A, versions: (0, 1), [UInt8](repeating: 0, count: 108))
        )
        let parsed = try RMParser.parsePage(data)
        #expect(parsed.skippedBlocks == 0)
        #expect(parsed.strokes.isEmpty)
        #expect(parsed.highlights.isEmpty)
    }

    // A value that ends before its optional colour: the byte behind it is
    // the next block's length, and 420 spells the colour's tag, `A4 01`.
    @Test("A highlight without a colour takes none from the block after it")
    func highlightColourStaysInsideItsValue() throws {
        let rectangles: [UInt8] = [0x6C, 33, 0, 0, 0, 1] + [UInt8](repeating: 0, count: 32)
        let value: [UInt8] = [0x01, 0x44, 3, 0, 0, 0] + rectangles
        let glyph = preamble(item: 20, deleted: 0) + [0x6C] + le32(value.count) + value
        let data = page(
            block(type: 0x03, versions: (1, 1), glyph),
            block(type: 0x0A, versions: (0, 1), [UInt8](repeating: 0, count: 420))
        )
        let parsed = try RMParser.parsePage(data)
        #expect(parsed.skippedBlocks == 0)
        let highlight = try #require(parsed.highlights.first)
        #expect(highlight.argb == nil)
        #expect(highlight.id == SceneItemID(author: 1, counter: 20))
    }

    @Test("A highlight whose rectangles run past its value is a counted loss")
    func highlightRectanglesStayInsideTheValue() throws {
        // Two rectangles declared, room for one.
        let rectangles: [UInt8] = [0x6C, 33, 0, 0, 0, 2] + [UInt8](repeating: 0, count: 32)
        let value: [UInt8] = [0x01, 0x44, 3, 0, 0, 0] + rectangles
        let glyph = preamble(item: 20, deleted: 0) + [0x6C] + le32(value.count) + value
        let data = page(
            block(type: 0x03, versions: (1, 1), glyph),
            block(type: 0x0A, versions: (0, 1), [UInt8](repeating: 0, count: 64))
        )
        #expect(try RMParser.parsePage(data).skippedBlocks == 1)
    }

    @Test("A highlight with neither a value nor a deletion is a counted loss, not an erasure")
    func undeletedHighlightWithoutValueIsALoss() throws {
        let data = page(block(type: 0x03, versions: (1, 1), preamble(item: 20, deleted: 0)))
        #expect(try RMParser.parsePage(data).skippedBlocks == 1)
    }

    @Test("A highlight whose value will not read is a counted loss")
    func highlightWithBrokenValueIsALoss() throws {
        // A value tag, a length, and then nothing a highlight is made of.
        let data = page(block(type: 0x03, versions: (1, 1), preamble(item: 20, deleted: 0) + [0x6C, 2, 0, 0, 0, 1, 0]))
        #expect(try RMParser.parsePage(data).skippedBlocks == 1)
    }

    @Test("Every stroke and highlight read out of a page carries its own identifier")
    func itemsCarryIdentifiers() throws {
        for (name, data) in try samples() {
            let page = try RMParser.parsePage(data)
            let ids = page.strokes.map(\.id) + page.highlights.map(\.id)
            #expect(!ids.contains(nil), "\(name)")
            #expect(Set(ids).count == ids.count, "\(name)")
        }
    }

    @Test("An identifier spells as author:counter and reads back")
    func identifierSpelling() {
        let id = SceneItemID(author: 2, counter: 1234)
        #expect(id.description == "2:1234")
        #expect(SceneItemID("2:1234") == id)
        #expect(SceneItemID("2:") == nil)
        #expect(SceneItemID("256:1") == nil)
        #expect(SceneItemID("2:1:3") == nil)
    }

    @Test("A highlight over a PDF's text is erased and the rest of the page stays as it was")
    func erasesOneHighlight() throws {
        let data = try sample("Wikipedia_highlighted_p1.rm")
        let page = try RMParser.parsePage(data)
        let target = try #require(page.highlights[1].id)

        let edited = try RMEditor.erasing([target], in: data)
        let after = try RMParser.parsePage(edited)
        #expect(after.highlights.count == page.highlights.count - 1)
        #expect(after.highlights.map(\.id) == page.highlights.map(\.id).filter { $0 != target })
        // A highlight taken off is a tombstone, not a loss.
        #expect(after.skippedBlocks == 0)
        expectOnlyErased(1, original: data, edited: edited, "Wikipedia_highlighted_p1.rm")
    }

    @Test("A stroke is erased as the tablet erases one")
    func erasesOneStroke() throws {
        let data = try sample("Color_and_tool_v3.14.4.rm")
        let page = try RMParser.parsePage(data)
        // One from the middle of the chain: the strokes after it hang on it.
        let target = try #require(page.strokes[page.strokes.count / 2].id)

        let edited = try RMEditor.erasing([target], in: data)
        let after = try RMParser.parsePage(edited)
        #expect(after.strokes.map(\.id) == page.strokes.map(\.id).filter { $0 != target })
        #expect(after.highlights.map(\.id) == page.highlights.map(\.id))
        #expect(after.skippedBlocks == 0)
        expectOnlyErased(1, original: data, edited: edited, "Color_and_tool_v3.14.4.rm")
    }

    @Test("Everything on every sample page erased at once reads back as an empty page")
    func erasesEverything() throws {
        for (name, data) in try samples() {
            let page = try RMParser.parsePage(data)
            let ids = Set((page.strokes.map(\.id) + page.highlights.map(\.id)).compactMap { $0 })
            guard !ids.isEmpty else { continue }
            let edited = try RMEditor.erasing(ids, in: data)
            let after = try RMParser.parsePage(edited)
            #expect(after.strokes.isEmpty, "\(name)")
            #expect(after.highlights.isEmpty, "\(name)")
            #expect(after.skippedBlocks == page.skippedBlocks, "\(name)")
            // The typed text is not the eraser's business.
            #expect(after.text?.lines == page.text?.lines, "\(name)")
            expectOnlyErased(ids.count, original: data, edited: edited, name)
        }
    }

    @Test("An identifier the page does not hold refuses the whole edit")
    func refusesUnknownItems() throws {
        let data = try sample("Wikipedia_highlighted_p1.rm")
        let page = try RMParser.parsePage(data)
        let known = try #require(page.highlights.first?.id)
        let stranger = SceneItemID(author: 9, counter: 999_999)
        #expect(throws: RMEditor.EditError.itemsNotFound([stranger])) {
            try RMEditor.erasing([known, stranger], in: data)
        }
    }

    @Test("An item already erased is not there to erase again")
    func refusesErasingTwice() throws {
        let data = try sample("Wikipedia_highlighted_p1.rm")
        let target = try #require(try RMParser.parsePage(data).highlights.first?.id)
        let once = try RMEditor.erasing([target], in: data)
        #expect(throws: RMEditor.EditError.itemsNotFound([target])) {
            try RMEditor.erasing([target], in: once)
        }
    }

    @Test("Nothing asked, nothing changed")
    func emptyEditIsIdentity() throws {
        let data = try sample("Color_and_tool_v3.14.4.rm")
        #expect(try RMEditor.erasing([], in: data) == data)
    }

    @Test("A page that is not a page is refused as the parser refuses it")
    func refusesGarbage() {
        #expect(throws: ParseError.self) {
            try RMEditor.erasing([SceneItemID(author: 1, counter: 1)], in: Data("not a page".utf8))
        }
    }

    // The user's own pages, when a folder of them is named: every stroke
    // and every highlight erased one at a time — whatever the tool, so that
    // every generation of block header the tablets write goes through it.
    // Off by default: the pages are the user's, and never part of the
    // repository.
    @Test(
        "Real pages: each stroke and highlight erases alone",
        .enabled(if: ProcessInfo.processInfo.environment["RMLINES_REAL_PAGES"] != nil)
    )
    func realPages() throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["RMLINES_REAL_PAGES"]))
        let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "rm" }
        var checked = 0
        for url in files {
            let data = try Data(contentsOf: url)
            guard let page = try? RMParser.parsePage(data) else { continue }
            let marks = page.strokes.compactMap(\.id) + page.highlights.compactMap(\.id)
            for id in marks {
                let edited = try RMEditor.erasing([id], in: data)
                expectOnlyErased(1, original: data, edited: edited, url.lastPathComponent)
                checked += 1
            }
        }
        print("real pages: \(files.count) files, \(checked) items erased one at a time")
    }
}
