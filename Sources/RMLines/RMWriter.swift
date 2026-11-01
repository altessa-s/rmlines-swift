// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

// Writing what the tablet accepts — the other half of this package's
// charter, and the narrower one. The writer builds **fresh pages only**: it
// never edits an existing file, because inserting into somebody else's CRDT
// chains is a different contract with a user's notebook at stake.
//
// The subset here is exactly what the tablet accepts: a typed-text page with
// anchored and loose strokes, one layer, one author (two with bold or
// italic). A new block type is added only once its bytes are known and the
// tablet accepts ours back — the parser's tolerance is no licence for the
// writer, which must produce what the tablet takes, not what we can read.
//
// The per-block header versions are written down nowhere; the ones
// here are the ones a page typed on the tablet carries. The tablet opens
// pages with other versions too, so they are not a gate — but a generated
// page is worth what it has in common with the tablet's own file, and the
// sheet it declares is not cosmetic at all (`RMPageDraft.Sheet`).

/// What a draft can be refused for.
///
/// Thrown rather than trapped. The draft is built by code and a bad one is
/// the caller's bug, but this package ships as a framework inside somebody
/// else's application: a `preconditionFailure` there takes the host process
/// down, and a host cannot catch it, log it or fall back to anything. An
/// error it can.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum WriteError: Error, Sendable, Equatable {
    /// A mark or a placed image is fastened to a paragraph the draft does not
    /// have. Written anyway, the ink would hang on nothing and vanish without
    /// a trace — silently losing ink is the one thing a writer must never do.
    case anchorOutOfRange(paragraph: Int)
    /// More items of one kind than a page's identifier ranges can name.
    ///
    /// The ranges are laid out in `DraftID`, each starting where the one
    /// before it has room to end. Past the limit the two would overlap and
    /// two different items would be handed one counter — and the file cannot
    /// tell two meanings of one counter apart, so the page would claim two
    /// edits are the same edit.
    case tooManyToNumber(what: String, limit: Int)
    /// A placed image whose key is not the sixteen bytes an attachment key
    /// is. The item and the attachment map name the picture by those bytes
    /// and nothing else; written with a key of another length, the page
    /// would read back with no image at all and count the loss nowhere. The
    /// draft's own length travels along, because it is the one number worth
    /// looking at.
    case imageKeyNotSixteenBytes(count: Int)
    /// A draft too large for the format: a block of the page would run past
    /// the 4 GiB its 32-bit length field can state. `limit` is that bound in
    /// bytes.
    case pageTooLarge(limit: Int)
}

public enum RMWriter {
    /// The whole `.rm` file of one typed-text page: the service four, the
    /// text, and a one-layer scene tree — the inventory of a page the tablet
    /// itself writes for a typed-only notebook.
    ///
    /// The service four go out first and in the tablet's order; `0x07` stands
    /// before the tree — a placement of our own, matching neither the tablet
    /// nor the companions. Block order past the four is the writer's property
    /// and the tablet accepts it as written. Each block is built by
    /// a function of its own below.
    ///
    /// - Throws: `WriteError` when the draft cannot be written as it stands —
    ///   ink fastened to a paragraph that is not there, more items of one
    ///   kind than a page's identifier ranges can name, an image keyed by
    ///   anything but sixteen bytes, or a page too large for the format.
    ///   Nothing is written in any case: a half-page is worse than none.
    public static func page(_ draft: RMPageDraft) throws -> Data {
        try checkSizeFits(draft)
        let text = textBlock(paragraphs: draft.paragraphs, column: draft.column)
        try checkCountersFit(draft, scalars: text.scalars)
        try checkImageKeys(draft)

        var file = RMBinaryWriter()
        file.append(contentsOf: Array(RMParser.header.utf8))
        // A page whose text carries faces names a second author: on a tablet's
        // page the formatting marks are another session's edits, and their
        // author index has to resolve in the table.
        let facesPresent = draft.paragraphs.contains { $0.bold || $0.italic }
        let marks = facesPresent
            ? (draft.marksAuthor ?? marksAuthor(derivedFrom: draft.author))
            : nil
        file.append(contentsOf: writerBlock(0x09, authorsBlock(draft.author, marks: marks)))
        file.append(contentsOf: writerBlock(0x00, migrationBlock()))
        file.append(contentsOf: writerBlock(
            0x0A,
            minVersion: 0,
            pageInfoBlock(scalars: text.scalars, paragraphs: draft.paragraphs.count)
        ))
        file.append(contentsOf: writerBlock(
            0x0D,
            minVersion: 0,
            sceneInfoBlock(
                sheet: draft.sheet,
                column: draft.column,
                hasImages: !draft.images.isEmpty
            )
        ))
        // The attachment map stands between SceneInfo and the scene tree —
        // where the tablet's page with an image keeps it. One map
        // per page, all attachments in it.
        if !draft.images.isEmpty {
            file.append(contentsOf: writerBlock(
                0x0E, minVersion: 3, currentVersion: 3, attachmentMapBlock(draft.images)
            ))
        }
        // A page with no typed text carries no RootText block at all — the
        // tablet's image-only page does not, and a generated page
        // is worth what it has in common with the tablet's own file. Marks
        // and anchored images presuppose text: they anchor to it.
        if !draft.paragraphs.isEmpty || !draft.marks.isEmpty
            || draft.images.contains(where: { $0.anchor != nil }) {
            file.append(contentsOf: writerBlock(0x07, text.bytes))
        }
        file.append(contentsOf: writerBlock(0x01, sceneTreeBlock()))
        file.append(contentsOf: writerBlock(0x02, currentVersion: 2, layerNodeBlock()))
        file.append(contentsOf: writerBlock(0x04, groupItemBlock()))
        // The marks and the loose strokes are one chain, not a heap: items
        // sharing a `left` are a tie, and the format breaks it in favour of
        // the newer one — so anything left unchained comes
        // back in the reverse of the order it was written in. They share the
        // chain because they share a parent: both hang on the layer.
        var previous = DraftID.none
        for (number, stroke) in draft.strokes.enumerated() {
            file.append(contentsOf: writerBlock(
                0x05,
                minVersion: 2,
                currentVersion: 2,
                lineItem(
                    stroke,
                    parent: DraftID.layer,
                    id: looseStrokeID(number),
                    after: previous
                )
            ))
            previous = looseStrokeID(number)
        }
        for (number, mark) in draft.marks.enumerated() {
            // A refusal, not a skip: a mark whose paragraph is not on the
            // page would vanish without a trace, and silently losing ink is
            // the one thing a writer must never do. Thrown and not trapped —
            // a bad index is the caller's bug, but this code runs inside the
            // caller's process and must not end it.
            guard let anchor = anchorID(of: mark.anchor, characters: text.firstCharacters) else {
                throw WriteError.anchorOutOfRange(paragraph: paragraphIndex(of: mark.anchor))
            }
            file.append(contentsOf: anchoredMarkBlocks(
                mark,
                number: number,
                anchor: anchor,
                after: previous
            ))
            previous = MarkIDs(number).item
        }
        for (number, image) in draft.images.enumerated() {
            let ids = ImageIDs(number)
            if let anchor = image.anchor {
                // The same refusal as a mark's, for the same reason.
                guard let named = anchorID(of: anchor, characters: text.firstCharacters) else {
                    throw WriteError.anchorOutOfRange(paragraph: paragraphIndex(of: anchor))
                }
                // The group carries the anchor and the image hangs inside it,
                // alone, the way the tablet writes it: the item's `left` is
                // unset and the group's place in the layer's chain is what
                // orders the drawing.
                file.append(contentsOf: anchoredGroupBlocks(
                    node: ids.node,
                    item: ids.groupItem,
                    stamps: AnchorStamps(
                        anchor: ids.anchor,
                        type: ids.type,
                        threshold: ids.threshold,
                        // The tablet stamps `anchor_origin_x` with the id
                        // of the group's own node, not a fresh counter —
                        // mirrored, like every other byte of the group.
                        origin: ids.node
                    ),
                    anchor: named,
                    penOrigin: image.penOrigin,
                    after: previous
                ))
                file.append(contentsOf: writerBlock(
                    0x0F,
                    minVersion: 2,
                    currentVersion: 2,
                    imageItem(image, ids: ids, parent: ids.node, after: DraftID.none)
                ))
                previous = ids.groupItem
            } else {
                file.append(contentsOf: writerBlock(
                    0x0F,
                    minVersion: 2,
                    currentVersion: 2,
                    imageItem(image, ids: ids, after: previous)
                ))
                previous = ids.item
            }
        }
        return Data(file.bytes)
    }
}

// MARK: - Page assembly

/// The authors a generated page names, and every identifier it hands out.
///
/// In one place because the file cannot tell two meanings of one counter
/// apart: reuse a number and the page claims two edits are the same edit.
///
/// Internal rather than file-private so that the tests can check the ranges
/// abut — a limit that does not match where the next range begins is a
/// collision waiting for the draft that reaches it, and that is worth an
/// assertion rather than a reading.
enum DraftID {
    static let author: UInt8 = 1
    /// The second author index a tablet's page keeps for its formatting
    /// edits: its marks all carry it, and its entry stands first in the
    /// authors table.
    static let marksAuthor: UInt8 = 2
    /// "Not set" — the start of the text, and the stamp of a field nobody
    /// has touched.
    static let none: WriterID = (0, 0)
    static let root: WriterID = (0, 1)
    static let text: WriterID = (author, 1)
    static let layer: WriterID = (author, 11)
    static let groupItem: WriterID = (author, 12)
    static let canvasStamp: WriterID = (author, 13)
    static let columnStamp: WriterID = (author, 14)
    static let widthStamp: WriterID = (author, 15)
    /// Where the characters of the text start counting.
    static let firstCharacter: UInt64 = 20
    /// Where the anchored groups and their strokes start counting. Far above
    /// the text: the characters take one counter each, and a page can run to
    /// thousands of them.
    static let firstMark: UInt64 = 100_000
    /// And where the strokes that hang on nothing start — above the marks,
    /// which take eight counters each.
    static let firstLooseStroke: UInt64 = 200_000
    /// Where the placed images start — above everything else. Each is given
    /// sixteen counters' worth of room and spends eight of them: the item,
    /// its two stamps, and — when it is anchored — the group, its place in
    /// the chain and the stamps of two of its anchor fields.
    static let firstImage: UInt64 = 300_000

    /// How many of each kind fit before one range runs into the next.
    ///
    /// Derived from the starts above rather than written out beside them, so
    /// that moving a start moves its limit with it. `checkCountersFit` is the
    /// one reader; past these the page would name two edits with one counter.
    static let markLimit = Int((firstLooseStroke - firstMark) / markStride)
    static let looseStrokeLimit = Int(firstImage - firstLooseStroke)
    /// The room the characters have before the marks begin — every scalar
    /// takes one, and an empty paragraph still takes one for its newline.
    static let characterLimit = Int(firstMark - firstCharacter)

    static let markStride: UInt64 = 8
    static let imageStride: UInt64 = 16
}

/// The draft against the identifier ranges, before a byte is written.
///
/// Images are not checked: their range is the last one and has nothing above
/// it to run into, and their counters are the author's own — a page would
/// have to carry two hundred million of them to reach anywhere that matters.
private func checkCountersFit(_ draft: RMPageDraft, scalars: Int) throws {
    // Every scalar takes a counter, and a paragraph with no text still takes
    // one for the newline that ends it.
    let characters = scalars + draft.paragraphs.count
    guard characters <= DraftID.characterLimit else {
        throw WriteError.tooManyToNumber(what: "characters", limit: DraftID.characterLimit)
    }
    guard draft.marks.count <= DraftID.markLimit else {
        throw WriteError.tooManyToNumber(what: "marks", limit: DraftID.markLimit)
    }
    guard draft.strokes.count <= DraftID.looseStrokeLimit else {
        throw WriteError.tooManyToNumber(what: "strokes", limit: DraftID.looseStrokeLimit)
    }
}

/// The bytes a block holds per item, above what the item's own content
/// takes: identifiers, tags, lengths and the fixed fields. Generous on
/// purpose — the estimate only has to stay above the truth.
private let overheadPerItem = 512
/// The bytes one point takes in the file.
private let bytesPerPoint = 14

/// The draft against the one bound the format sets on size, before a byte is
/// laid out: every block states its length in 32 bits. The estimate is an
/// upper bound on the whole page, so no block can pass the limit unnoticed.
/// Checked first because laying out the text is itself the step that would
/// meet an oversized paragraph.
func checkSizeFits(_ draft: RMPageDraft, limit: Int = Int(UInt32.max)) throws {
    var total = 4096
    func add(_ bytes: Int) throws {
        total += bytes
        guard total <= limit else { throw WriteError.pageTooLarge(limit: limit) }
    }
    for paragraph in draft.paragraphs {
        try add(paragraph.text.utf8.count + overheadPerItem)
    }
    for stroke in draft.strokes {
        try add(stroke.points.count * bytesPerPoint + overheadPerItem)
    }
    for mark in draft.marks {
        try add(mark.stroke.points.count * bytesPerPoint + 2 * overheadPerItem)
    }
    for image in draft.images {
        try add(image.file.utf8.count + image.key.count + 2 * overheadPerItem)
    }
}

/// Every image key against the one length an attachment key has, before a
/// byte is written.
///
/// Not a `precondition` on the draft's field: a precondition inside a
/// framework ends the host process, which is exactly what the rule at the top
/// of this file forbids. Here it is a refusal the caller can catch, and it
/// stands with the other refusals so that nothing is half-written when it
/// fires.
private func checkImageKeys(_ draft: RMPageDraft) throws {
    for image in draft.images where image.key.count != 16 {
        throw WriteError.imageKeyNotSixteenBytes(count: image.key.count)
    }
}

/// Which paragraph an anchor names, for the error that says it could not be
/// found. The two sentinels name none, and never fail to resolve.
private func paragraphIndex(of anchor: RMPageDraft.Anchor) -> Int {
    switch anchor {
    case .firstCharacter(let paragraph): paragraph
    case .beforeText, .afterText: -1
    }
}

/// The identifier a mark or an anchored image hangs on, and how the tablet
/// describes that kind of anchor: a character, or a boundary between lines.
private func anchorID(
    of anchor: RMPageDraft.Anchor,
    characters: [WriterID]
) -> (id: WriterID, type: UInt8, threshold: Float)? {
    switch anchor {
    case .firstCharacter(let paragraph):
        guard paragraph >= 0, paragraph < characters.count else { return nil }
        return (characters[paragraph], 1, 0)
    case .beforeText:
        // The pen went nowhere near a character, so the anchor is a line
        // boundary — here the one before everything typed. Type and threshold
        // travel as a hard pair, and the threshold is the tablet's own float:
        // 35.75 is how it reads, 35.748031 is what it writes.
        return ((0, 0xFFFF_FFFF_FFFE), 2, lineAnchorThreshold)
    case .afterText:
        return ((0, 0xFFFF_FFFF_FFFF), 2, lineAnchorThreshold)
    }
}

/// The threshold a line anchor carries, as the tablet writes it.
private let lineAnchorThreshold: Float = 35.748031

/// The author the formatting marks are written under, when the draft names
/// none.
///
/// Derived from the page's own author, and derived the same way every time.
/// A fresh `UUID()` would make `RMWriter.page` answer with different bytes
/// for one and the same draft: a byte-level regression test would be
/// impossible, content-addressed storage would see a change on every
/// rewrite, and two pages of one notebook would name different authors for
/// the same kind of edit.
///
/// The value decides nothing that is drawn — only that the marks' author
/// index resolves in the page's table — so the transformation has only to be
/// stable and to differ from the author it came from. The last byte is
/// flipped and nothing else: bytes 6 and 8 carry the version and the variant,
/// and leaving them be is what keeps the result a well-formed UUID rather
/// than sixteen bytes that merely look like one.
private func marksAuthor(derivedFrom author: UUID) -> UUID {
    var bytes = withUnsafeBytes(of: author.uuid) { Array($0) }
    bytes[15] ^= 0x01
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

/// A stroke of no anchor, by its number on the page.
private func looseStrokeID(_ number: Int) -> WriterID {
    (DraftID.author, DraftID.firstLooseStroke + UInt64(number))
}

/// `0x05` SceneLineItem: the preamble and the stroke itself.
///
/// One writer for both kinds of stroke — the anchored ones differ only in
/// which node they name as their parent.
private func lineItem(
    _ stroke: RMPageDraft.Stroke,
    parent: WriterID,
    id: WriterID,
    after previous: WriterID
) -> [UInt8] {
    var value = RMBinaryWriter()
    value.append(0x03)                                    // value type: line
    value.appendTag(index: 1, type: 0x4)
    value.append(uint32: UInt32(stroke.tool.rawValue))
    value.appendTag(index: 2, type: 0x4)
    value.append(uint32: UInt32(stroke.color.rawValue))
    value.appendTag(index: 3, type: 0x8)
    value.append(double: stroke.thickness)                // the setting, not a factor
    value.appendTag(index: 4, type: 0x4)
    value.append(float: 0)                                // starting length
    // The four numbers beside the coordinates, in version 2's order — speed,
    // **width**, direction, pressure — and not version 1's, which is speed,
    // direction, width, pressure: swapped, the strokes come out the right shape
    // and the wrong thickness.
    var written = RMBinaryWriter()
    for point in stroke.points {
        written.append(float: point.x)
        written.append(float: point.y)
        written.append(uint16: point.speed)
        written.append(uint16: point.width)
        written.append(point.direction)
        written.append(point.pressure)
    }
    value.appendBlock(index: 5, written.bytes)
    // The colour written out in full, for the strokes whose index cannot name
    // it: every shader colour, and the highlighter's blue and orange. The two
    // identifiers before it are the tail a tablet page carries — a timestamp
    // and a move — and they go in only here, because tag 8 stands behind
    // them: a field found before its predecessors is a field read as
    // something else.
    if let argb = stroke.argb {
        value.appendID(index: 6, DraftID.none)
        value.appendID(index: 7, DraftID.none)
        value.appendTag(index: 8, type: 0x4)
        value.append(uint32: argb)
    }

    var line = RMBinaryWriter()
    line.appendID(index: 1, parent)
    line.appendID(index: 2, id)
    line.appendID(index: 3, previous)
    line.appendID(index: 4, DraftID.none)
    line.appendTag(index: 5, type: 0x4)
    line.append(uint32: 0)
    line.appendBlock(index: 6, value.bytes)
    return line.bytes
}

/// The identifiers of one mark: the group, its place in the drawing order, the
/// stroke, and a stamp for each of the four anchor fields.
///
/// In one place because two places count them: the chain is built where the
/// marks are looped over and the blocks are written a function away, and a
/// stride that agreed in one and not the other would break the chain into
/// ties — which the format resolves by identifier, so the marks would come
/// back in an order nobody wrote.
private struct MarkIDs {
    let node: WriterID
    let item: WriterID
    let stroke: WriterID
    /// The stamps of the anchor and of the three fields beside it. Each is an
    /// identifier of its own, as they are on a page the tablet wrote.
    let anchor: WriterID
    let type: WriterID
    let threshold: WriterID
    let origin: WriterID

    init(_ number: Int) {
        let author = DraftID.author
        let base = DraftID.firstMark + UInt64(number) * DraftID.markStride
        node = (author, base)
        item = (author, base + 1)
        stroke = (author, base + 2)
        anchor = (author, base + 3)
        type = (author, base + 4)
        threshold = (author, base + 5)
        origin = (author, base + 6)
    }
}

/// One anchored stroke: the group that carries the anchor, its place in the
/// tree and in the drawing order, and the stroke itself.
///
/// Four blocks rather than one because that is how the tablet says it: the
/// anchor lives on a **node**, and a stroke is anchored by having that node
/// for a parent.
private func anchoredMarkBlocks(
    _ mark: RMPageDraft.Mark,
    number: Int,
    anchor: (id: WriterID, type: UInt8, threshold: Float),
    after previous: WriterID
) -> [UInt8] {
    let ids = MarkIDs(number)

    // The stroke hangs on the group, and the group on the text: that parent is
    // the whole of what "anchored" means in the file.
    let line = lineItem(mark.stroke, parent: ids.node, id: ids.stroke, after: DraftID.none)

    var out = RMBinaryWriter()
    out.append(contentsOf: anchoredGroupBlocks(
        node: ids.node,
        item: ids.item,
        stamps: AnchorStamps(
            anchor: ids.anchor,
            type: ids.type,
            threshold: ids.threshold,
            origin: ids.origin
        ),
        anchor: anchor,
        penOrigin: mark.penOrigin,
        after: previous
    ))
    // The points are the v2 layout, and the block header is what says so —
    // both halves of it: a stroke block on a tablet page declares 2 as its
    // minimum too.
    out.append(contentsOf: writerBlock(0x05, minVersion: 2, currentVersion: 2, line))
    return out.bytes
}

/// The stamps of the four anchor fields of one group — each an identifier of
/// its own, as they are on a page the tablet wrote.
private struct AnchorStamps {
    let anchor: WriterID
    let type: WriterID
    let threshold: WriterID
    let origin: WriterID
}

/// The group that carries an anchor: its tree record, its node with the four
/// anchor fields, and its place in the drawing order — everything of an
/// anchored mark or image except the item that hangs inside.
private func anchoredGroupBlocks(
    node: WriterID,
    item: WriterID,
    stamps: AnchorStamps,
    anchor: (id: WriterID, type: UInt8, threshold: Float),
    penOrigin: Float,
    after previous: WriterID
) -> [UInt8] {
    var tree = RMBinaryWriter()
    tree.appendID(index: 1, node)
    tree.appendID(index: 2, DraftID.none)
    tree.appendTag(index: 3, type: 0x1)
    tree.append(1)
    var parent = RMBinaryWriter()
    parent.appendID(index: 1, DraftID.layer)
    tree.appendBlock(index: 4, parent.bytes)

    var anchorField = RMBinaryWriter()
    // Two identifiers, and the anchor is the second: the first belongs to the
    // node, the second names the character or the line boundary.
    anchorField.appendID(index: 1, stamps.anchor)
    anchorField.appendID(index: 2, anchor.id)

    var nodeBlock = RMBinaryWriter()
    nodeBlock.appendID(index: 1, node)
    // An anchored group carries a name and it is empty — the tablet names its
    // layers and not these.
    nodeBlock.appendBlock(index: 2, nodeName(""))
    nodeBlock.appendStamped(index: 3, by: DraftID.none, u8: 1)
    nodeBlock.appendBlock(index: 7, anchorField.bytes)
    // The type and the threshold go in hard pairs: a character anchor is 1
    // and 0, a line anchor 2 and 35.75. All three fields are stamped values,
    // like the anchor above them: written bare, the page opens and the
    // tablet refuses to draw it.
    nodeBlock.appendStamped(index: 8, by: stamps.type, u8: anchor.type)
    nodeBlock.appendStamped(index: 9, by: stamps.threshold, float: anchor.threshold)
    // `anchor_origin_x`. Anchored to the first character, the pen stands on
    // the left edge of the text: the box origin plus the four units the text
    // sits in by.
    nodeBlock.appendStamped(index: 10, by: stamps.origin, float: penOrigin)

    var out = RMBinaryWriter()
    out.append(contentsOf: writerBlock(0x01, tree.bytes))
    out.append(contentsOf: writerBlock(0x02, currentVersion: 2, nodeBlock.bytes))
    out.append(contentsOf: writerBlock(
        0x04, groupItemBlock(node: node, item: item, parent: DraftID.layer, after: previous)
    ))
    return out.bytes
}

/// `0x07` RootText: the paragraphs, the styles keyed to them, and the box
/// they are set in.
///
/// Hands back two things only this walk knows: how many characters there are,
/// which `0x0A` has to declare, and the identifier of the first character of
/// each paragraph, which is what an anchored stroke names.
private func textBlock(
    paragraphs: [RMPageDraft.Paragraph],
    column: RMPageDraft.Column
) -> (bytes: [UInt8], scalars: Int, firstCharacters: [WriterID]) {
    let author = DraftID.author
    // The records, one per paragraph, chained by `left`. Face marks are
    // NOT part of this chain: they stand beside it as a second author's
    // items (`appendMark` below) — the tablet declines to draw the
    // in-chain spelling.
    var items = RMBinaryWriter()
    var styles: [(key: WriterID, paragraph: RMPageDraft.Paragraph)] = []
    var counter = DraftID.firstCharacter
    // Two different tails: `chainTail` is the last text record of the CRDT
    // chain (what the next record's `left` names; face marks stand beside
    // the chain and do not move it); `lastNewline` is the newline character
    // that keys the next paragraph's style record.
    var chainTail = DraftID.none
    var lastNewline = DraftID.none
    var records = 0
    var totalScalars = 0
    // The identifier of each paragraph's first character. The characters of a
    // record continue its own identifier, so the first
    // one is the counter the record was opened with.
    var firstCharacters: [WriterID] = []

    func appendRecord(text: String) {
        var body = RMBinaryWriter()
        body.appendID(index: 2, (author, counter))
        body.appendID(index: 3, chainTail)
        body.appendID(index: 4, DraftID.none)
        body.appendTag(index: 5, type: 0x4)
        body.append(uint32: 0)

        var value = RMBinaryWriter()
        value.append(string: text)
        body.appendBlock(index: 6, value.bytes)
        items.appendBlock(index: 0, body.bytes)
        records += 1

        let span = max(text.unicodeScalars.count, 1)
        chainTail = (author, counter + UInt64(span) - 1)
        counter += UInt64(span)
        totalScalars += text.unicodeScalars.count
    }

    // A face mark, the way the tablet spells one: a second author's item
    // standing beside the text chain — its `left` names a text scalar, its
    // `right` the neighbour it precedes, and it consumes no scalar of the
    // text counter. A mark woven into the chain itself is a shape the tablet
    // declines to draw.
    var markCounter: UInt64 = 1_000_000
    @discardableResult
    func appendMark(_ mark: UInt32, left: WriterID, right: WriterID) -> WriterID {
        let id: WriterID = (DraftID.marksAuthor, markCounter)
        markCounter += 1
        var body = RMBinaryWriter()
        body.appendID(index: 2, id)
        body.appendID(index: 3, left)
        body.appendID(index: 4, right)
        body.appendTag(index: 5, type: 0x4)
        body.append(uint32: 0)
        var value = RMBinaryWriter()
        // No text at all: what makes this a mark rather than a record is the
        // field behind the empty string.
        value.append(string: "")
        value.appendTag(index: 2, type: 0x4)
        value.append(uint32: mark)
        body.appendBlock(index: 6, value.bytes)
        items.appendBlock(index: 0, body.bytes)
        records += 1
        return id
    }

    for (index, paragraph) in paragraphs.enumerated() {
        // The style is keyed by the newline that ends the paragraph before;
        // the first paragraph is keyed by the start sentinel.
        let key = index == 0 ? DraftID.none : lastNewline
        if paragraph.style != nil { styles.append((key, paragraph)) }

        let last = index == paragraphs.count - 1
        firstCharacters.append((author, counter))
        if paragraph.text.isEmpty {
            // An empty paragraph is its newline and nothing else — one
            // record, so the scalar counters the anchors key on do not
            // move.
            appendRecord(text: last ? "" : "\n")
            lastNewline = chainTail
        } else {
            // Opening marks stand beside the chain, pointing right at the
            // text item — italic first, bold chained onto it, the tablet's
            // order.
            let textID: WriterID = (author, counter)
            var opener = chainTail
            if paragraph.italic { opener = appendMark(3, left: chainTail, right: textID) }
            if paragraph.bold { appendMark(1, left: opener, right: textID) }

            appendRecord(text: paragraph.text)
            let textTail = chainTail
            let newlineID: WriterID = last ? DraftID.none : (author, counter)
            // Closing marks hang off the last letter and point at the
            // newline — bold first, italic after, the nesting the tablet
            // closes with.
            switch (paragraph.bold, paragraph.italic) {
            case (true, true):
                let italicOff: WriterID = (DraftID.marksAuthor, markCounter + 1)
                appendMark(2, left: textTail, right: italicOff)
                appendMark(4, left: textTail, right: newlineID)
            case (true, false):
                appendMark(2, left: textTail, right: newlineID)
            case (false, true):
                appendMark(4, left: textTail, right: newlineID)
            case (false, false):
                break
            }
            if !last {
                appendRecord(text: "\n")
                lastNewline = chainTail
            }
        }
    }

    var itemRows = RMBinaryWriter()
    itemRows.append(varuint: UInt64(records))
    itemRows.append(contentsOf: items.bytes)

    var itemList = RMBinaryWriter()
    itemList.appendBlock(index: 1, itemRows.bytes)
    var itemContainer = RMBinaryWriter()
    itemContainer.appendBlock(index: 1, itemList.bytes)

    var styleRows = RMBinaryWriter()
    styleRows.append(varuint: UInt64(styles.count))
    for (key, paragraph) in styles {
        styleRows.appendBareID(key)
        styleRows.appendID(index: 1, DraftID.none)
        var value = RMBinaryWriter()
        value.appendTag(index: 1, type: 0x1)
        value.append(paragraph.style ?? 1)
        if let second = paragraph.second {
            value.appendTag(index: 2, type: 0x1)
            value.append(second)
        }
        if let third = paragraph.third {
            value.appendTag(index: 3, type: 0x4)
            value.append(uint32: third)
        }
        styleRows.appendBlock(index: 2, value.bytes)
    }
    var styleList = RMBinaryWriter()
    styleList.appendBlock(index: 1, styleRows.bytes)

    // Both lists share the one subblock — the only place in the format where
    // that happens.
    var both = RMBinaryWriter()
    both.append(contentsOf: itemContainer.bytes)
    both.appendBlock(index: 2, styleList.bytes)

    var text = RMBinaryWriter()
    text.appendID(index: 1, DraftID.text)
    text.appendBlock(index: 2, both.bytes)
    // The box: the column is centred on the sheet, so it starts half its own
    // width to the left of the middle.
    var position = RMBinaryWriter()
    position.append(double: Double(-column.width / 2))
    position.append(double: 234)
    text.appendBlock(index: 3, position.bytes)
    text.appendTag(index: 4, type: 0x4)
    text.append(float: column.width)
    // `tag 5` — the text's settings, whose `tag 1` is the same width once
    // more, stamped. It takes precedence over `tag 4` (`textWidthLegacy`),
    // and the tablet writes it on every typed page.
    var stamped = RMBinaryWriter()
    stamped.appendStamped(index: 1, by: DraftID.widthStamp, float: column.width)
    text.appendBlock(index: 5, stamped.bytes)

    return (text.bytes, totalScalars, firstCharacters)
}

/// `0x09` AuthorIds: the page's author against index 1, and the formatting
/// author against index 2 when the text carries bold or italic.
///
/// The bytes go in as the UUID reads, not byte-swapped: a page typed on the
/// tablet carries the same sixteen bytes its `.content` spells out. Swapped,
/// the page and the document it belongs to name two different authors.
private func authorsBlock(_ uuid: UUID, marks marksUUID: UUID?) -> [UInt8] {
    var authors = RMBinaryWriter()
    authors.append(varuint: marksUUID == nil ? 1 : 2)
    // The marks author's entry stands first, the way the tablet's page keeps
    // its table.
    if let marksUUID {
        var marksEntry = RMBinaryWriter()
        marksEntry.append(varuint: 16)
        marksEntry.append(contentsOf: withUnsafeBytes(of: marksUUID.uuid) { Array($0) })
        marksEntry.append(uint16: UInt16(DraftID.marksAuthor))
        authors.appendBlock(index: 0, marksEntry.bytes)
    }
    var entry = RMBinaryWriter()
    entry.append(varuint: 16)
    entry.append(contentsOf: withUnsafeBytes(of: uuid.uuid) { Array($0) })
    entry.append(uint16: UInt16(DraftID.author))
    authors.appendBlock(index: 0, entry.bytes)
    return authors.bytes
}

/// `0x00` MigrationInfo (`Conversion` in the tablet's table of block
/// names): the tablet wrote the page. Generated files are meant
/// to be read as the device's own, and this is what a page typed there says:
/// `is_device` set, `migratedLegacy` clear — a native v6 page, not one
/// converted from `.lines`. The flag only steers how two versions of a page
/// merge; it decides nothing about drawing.
private func migrationBlock() -> [UInt8] {
    var migration = RMBinaryWriter()
    migration.appendID(index: 1, DraftID.text)
    migration.appendTag(index: 2, type: 0x1)
    migration.append(1)                                   // is_device = yes
    migration.appendTag(index: 3, type: 0x1)
    migration.append(0)                                   // migratedLegacy = no
    return migration.bytes
}

/// `0x0A` PageInfo: the counters the tablet keeps per page.
private func pageInfoBlock(scalars: Int, paragraphs: Int) -> [UInt8] {
    var info = RMBinaryWriter()
    info.appendTag(index: 1, type: 0x4)
    info.append(uint32: 1)                                // loads
    info.appendTag(index: 2, type: 0x4)
    info.append(uint32: 0)                                // merges
    info.appendTag(index: 3, type: 0x4)
    info.append(uint32: UInt32(scalars))
    info.appendTag(index: 4, type: 0x4)
    info.append(uint32: UInt32(paragraphs))
    info.appendTag(index: 5, type: 0x4)
    info.append(uint32: 0)                                // keyboardCount
    return info.bytes
}

/// `0x0D` SceneInfo: the current layer, what is shown under the ink, and the
/// sheet.
private func sceneInfoBlock(
    sheet: RMPageDraft.Sheet,
    column: RMPageDraft.Column,
    hasImages: Bool
) -> [UInt8] {
    var currentLayer = RMBinaryWriter()
    currentLayer.appendID(index: 1, DraftID.none)
    currentLayer.appendID(index: 2, DraftID.layer)

    // The sheet, declared the three ways the tablet declares it: whole units
    // under `tag 5`, the same size unrounded under `tag 7`, and once more
    // stamped under `tag 8` — the one the format calls authoritative. Which
    // sheet it is decides where the text lands.
    var size = RMBinaryWriter()
    size.append(uint32: sheet.screenWidth)
    size.append(uint32: sheet.screenHeight)
    var canvas = RMBinaryWriter()
    canvas.append(double: sheet.canvasWidth)
    canvas.append(double: sheet.canvasHeight)

    var scene = RMBinaryWriter()
    scene.appendBlock(index: 1, currentLayer.bytes)
    scene.appendStamped(index: 2, by: DraftID.none, u8: 1)    // template shown
    // The imported document's visibility. A notebook has no PDF underneath
    // and the field decides nothing here; the tablet writes it on its typed
    // pages, so ours carry it too.
    scene.appendStamped(index: 3, by: DraftID.none, u8: 1)
    scene.appendBlock(index: 5, size.bytes)
    // `tag 6` is `extendedContentRect` — an LWW of four `float64`, zeros on
    // a typical page. Ours leaves it out of typed-only pages, keeping them
    // byte for byte what the tablet accepts. A page that carries an
    // image writes it, because the tablet's page with an image does, and a
    // generated page is worth what it has in common with the tablet's own
    // file.
    if hasImages {
        var viewport = RMBinaryWriter()
        viewport.appendID(index: 1, DraftID.none)
        viewport.appendBlock(index: 2, [UInt8](repeating: 0, count: 32))
        scene.appendBlock(index: 6, viewport.bytes)
    }
    scene.appendBlock(index: 7, canvas.bytes)
    scene.appendStamped(index: 8, by: DraftID.canvasStamp, block: canvas.bytes)
    // `tag 9` is the column setting itself — nought, one or two, not the
    // width. It has to name the same column the text box was
    // built to.
    scene.appendStamped(index: 9, by: DraftID.columnStamp, block: [column.setting])
    return scene.bytes
}

/// `0x01` SceneTree: the layer exists under the root.
private func sceneTreeBlock() -> [UInt8] {
    var tree = RMBinaryWriter()
    tree.appendID(index: 1, DraftID.layer)
    tree.appendID(index: 2, DraftID.none)
    tree.appendTag(index: 3, type: 0x1)
    tree.append(1)
    var parent = RMBinaryWriter()
    parent.appendID(index: 1, DraftID.root)
    tree.appendBlock(index: 4, parent.bytes)
    return tree.bytes
}

/// The name of a node, as the format spells a string: how many bytes, the
/// encoding marker, the bytes.
private func nodeName(_ label: String) -> [UInt8] {
    var value = RMBinaryWriter()
    value.append(string: label)
    var name = RMBinaryWriter()
    name.appendID(index: 1, DraftID.none)
    name.appendBlock(index: 2, value.bytes)
    return name.bytes
}

/// `0x02` SceneTreeNode: the layer's name and visibility.
private func layerNodeBlock() -> [UInt8] {
    var node = RMBinaryWriter()
    node.appendID(index: 1, DraftID.layer)
    node.appendBlock(index: 2, nodeName("Layer 1"))
    node.appendStamped(index: 3, by: DraftID.none, u8: 1)
    return node.bytes
}

/// The identifiers of one placed image: the item, and a stamp for each of
/// the two fields written with one — the key on the item, the name in the
/// attachment map.
private struct ImageIDs {
    let item: WriterID
    let keyStamp: WriterID
    let nameStamp: WriterID
    /// The group an anchored image hangs on, its place in the drawing order,
    /// and the stamps of three anchor fields — spent only when the image is
    /// anchored; a loose one takes the first three counters and no more. The
    /// fourth field, `anchor_origin_x`, is stamped with the node's own id:
    /// that is what the tablet's page carries, not a fresh counter.
    let node: WriterID
    let groupItem: WriterID
    let anchor: WriterID
    let type: WriterID
    let threshold: WriterID

    init(_ number: Int) {
        let author = DraftID.author
        let base = DraftID.firstImage + UInt64(number) * DraftID.imageStride
        item = (author, base)
        keyStamp = (author, base + 1)
        nameStamp = (author, base + 2)
        node = (author, base + 3)
        groupItem = (author, base + 4)
        anchor = (author, base + 5)
        type = (author, base + 6)
        threshold = (author, base + 7)
    }
}

/// `0x0E` AttachmentMap: every attachment of the page, keyed the way the
/// image items name them.
///
/// Version 3/3, one map per page. An entry is the 16-byte key, the stamped
/// file name — extension included — and a second stamped field whose two
/// bytes read `11 00`. That tail is mirrored verbatim: its meaning is
/// unknown, and inventing one would be writing a format the tablet does
/// not.
private func attachmentMapBlock(_ images: [RMPageDraft.Image]) -> [UInt8] {
    var entries = RMBinaryWriter()
    entries.append(varuint: UInt64(images.count))
    for (number, image) in images.enumerated() {
        var entry = RMBinaryWriter()
        entry.append(contentsOf: image.key)
        var name = RMBinaryWriter()
        name.appendID(index: 1, ImageIDs(number).nameStamp)
        var text = RMBinaryWriter()
        text.append(string: image.file)
        name.appendBlock(index: 2, text.bytes)
        entry.appendBlock(index: 1, name.bytes)
        var tailValue = RMBinaryWriter()
        tailValue.append(0x11)
        tailValue.append(0x00)
        var tail = RMBinaryWriter()
        tail.appendID(index: 1, DraftID.none)
        tail.appendBlock(index: 2, tailValue.bytes)
        entry.appendBlock(index: 2, tail.bytes)
        entries.appendBlock(index: 0, entry.bytes)
    }
    var map = RMBinaryWriter()
    map.appendBlock(index: 1, entries.bytes)
    return map.bytes
}

/// `0x0F` SceneImageItem: the placement of one attachment, hung on the
/// layer like a stroke.
///
/// Value type 7, the key stamped under `tag 1`, four vertices under `tag 3`
/// — the quad's corners with their UV, plain noughts and ones for an
/// uncropped image — and under `tag 4` the quad as two triangles, the same
/// six indices on every item. The two identifiers at `tag 2` and `tag 5` are the insert
/// flow's lineage — a moved or resized image points them at its earlier
/// incarnations — and a fresh page has none to point at.
private func imageItem(
    _ image: RMPageDraft.Image,
    ids: ImageIDs,
    parent: WriterID = DraftID.layer,
    after previous: WriterID
) -> [UInt8] {
    var value = RMBinaryWriter()
    value.append(0x07)                                    // value type: image
    var keyed = RMBinaryWriter()
    keyed.appendID(index: 1, ids.keyStamp)
    keyed.appendBlock(index: 2, image.key)
    value.appendBlock(index: 1, keyed.bytes)
    value.appendID(index: 2, DraftID.none)
    var vertices = RMBinaryWriter()
    vertices.append(varuint: 16)
    // The parser's own vertex type, so the two halves cannot disagree about
    // what a corner is.
    let corners = [
        PageImage.Vertex(x: Double(image.x), y: Double(image.y), u: 0, v: 0),
        PageImage.Vertex(x: Double(image.x + image.width), y: Double(image.y), u: 1, v: 0),
        PageImage.Vertex(
            x: Double(image.x + image.width), y: Double(image.y + image.height), u: 1, v: 1
        ),
        PageImage.Vertex(x: Double(image.x), y: Double(image.y + image.height), u: 0, v: 1),
    ]
    for corner in corners {
        vertices.append(float: Float(corner.x))
        vertices.append(float: Float(corner.y))
        vertices.append(float: Float(corner.u))
        vertices.append(float: Float(corner.v))
    }
    value.appendBlock(index: 3, vertices.bytes)
    var indices = RMBinaryWriter()
    indices.append(varuint: 6)
    for index in [0, 1, 2, 2, 3, 0] as [UInt32] {
        indices.append(uint32: index)
    }
    value.appendBlock(index: 4, indices.bytes)
    value.appendID(index: 5, DraftID.none)

    var item = RMBinaryWriter()
    item.appendID(index: 1, parent)
    item.appendID(index: 2, ids.item)
    item.appendID(index: 3, previous)
    item.appendID(index: 4, DraftID.none)
    item.appendTag(index: 5, type: 0x4)
    item.append(uint32: 0)
    item.appendBlock(index: 6, value.bytes)
    return item.bytes
}

/// `0x04` SceneGroupItem: a node's place in the drawing order. The layer sits
/// under the root; an anchored group sits under the layer.
private func groupItemBlock(
    node: WriterID = DraftID.layer,
    item: WriterID = DraftID.groupItem,
    parent: WriterID = DraftID.root,
    after previous: WriterID = DraftID.none
) -> [UInt8] {
    var value = RMBinaryWriter()
    value.append(0x02)                                    // value type: group
    value.appendID(index: 2, node)

    var group = RMBinaryWriter()
    group.appendID(index: 1, parent)
    group.appendID(index: 2, item)
    group.appendID(index: 3, previous)                    // left: the mark before
    group.appendID(index: 4, DraftID.none)
    group.appendTag(index: 5, type: 0x4)
    group.append(uint32: 0)
    group.appendBlock(index: 6, value.bytes)
    return group.bytes
}

// Equality spelled out rather than synthesised.
//
// `@frozen` lets a consumer compare two values directly, through the witness
// the compiler derives — and that witness is internal, so it is absent from
// this module's symbol table when RMLines is linked as a binary framework.
// The reference resolves in a release build, where the comparison is inlined,
// and fails to link in a debug one. Declaring `==` here puts the comparison
// behind an exported symbol, which costs nothing and keeps `@frozen`: a new
// case must still break a consumer's build rather than fall into an
// `@unknown default`.
extension WriteError {
    public static func == (a: WriteError, b: WriteError) -> Bool {
        switch (a, b) {
        case let (.anchorOutOfRange(x), .anchorOutOfRange(y)): x == y
        case let (.tooManyToNumber(whatA, limitA), .tooManyToNumber(whatB, limitB)):
            whatA == whatB && limitA == limitB
        case let (.imageKeyNotSixteenBytes(x), .imageKeyNotSixteenBytes(y)): x == y
        case let (.pageTooLarge(x), .pageTooLarge(y)): x == y
        default: false
        }
    }
}
