// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// Edits made to a page the tablet wrote, in place.
///
/// Not the writer. `RMWriter` composes a new page from a draft, and a page
/// composed anew has lost what makes it the tablet's: the identifiers every
/// item is known by, the chain the items hang in, the counters the tablet
/// merges by. An edit here leaves all of that as it was and rewrites only
/// the blocks it was asked about; every other byte of the page goes out as
/// it came in.
public enum RMEditor {
    /// Why an edit was refused. Nothing is written when it is.
    @frozen
    public enum EditError: Error, Sendable, Equatable {
        /// These items are not on the page as living strokes or highlights:
        /// the page is not the one they were read from, or they are gone
        /// already. The edit does not guess which.
        case itemsNotFound(Set<SceneItemID>)
        /// The edited page did not read back as the edit meant it to — the
        /// last check before the bytes leave, and a refusal rather than a
        /// page that might be damaged.
        case unverified(String)
        /// This many blocks of the page would not read, so what the page
        /// holds cannot be told in full.
        case incompletePage(Int)
    }

    /// The page with these strokes and highlights erased, the way the
    /// tablet's own eraser does it.
    ///
    /// An erased item stays in the page as a tombstone: the same block, the
    /// same identifier, parent and neighbours, a deleted length of one, and
    /// no value. That is the shape the tablet writes for every erased
    /// stroke, and it has to be
    /// kept rather than the block dropped: a later item may hang its `left`
    /// on this one, and the tablet merges pages by these identifiers.
    ///
    /// The block's header keeps its versions and its unknown byte; only the
    /// length changes. Every other block, and whatever trails the last one,
    /// is copied byte for byte.
    ///
    /// Every identifier asked for must name a living stroke (`0x05`) or
    /// highlight (`0x03`) of this page, or nothing is erased
    /// (`EditError.itemsNotFound`). The result is read back before it is
    /// handed over: it must parse, lose nothing it did not lose before, and
    /// hold every item it held except the erased ones.
    public static func erasing(_ ids: Set<SceneItemID>, in page: Data) throws -> Data {
        guard !ids.isEmpty else { return page }
        let original = try RMParser.parsePage(page)

        var reader = RMBinaryReader(page)
        let header = try reader.readBytes(RMParser.header.utf8.count)
        guard String(decoding: header, as: UTF8.self) == RMParser.header else {
            // The parse above already said which; this cannot be reached
            // with a page it accepted.
            throw ParseError.unsupportedFormat(String(decoding: header.prefix(32), as: UTF8.self))
        }

        var output = Data(header)
        output.reserveCapacity(page.count)
        var erased: Set<SceneItemID> = []
        while reader.remaining >= 8 {
            let blockStart = reader.offset
            let blockLength = Int(try reader.readUInt32())
            let unknown = try reader.readUInt8()
            let minVersion = try reader.readUInt8()
            let currentVersion = try reader.readUInt8()
            let blockType = try reader.readUInt8()
            let bodyStart = reader.offset
            let blockEnd = bodyStart + blockLength
            guard blockEnd <= reader.count else { throw ParseError.unexpectedEndOfData }

            if blockType == RMParser.sceneLineItemBlock || blockType == RMParser.sceneGlyphItemBlock,
               let kept = try tombstone(of: &reader, before: blockEnd, erasing: ids) {
                erased.insert(kept.id)
                let body = page[(page.startIndex + bodyStart)..<(page.startIndex + kept.deletedAt)]
                output.appendLittleEndian(UInt32(body.count + 4))
                output.append(contentsOf: [unknown, minVersion, currentVersion, blockType])
                output.append(body)
                output.appendLittleEndian(UInt32(1))
            } else {
                output.append(page[(page.startIndex + blockStart)..<(page.startIndex + blockEnd)])
            }
            try reader.seek(to: blockEnd)
        }
        // Fewer bytes than a block header: not a block, and not ours to drop.
        output.append(page[(page.startIndex + reader.offset)...])

        let missing = ids.subtracting(erased)
        guard missing.isEmpty else { throw EditError.itemsNotFound(missing) }
        try verify(output, against: original, erased: erased)
        return output
    }

    /// Every living mark of the highlighter on a page: its strokes, on
    /// every layer — a layer hidden on the tablet included, since showing it
    /// again would bring them back — and its highlights over a text layer.
    ///
    /// What an erase of "everything the marker did" takes. `RMPage` cannot
    /// answer it: the page is what is drawn, and a hidden layer's strokes
    /// are left out of it. Strokes on a layer taken out of the tree are
    /// left out here too — no switch brings them back.
    ///
    /// A page with a block that would not read is refused rather than
    /// answered in part (`EditError.incompletePage`): the block lost may be
    /// a mark, and "every mark" less one is not every mark.
    public static func highlighterItems(in page: Data) throws -> Set<SceneItemID> {
        let blocks = try RMParser.readBlocks(page)
        let lost = blocks.unreadableStrokes + blocks.otherBlocks
        guard lost == 0 else { throw EditError.incompletePage(lost) }
        let tree = RMParser.TreeState(blocks.treeEvents)
        var removed = tree.removed
        // Everything under a removed node goes with it: a group nested in a
        // removed layer is as gone as the layer. Walked with a queue of its
        // own, and each node once, so a cycle in the links ends the walk.
        // A node is under the parent the tree records last put it under:
        // a group item left behind by a move links nothing, and a node
        // moved without a group item of its own is still under its parent.
        let groupLinks = blocks.items.compactMap { item -> (CrdtID, CrdtID)? in
            guard item.deleted == 0, case .group(let child) = item.content,
                  tree.links(item.parent, to: child) else { return nil }
            return (item.parent, child)
        }
        let recordLinks = tree.parentOf.map { child, parent in (parent, child) }
        let childrenOf = Dictionary(grouping: groupLinks + recordLinks, by: \.0)
        var queue = Array(removed)
        while let node = queue.popLast() {
            for (_, child) in childrenOf[node] ?? [] where removed.insert(child).inserted {
                queue.append(child)
            }
        }
        var ids: Set<SceneItemID> = []
        for item in blocks.items where item.deleted == 0 && !removed.contains(item.parent) {
            if case .stroke(let stroke) = item.content, stroke.tool?.isHighlighter == true {
                ids.insert(SceneItemID(item.id))
            }
        }
        for highlight in blocks.highlights {
            if let id = highlight.id { ids.insert(id) }
        }
        return ids
    }

    /// Where a living item's deleted length stands in the page, when the
    /// block the reader is at is one of `ids`; `nil` for any other block.
    /// The reader is left wherever the look took it — the caller seeks to
    /// the block's end.
    private static func tombstone(
        of reader: inout RMBinaryReader,
        before end: Int,
        erasing ids: Set<SceneItemID>
    ) throws -> (id: SceneItemID, deletedAt: Int)? {
        // A block whose preamble does not read is not one we were asked
        // about: the parse that ran first counted it, and it goes out as it
        // came in.
        guard let preamble = try? RMParser.parsePreamble(&reader) else { return nil }
        // The preamble ends with the four bytes of the deleted length.
        let deletedAt = reader.offset - 4
        let id = SceneItemID(preamble.id)
        guard ids.contains(id) else { return nil }
        // Already a tombstone — erased, or a range of erased items — is not
        // a living item, and the request that named it is not about this
        // page as it is.
        guard preamble.deleted == 0, reader.matchValue(before: end) else { return nil }
        return (id, deletedAt)
    }

    /// The edited page read back and held against the page it was made
    /// from.
    private static func verify(_ edited: Data, against original: RMPage, erased: Set<SceneItemID>) throws {
        let page: RMPage
        do {
            page = try RMParser.parsePage(edited)
        } catch {
            throw EditError.unverified("the edited page does not parse: \(error)")
        }
        guard page.skippedBlocks == original.skippedBlocks else {
            throw EditError.unverified(
                "the edited page skips \(page.skippedBlocks) blocks, the original \(original.skippedBlocks)"
            )
        }
        let before = identifiers(of: original)
        let after = identifiers(of: page)
        guard after == before.filter({ $0.map { !erased.contains($0) } ?? true }) else {
            throw EditError.unverified("the edited page does not hold what the original held less the erased")
        }
    }

    /// Every stroke and highlight the page shows, by identifier, in order.
    private static func identifiers(of page: RMPage) -> [SceneItemID?] {
        page.strokes.map(\.id) + page.highlights.map(\.id)
    }
}

// Equality spelled out rather than synthesised, for the reason
// `ParseError`'s is: a `@frozen` enum compared through the derived witness
// fails to link against the binary framework in a debug build.
extension RMEditor.EditError {
    public static func == (a: RMEditor.EditError, b: RMEditor.EditError) -> Bool {
        switch (a, b) {
        case let (.itemsNotFound(x), .itemsNotFound(y)): x == y
        case let (.unverified(x), .unverified(y)): x == y
        case let (.incompletePage(x), .incompletePage(y)): x == y
        default: false
        }
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
