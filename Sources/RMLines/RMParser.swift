// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation

/// Parsing a notebook page (the `.rm` format, version 6).
///
/// Strokes, text, glyphs, the scene tree and the attachments each have a
/// parser of their own. What goes unread is counted in `RMPage.skippedBlocks`:
/// a block of a type this parser does not know, and a block of a known type
/// that would not read. The service blocks every page opens with hold nothing
/// to draw and are stepped over uncounted — counting them would put three on
/// every page ever written and leave a real loss indistinguishable from the
/// floor.
public enum RMParser {
    /// What every page begins with, whatever its generation: 32 characters,
    /// the version number right behind them.
    public static let headerPrefix = "reMarkable .lines file, version="
    /// The file header, exactly 43 bytes including the padding spaces.
    public static let header = headerPrefix + "\(supportedVersion)          "
    /// The one version this parser reads. Versions 3 and 5 carry the same
    /// 43-byte header with another digit in it and nothing else in common: a
    /// flat container of counters rather than the tagged CRDT blocks below.
    public static let supportedVersion = 6

    /// The type of a stroke block and the value type inside it.
    static let sceneLineItemBlock: UInt8 = 0x05
    private static let lineItemType: UInt8 = 0x03
    /// A scene tree node and the root text block.
    private static let treeNodeBlock: UInt8 = 0x02
    private static let rootTextBlock: UInt8 = 0x07
    /// The tree itself, the order of a node's children, and the tombstones
    /// an undo leaves. The three carry the layers: `0x01` says which nodes
    /// exist, `0x04` links a child group into its parent's list, and `0x08`
    /// is a position-holding tombstone like an erased stroke's.
    private static let sceneTreeBlock: UInt8 = 0x01
    private static let sceneGroupItemBlock: UInt8 = 0x04
    private static let undoTombstoneBlock: UInt8 = 0x08
    private static let groupItemType: UInt8 = 0x02
    /// The attachments: `0x0E` maps a 16-byte key to a file name in the
    /// document's index, `0x0F` places the image on the page by four
    /// vertices.
    private static let attachmentMapBlock: UInt8 = 0x0E
    private static let imageItemBlock: UInt8 = 0x0F
    private static let imageItemType: UInt8 = 0x07
    /// The scene info block and the index of the sheet size field inside it.
    private static let sceneInfoBlock: UInt8 = 0x0D

    /// The service blocks every page opens with, in the order the tablet
    /// writes them: the author table, the migration record, the page counters
    /// — and then `0x0D`, which is read (`09 00 0a 0d …`). The first three
    /// hold nothing that is drawn: the author table names who made an edit,
    /// the migration record who created the page, the counters how many times
    /// it was opened. Stepping over them by length loses no content, so they
    /// must not be counted as loss — counted, they would put three on every
    /// page and a hundred-page notebook would report three hundred losses.
    private static let authorIdsBlock: UInt8 = 0x09
    private static let migrationInfoBlock: UInt8 = 0x00
    private static let pageInfoBlock: UInt8 = 0x0A

    static let sceneGlyphItemBlock: UInt8 = 0x03
    /// The scene info fields: whether the template and the imported document
    /// are shown, and the sheet size.
    private static let backgroundVisibleTag = 2
    private static let rootDocumentVisibleTag = 3
    private static let paperSizeTag = 5
    /// The same sheet as `tag 5`, unrounded — two `float64`.
    private static let canvasSizeTag = 7
    /// Field indexes: the visibility of a node, its anchor, the items and the
    /// position in the text.
    private static let visibilityTag = 3
    private static let anchorTag = 7
    /// `anchor_origin_x` — the horizontal the anchored handwriting counts its
    /// x from, written outright.
    private static let anchorOriginTag = 10
    private static let textItemsTag = 2
    private static let textPositionTag = 3
    /// The width of the text column, declared outright. `byte4` by its tag
    /// and a **float32** by its contents: `0x44900000` is 1152.0, and read as
    /// a `uint32` the same bytes are a billion and change.
    private static let columnWidthTag = 4
    /// The text's settings, whose `tag 1` is the same width once more,
    /// stamped — the one that takes precedence.
    private static let textSettingsTag = 5
    /// The field a text record carries when it is not text at all but a
    /// marker: the start or the end of a bold or an italic stretch or of a
    /// link, or an image in the flow.
    private static let markerTag = 2

    /// The version a header declares, or `nil` when the bytes are not one.
    ///
    /// Read out of the header rather than compared against a list of known
    /// spellings: the point is to recognise a generation nobody has written
    /// down yet — a future 7 as much as the 3 and the 5 behind us — and say
    /// its number instead of calling the file unrecognisable.
    public static func version(inHeader header: String) -> Int? {
        guard header.hasPrefix(headerPrefix) else { return nil }
        let digits = header.dropFirst(headerPrefix.count).prefix(while: \.isNumber)
        // A single leading digit is what the format writes; the padding
        // spaces behind it stop the scan. An empty run means the header only
        // looks like one.
        return digits.isEmpty ? nil : Int(digits)
    }

    public static func parsePage(_ data: Data) throws -> RMPage {
        let blocks = try readBlocks(data)
        Self.report(blocks)
        return Self.assemble(blocks)
    }

    /// One pass over a page's blocks, everything gathered and nothing yet
    /// decided about what is drawn: hidden layers are in here with the rest.
    static func readBlocks(_ data: Data) throws -> ParsedBlocks {
        var reader = RMBinaryReader(data)

        let headerBytes = try reader.readBytes(header.utf8.count)
        let headerText = String(decoding: headerBytes, as: UTF8.self)
        guard headerText == header else {
            // A page of an older generation is not a broken file, and the two
            // must not arrive as one error: the reader above leaves the page
            // out and tells the user which format it is in, and it can only
            // say that about a version it has actually read.
            if let version = Self.version(inHeader: headerText) {
                throw ParseError.unsupportedVersion(version)
            }
            throw ParseError.unsupportedFormat(String(headerText.prefix(32)))
        }

        var items: [SceneItem] = []
        var treeEvents: [TreeEvent] = []
        var attachments: [[UInt8]: String] = [:]
        var anchorOfNode: [CrdtID: NodeAnchor] = [:]
        // The nodes the user hid. Their strokes stay in the file with every
        // one of their points; it is the layer that is hidden, not its
        // contents, and a hidden layer is not drawn. Drawing them shows the
        // user what they put away — the worst kind of discrepancy, because
        // nothing says it happened.
        //
        // The nodes hidden themselves. The scene walk hides everything nested
        // under one, the way it leaves out whatever hangs under a node the
        // `0x01` blocks took out of the tree.
        var hiddenNodes: Set<CrdtID> = []
        // The stamp of the visibility edit each node's state comes from. A
        // layer hidden and shown again carries two records, and file order is
        // not edit order: the newer stamp wins, an older record arriving later
        // does not undo it, and a layer shown again is shown.
        var visibilityStamps: [CrdtID: CrdtID] = [:]
        var textLayout: TextLayout?
        // Two reasons for skipping, not one. Mixed into a single counter they
        // hide the loss: nine hundred unknown blocks look ordinary, while two
        // thousand unread strokes in the same total do not.
        var otherBlocks = 0
        var unreadableStrokes = 0
        var deletedItems = 0
        var highlights: [Highlight] = []
        var firstFailure: String?
        var paperSize: CGSize?
        // Shown unless the file says otherwise: most pages carry no flag at
        // all, and a missing field means "never touched", not "hidden".
        var backgroundVisible = true
        var rootDocumentVisible = true

        while reader.remaining >= 8 {
            let blockLength = Int(try reader.readUInt32())
            _ = try reader.readUInt8()               // unknown field
            _ = try reader.readUInt8()               // min_version
            let currentVersion = try reader.readUInt8()
            let blockType = try reader.readUInt8()

            let blockEnd = reader.offset + blockLength
            guard blockEnd <= reader.count else { throw ParseError.unexpectedEndOfData }

            switch blockType {
            case sceneLineItemBlock:
                // A stroke we did not understand is a lost piece of the
                // drawing, but no reason to lose the whole page.
                do {
                    let item = try parseLineItem(
                        &reader, pointVersion: currentVersion, end: blockEnd
                    )
                    if item.content == nil { deletedItems += 1 }
                    items.append(item)
                } catch {
                    unreadableStrokes += 1
                    if firstFailure == nil { firstFailure = String(describing: error) }
                }

            // Every block below counts itself only when its own parse failed,
            // which is what keeps `skippedBlocks` meaning what the field says:
            // the pieces of this page that will not be drawn. A block of a
            // type we understand and read is not a loss and is not counted —
            // counted regardless, the number would say "blocks other than
            // strokes" and could not tell a loss from an ordinary page.
            case sceneTreeBlock:
                // Which nodes are in the tree. The one authority on the list
                // of layers: a deleted layer keeps its `0x02` and its `0x04`,
                // and only this block says it is gone.
                if let event = try? parseSceneTree(&reader) { treeEvents.append(event) } else { otherBlocks += 1 }

            case sceneGroupItemBlock:
                // The link of a child group into its parent's list of items —
                // what the order of layers is made of. Unread, the layer it
                // named comes unhooked from the tree and its strokes fall
                // back to file order — kept, but not where they were.
                do {
                    items.append(try parseGroupItem(&reader, end: blockEnd))
                } catch {
                    otherBlocks += 1
                    if firstFailure == nil { firstFailure = String(describing: error) }
                }

            case undoTombstoneBlock:
                // The tombstone an undo leaves: the same preamble as an
                // erased stroke's, no value. It holds a position in the
                // chain, and dropping it would unhook whatever hangs on it.
                if let item = try? parseSceneTombstone(&reader) { items.append(item) } else { otherBlocks += 1 }

            case attachmentMapBlock:
                // The names of the page's attachments, keyed the way the
                // image items name them. Unread, a page of captures comes out
                // blank — the tablet rasterises a capture whole, and nothing
                // of it lives anywhere else.
                if let map = try? parseAttachmentMap(&reader, end: blockEnd) {
                    attachments.merge(map) { _, new in new }
                } else {
                    otherBlocks += 1
                }

            case imageItemBlock:
                // A picture that will not parse is a lost picture, and a
                // picture is the whole of a captured page: counted, and
                // its failure kept for the log, the same as a stroke's.
                do {
                    items.append(try parseImageItem(&reader, end: blockEnd))
                } catch {
                    otherBlocks += 1
                    if firstFailure == nil { firstFailure = String(describing: error) }
                }

            case treeNodeBlock:
                if let node = try? parseTreeNode(&reader, end: blockEnd) {
                    if let anchor = node.anchor {
                        anchorOfNode[node.id] = NodeAnchor(anchor: anchor, originX: node.originX)
                    }
                    if let visible = node.visible {
                        let stamp = node.visibilityStamp
                        // Counters are page-wide; the author breaks a tie.
                        let isNewer = visibilityStamps[node.id].map {
                            (stamp.counter, stamp.author) >= ($0.counter, $0.author)
                        } ?? true
                        if isNewer {
                            visibilityStamps[node.id] = stamp
                            if visible { hiddenNodes.remove(node.id) } else { hiddenNodes.insert(node.id) }
                        }
                    }
                } else {
                    otherBlocks += 1
                }

            case rootTextBlock:
                if let layout = try? parseRootText(&reader, end: blockEnd) {
                    textLayout = layout
                } else {
                    // A text block that will not parse is counted, and the
                    // text of an earlier block that did parse stays. A broken
                    // item or style list inside a block that parses is not
                    // counted.
                    otherBlocks += 1
                }

            case sceneGlyphItemBlock:
                // The marker over the text of an imported PDF. Not a stroke:
                // it carries the highlighted text and ready-made rectangles,
                // so skipping it drops the highlight silently. A highlight
                // the user took off is a tombstone, as ordinary as an erased
                // stroke, and is not counted as a loss — only a highlight
                // that is there and would not read is.
                do {
                    if let highlight = try parseGlyphItem(&reader, end: blockEnd) {
                        highlights.append(highlight)
                    } else {
                        deletedItems += 1
                    }
                } catch {
                    otherBlocks += 1
                    if firstFailure == nil { firstFailure = String(describing: error) }
                }

            case sceneInfoBlock:
                // Never counted: `parseSceneInfo` does not fail. It reads the
                // fields it knows and leaves the rest at their defaults, so no
                // outcome here loses content.
                let info = parseSceneInfo(&reader, end: blockEnd)
                paperSize = info.paperSize ?? paperSize
                if let flag = info.backgroundVisible { backgroundVisible = flag }
                if let flag = info.rootDocumentVisible { rootDocumentVisible = flag }

            case authorIdsBlock, migrationInfoBlock, pageInfoBlock:
                // The other three of the service quartet. Stepped over by
                // length on purpose and never counted: nothing in them is
                // drawn, so passing them over is not a loss.
                break

            default:
                // A block of a type this parser does not know — the one case
                // where stepping over it by length is all there is to do.
                otherBlocks += 1
            }

            try reader.seek(to: blockEnd)
        }

        return ParsedBlocks(
            items: items,
            treeEvents: treeEvents,
            attachments: attachments,
            anchorOfNode: anchorOfNode,
            hiddenNodes: hiddenNodes,
            textLayout: textLayout,
            otherBlocks: otherBlocks,
            unreadableStrokes: unreadableStrokes,
            deletedItems: deletedItems,
            highlights: highlights,
            firstFailure: firstFailure,
            paperSize: paperSize,
            backgroundVisible: backgroundVisible,
            rootDocumentVisible: rootDocumentVisible
        )
    }

    /// What one pass over a page's blocks gathered, before any of it is a
    /// page.
    ///
    /// A type rather than a dozen values carried to the end of one function:
    /// the loop that fills it and the assembly that reads it change for
    /// different reasons — one more block type is the format's business,
    /// while what a page is made of is the domain's.
    struct ParsedBlocks {
        let items: [SceneItem]
        let treeEvents: [TreeEvent]
        let attachments: [[UInt8]: String]
        let anchorOfNode: [CrdtID: NodeAnchor]
        let hiddenNodes: Set<CrdtID>
        let textLayout: TextLayout?
        let otherBlocks: Int
        let unreadableStrokes: Int
        let deletedItems: Int
        let highlights: [Highlight]
        let firstFailure: String?
        let paperSize: CGSize?
        let backgroundVisible: Bool
        let rootDocumentVisible: Bool
    }

    /// What the pass could not read, said out loud.
    private static func report(_ blocks: ParsedBlocks) {
        // Only the unread must not be passed over in silence: that is a
        // missing piece of what was written. Deleted items do not go into the
        // log — there are many of them and they are normal. The other
        // blocks are counted in `skippedBlocks` on the same terms as a
        // stroke, so they are said on the same terms too: a lost image or an
        // unhooked layer that reached the count and not the log would be
        // found months later, in somebody's page.
        if blocks.unreadableStrokes + blocks.otherBlocks > 0 {
            RMLinesLog.error(
                """
                page: \(blocks.items.count) scene items, \
                \(blocks.unreadableStrokes) unreadable, \
                \(blocks.deletedItems) deleted, \
                \(blocks.otherBlocks) other blocks; \
                first failure: \(blocks.firstFailure ?? "-")
                """
            )
        }
    }

    /// The gathered blocks as one page.
    private static func assemble(_ blocks: ParsedBlocks) -> RMPage {
        // The drawing order is the scene's, not the file's: layers in the
        // chain order of `0x04`, strokes in their own chain within a layer.
        // A hidden or deleted layer is dropped here rather than at drawing
        // time, so that it widens no sheet and shifts no anchor either.
        let scene = orderedScene(items: blocks.items, events: blocks.treeEvents, hidden: blocks.hiddenNodes)
        let visible = scene.strokes
        let drawableCount = blocks.items.count { item in
            if case .stroke = item.content { return true } else { return false }
        }
        if visible.count != drawableCount {
            RMLinesLog.debug(
                """
                page: \(drawableCount - visible.count) strokes on \
                hidden or deleted layers are not drawn
                """
            )
        }
        let images = Self.images(
            of: scene.images,
            named: blocks.attachments,
            anchoredBy: blocks.anchorOfNode,
            in: blocks.textLayout
        )

        // Deleted items do not count as skipped: the user erased them, and a
        // "loss" here would be a false alarm.
        let handwriting = anchoring(visible, anchors: blocks.anchorOfNode, text: blocks.textLayout)
        return RMPage(
            strokes: handwriting.strokes,
            skippedBlocks: blocks.unreadableStrokes + blocks.otherBlocks,
            paperSize: blocks.paperSize,
            backgroundVisible: blocks.backgroundVisible,
            rootDocumentVisible: blocks.rootDocumentVisible,
            text: blocks.textLayout.map { layout in
                TextBlock(
                    originX: layout.origin.x,
                    originY: layout.origin.y,
                    lines: layout.lines,
                    formats: layout.formatOfLine,
                    faces: layout.faces,
                    columnWidth: layout.columnWidth
                )
            },
            anchoredStrokes: handwriting.anchored,
            highlights: blocks.highlights,
            images: images
        )
    }

    /// The scene info block: the sheet size, and whether the template and the
    /// imported document are shown.
    ///
    /// The size's only reliable source is here: `.content` declares
    /// `customZoomPageWidth`/`Height`, but with `zoomMode: bestFit` that is
    /// the state of a manual zoom left over from an earlier device rather
    /// than the page size. A notebook written on a Paper Pro holds the legacy
    /// values 1404 × 1872 there, while the real sheet is 1620 × 2160.
    ///
    /// The two flags are what the user's own "hide" switches write: a hidden
    /// template or imported PDF must not be drawn.
    ///
    /// Inside the block every field comes as `length4`: a tag, a four-byte
    /// length, a value. Tag 5 is two `uint32`s; tags 2 and 3 are last-write-
    /// wins records — a timestamp, then the flag. On meeting a field of
    /// another kind we stop parsing: the format is unofficial, and guessing
    /// the length of an unfamiliar value is worse than answering "unknown".
    private static func parseSceneInfo(
        _ reader: inout RMBinaryReader,
        end: Int
    ) -> (paperSize: CGSize?, backgroundVisible: Bool?, rootDocumentVisible: Bool?) {
        var paperSize: CGSize?
        var canvasSize: CGSize?
        var backgroundVisible: Bool?
        var rootDocumentVisible: Bool?
        while reader.offset < end, let tag = try? reader.readTag() {
            guard tag.type == RMBinaryReader.TagType.length4.rawValue,
                  let length = try? reader.readUInt32()
            else { break }

            let valueEnd = reader.offset + Int(length)
            switch tag.index {
            case paperSizeTag where length >= 8:
                if let width = try? reader.readUInt32(),
                   let height = try? reader.readUInt32(),
                   width > 0, height > 0 {
                    paperSize = CGSize(width: Int(width), height: Int(height))
                }
            // The same sheet unrounded. `tag 7` (`canvasSizeTag`) is read and
            // `tag 8` never is: `tag 7` is the sheet the tablet renders. A
            // Move's canvas is 820.295 × 1458.303 where `tag 5` says
            // 820 × 1458, and the page is 260 × 463 points — the canvas times
            // the unit, rounded to whole points, and not the panel's 462.4.
            // Read after the whole one (`tag 5`) so it wins when both are
            // there, and a page carrying only `tag 5` still has a sheet.
            case canvasSizeTag where length >= 16:
                // `isFinite` and not only `> 0`: a NaN fails the comparison on
                // its own, but `+Inf` passes it and becomes a sheet of
                // infinite size — every page of the book rendered into a
                // MediaBox no reader will open.
                if let width = try? reader.readFloat64(),
                   let height = try? reader.readFloat64(),
                   width.isFinite, height.isFinite,
                   width > 0, height > 0 {
                    canvasSize = CGSize(width: width, height: height)
                }
            case backgroundVisibleTag, rootDocumentVisibleTag:
                // The timestamp of the last write, then the flag — the same
                // shape as a layer's visibility in the tree node.
                _ = try? reader.readCrdtID(index: 1)
                if reader.matchTag(index: 2, type: .byte1),
                   let flag = try? reader.readUInt8() {
                    if tag.index == backgroundVisibleTag {
                        backgroundVisible = flag != 0
                    } else {
                        rootDocumentVisible = flag != 0
                    }
                }
            default:
                break
            }

            do { try reader.seek(to: valueEnd) } catch { break }
        }
        return (canvasSize ?? paperSize, backgroundVisible, rootDocumentVisible)
    }

    /// The scene's images, their keys resolved to file names.
    ///
    /// A key the attachment map does not know is content we cannot fetch —
    /// said out loud rather than dropped in silence, because a page that
    /// quietly loses a picture looks like a page that never had one.
    private static func images(
        of placed: [PlacedImageItem],
        named attachments: [[UInt8]: String],
        anchoredBy anchors: [CrdtID: NodeAnchor],
        in text: TextLayout?
    ) -> [PageImage] {
        placed.compactMap { image in
            guard let file = attachments[image.key] else {
                RMLinesLog.error("page: an image without a name in the attachment map is lost")
                return nil
            }
            // An image anchored to the text hangs on an anchored group the
            // way handwriting does, and takes the same anchor: its vertices
            // are counted from the pen, and where the pen stands is the
            // layout's to say. (The format has a second way, an image
            // standing in the text itself — a record of `RootText` keyed into
            // block `0x0E` with no `0x0F` item at all; that one is not drawn
            // here.)
            return PageImage(
                file: file,
                vertices: image.vertices,
                strokesBefore: image.strokesBefore,
                anchor: textAnchor(underneath: image.parent, in: anchors, text: text)
            )
        }
    }

    /// The anchor an item takes from the node it hangs on, when that node
    /// carries one the laid-out text can locate — the one translation both
    /// anchored handwriting and anchored images go through. The place says
    /// which character; the horizontal comes with the node, straight from the
    /// file, and travels alongside.
    private static func textAnchor(
        underneath parent: CrdtID,
        in anchors: [CrdtID: NodeAnchor],
        text: TextLayout?
    ) -> TextAnchor? {
        guard let node = anchors[parent], let place = text?.anchor(of: node.anchor) else {
            return nil
        }
        return TextAnchor(
            paragraph: place.paragraph,
            offset: place.offset,
            originX: node.originX
        )
    }

    /// Mark the handwriting that is counted from the text with the paragraph
    /// it belongs to.
    ///
    /// The coordinates of such strokes are counted from a paragraph of the text
    /// rather than from the sheet — a line here is a paragraph, because the
    /// anchor names a character and the character knows how many newlines came
    /// before it. Where that paragraph lands is not decided here: a paragraph
    /// too long for one line takes more than one step, and working out how much
    /// more takes a font and a column width. Both belong to drawing, so the
    /// number travels to the renderer.
    ///
    /// Unanchored strokes are left alone — their coordinates are the sheet's
    /// already.
    private static func anchoring(
        _ items: [(stroke: Stroke, parent: CrdtID)],
        anchors: [CrdtID: NodeAnchor],
        text: TextLayout?
    ) -> (strokes: [Stroke], anchored: Int) {
        guard text != nil, !anchors.isEmpty else { return (items.map(\.stroke), 0) }

        var anchored = 0
        let marked = items.map { item -> Stroke in
            guard let place = textAnchor(underneath: item.parent, in: anchors, text: text) else {
                return item.stroke
            }
            anchored += 1
            return item.stroke.anchored(to: place)
        }
        return (marked, anchored)
    }

    /// The marker over the text of an imported PDF.
    ///
    /// The same item preamble as a stroke — parent, identifier, neighbours,
    /// the length of what was deleted — and then a value of its own: the
    /// place in the text layer, the highlighted text, the colour, and the
    /// rectangles: tag 2 `start`, 3 `length`, 4 the colour, 5 the text, 6 the
    /// rectangles, 10 an explicit colour.
    ///
    /// The rectangles and the colour are what drawing needs; the text is
    /// read as well, because it is the only record of *what* was highlighted
    /// short of reading the PDF back — and the page under the band may be a
    /// scan with no text layer to read.
    ///
    /// `end` is the end of the block. It is not decoration: the rectangles
    /// come with a count of their own, and a count is a declaration rather
    /// than a promise — reserving on it hands a sixty-byte blob the keys to
    /// gigabytes.
    private static func parseGlyphItem(
        _ reader: inout RMBinaryReader,
        end: Int
    ) throws -> Highlight? {
        let preamble = try parsePreamble(&reader)

        // No value means the highlight was removed — as ordinary here as an
        // erased stroke, and answered `nil` rather than thrown for that
        // reason. Only a real tombstone is that: a deleted length, and the
        // block ending right behind it. Every other way of coming back
        // without a highlight throws — a highlight that is there and will
        // not read is a loss, and must be counted as one.
        guard reader.matchValue(before: end) else {
            guard preamble.deleted > 0, reader.offset == end else {
                throw ParseError.malformedPage("a highlight has neither a value nor a deletion")
            }
            return nil
        }
        // A deleted length removes the highlight whatever follows it, as it
        // removes a stroke from the scene: the editor and the scene walk read
        // it so, and a highlight the page shows has to be one the editor can
        // erase.
        guard preamble.deleted == 0 else { return nil }
        // The value declares its length, and it is held to the block: what
        // follows is read inside the value and nowhere else. Its type is
        // not checked — the tablet writes `0x01`, but a highlight refused
        // on a type byte spelled otherwise would vanish from the page for
        // nothing the drawing needs.
        let valueLength = Int(try reader.readUInt32())
        let valueEnd = reader.offset + valueLength
        guard valueEnd <= end else {
            throw ParseError.malformedPage("a highlight's value runs past its block")
        }
        _ = try reader.readUInt8()           // value type

        // `start` and `length` may be absent, and their absence
        // is not an error: they place the highlight in the text layer, which
        // we do not need — the rectangles say where to draw.
        if reader.matchTag(index: 2, type: .byte4) { _ = try reader.readUInt32() }
        if reader.matchTag(index: 3, type: .byte4) { _ = try reader.readUInt32() }

        try reader.expectTag(index: 4, type: .byte4)
        let colorID = Int(try reader.readUInt32())

        // The reader is put at the field's end whatever its length claimed,
        // so a short or padded field cannot shift the rectangles after it.
        var text: String?
        if reader.matchTag(index: 5, type: .length4) {
            let textLength = Int(try reader.readUInt32())
            let textEnd = min(reader.offset + textLength, valueEnd)
            let decoded = try reader.readString(upTo: textEnd)
            if !decoded.isEmpty { text = decoded }
            try reader.seek(to: textEnd)
        }

        guard reader.matchTag(index: 6, type: .length4) else {
            throw ParseError.malformedPage("a highlight has no rectangles")
        }
        let rectanglesLength = Int(try reader.readUInt32())
        let rectanglesEnd = reader.offset + rectanglesLength
        guard rectanglesEnd <= valueEnd else {
            throw ParseError.malformedPage("a highlight's rectangles run past its value")
        }
        let count = try reader.readCount()
        // Four `float64` to a rectangle: more than fit in the field cannot be
        // there, whatever the count says — refused before a single one is
        // read, so the reads below never leave the field.
        guard count <= max(0, rectanglesEnd - reader.offset) / 32 else {
            throw ParseError.malformedPage("a highlight declares \(count) rectangles, more than its field holds")
        }
        var rectangles: [CGRect] = []
        rectangles.reserveCapacity(count)
        for _ in 0..<count {
            let x = try reader.readFloat64()
            let y = try reader.readFloat64()
            let width = try reader.readFloat64()
            let height = try reader.readFloat64()
            // The whole highlight goes, not the one rectangle: the marker is
            // drawn as a run over a line of text, and a run with a hole in it
            // is a highlight of something the user did not highlight. Thrown
            // rather than returned empty so that the caller counts it.
            guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
                throw ParseError.malformedPage("a highlight rectangle is not a finite one")
            }
            rectangles.append(CGRect(x: x, y: y, width: width, height: height))
        }
        guard !rectangles.isEmpty else {
            throw ParseError.malformedPage("a highlight has no rectangles")
        }
        // Whatever the field holds past the rectangles it counted is the
        // field's own: the tail is read from where the field ends.
        try reader.seek(to: rectanglesEnd)

        // The second form of a highlight: instead of `start` and `length`,
        // the first and the last character as identifiers, and whether the
        // last one is included (`first`/`last`/`includeLastId`).
        // They stand between the rectangles and the colour, and an unread one
        // hides the colour from the match below. Each is stepped over whole,
        // and only while it lies wholly inside the value.
        skipOptionalTail(&reader, index: 7, type: .id, before: valueEnd)
        skipOptionalTail(&reader, index: 8, type: .id, before: valueEnd)
        skipOptionalTail(&reader, index: 9, type: .byte1, before: valueEnd)

        var argb: UInt32?
        // Inside the value only, for the reason the stroke's colour is: the
        // next block's length of 420 spells this tag's `A4 01`.
        if reader.offset < valueEnd, reader.matchTag(index: 10, type: .byte4), reader.offset + 4 <= valueEnd {
            argb = try? reader.readUInt32()
        }

        return Highlight(
            rectangles: rectangles,
            color: PenColor(rawValue: colorID) ?? .yellow,
            argb: argb,
            text: text,
            id: SceneItemID(preamble.id)
        )
    }

    /// Step over an optional field of a value's tail when it is there and ends
    /// inside the value; otherwise leave the reader where it stood.
    ///
    /// The bound is the field's end, not its tag's: an identifier is a byte
    /// and a varuint, and a tail cut short in the middle of one would carry
    /// the reader into the next block.
    private static func skipOptionalTail(
        _ reader: inout RMBinaryReader,
        index: Int,
        type: RMBinaryReader.TagType,
        before end: Int
    ) {
        let saved = reader.offset
        guard reader.offset < end, reader.matchTag(index: index, type: type) else { return }
        let skipped: Bool
        switch type {
        case .id: skipped = (try? reader.readBareCrdtID()) != nil
        case .byte1: skipped = (try? reader.readUInt8()) != nil
        default: skipped = false
        }
        if !skipped || reader.offset > end { try? reader.seek(to: saved) }
    }

    /// One item of a node's list of children — the unit the scene is ordered
    /// by. A stroke, a reference to a child group, or a tombstone: the
    /// tombstones must not be dropped while ordering, because a later record
    /// may hang its `left` link on one.
    struct SceneItem {
        let parent: CrdtID
        let id: CrdtID
        let left: CrdtID
        /// How many records this one deletes — a counter, not a flag. A
        /// living record carries nought and a value; a tombstone carries the
        /// count and no value.
        let deleted: UInt32
        let content: Content?

        enum Content {
            case stroke(Stroke)
            case group(CrdtID)
            /// An image: the opaque key of its attachment (resolved to a
            /// file name through the `0x0E` map) and the four vertices.
            case image(key: [UInt8], vertices: [PageImage.Vertex])
        }
    }

    /// What a node hangs on in the typed text: the character the file names,
    /// and the horizontal it carries alongside.
    ///
    /// A name rather than a bare pair: the two travel together through five
    /// signatures, and a tuple would leave the reader to hold in their head
    /// which half is which, and adding a third field would mean editing five
    /// places.
    struct NodeAnchor {
        let anchor: CrdtID
        let originX: Double?
    }

    /// One record of the scene tree (`0x01`): a node entering or leaving.
    /// Applied in file order, these are the one authority on which layers
    /// exist — `0x02` and `0x04` both survive a layer's deletion.
    struct TreeEvent {
        let node: CrdtID
        let inTree: Bool
    }

    /// A record of the scene tree. An adding record names its node in tag 1
    /// with tag 2 at nought; a removing one is a fresh record whose tag 2
    /// names the node taken out (`inTree=0` is a real removal — the device's
    /// five-layer limit counts by these).
    private static func parseSceneTree(_ reader: inout RMBinaryReader) throws -> TreeEvent {
        let record = try reader.readCrdtID(index: 1)
        let target = try reader.readCrdtID(index: 2)
        try reader.expectTag(index: 3, type: .byte1)
        let inTree = try reader.readUInt8() != 0
        return TreeEvent(node: inTree ? record : target, inTree: inTree)
    }

    /// A group's place in its parent's list (`0x04`): the same preamble as a
    /// stroke, and a value naming the child node. A tombstone names nothing —
    /// the reference is thrown out with the deletion.
    ///
    /// A value that is there but not of that shape is thrown rather than
    /// answered with `nil`: `nil` is what `orderedScene` reads as "the user
    /// deleted this", and a link the file still carries was not deleted, it
    /// was lost — along with the place of everything the group held.
    private static func parseGroupItem(_ reader: inout RMBinaryReader, end: Int) throws -> SceneItem {
        let preamble = try parsePreamble(&reader)
        var content: SceneItem.Content?
        if reader.matchValue(before: end) {
            _ = try reader.readUInt32()              // value length
            let valueType = try reader.readUInt8()
            guard valueType == groupItemType else {
                throw ParseError.malformedPage("a group item's value is of type \(valueType), not a group")
            }
            guard let node = try? reader.readCrdtID(index: 2) else {
                throw ParseError.malformedPage("a group item names no node")
            }
            content = .group(node)
        }
        return SceneItem(
            parent: preamble.parent,
            id: preamble.id,
            left: preamble.left,
            deleted: preamble.deleted,
            content: content
        )
    }

    /// The tombstone an undo leaves (`0x08`): the preamble alone, no value.
    /// Read for its position in the chain, nothing else.
    private static func parseSceneTombstone(_ reader: inout RMBinaryReader) throws -> SceneItem {
        let preamble = try parsePreamble(&reader)
        return SceneItem(
            parent: preamble.parent,
            id: preamble.id,
            left: preamble.left,
            deleted: preamble.deleted,
            content: nil
        )
    }

    /// The envelope every scene item starts with: the parent node, the item's
    /// own identifier, its neighbours in the parent's list, and the count of
    /// what was deleted here.
    struct Preamble {
        let parent: CrdtID
        let id: CrdtID
        let left: CrdtID
        let deleted: UInt32
    }

    static func parsePreamble(_ reader: inout RMBinaryReader) throws -> Preamble {
        let parent = try reader.readCrdtID(index: 1)
        let id = try reader.readCrdtID(index: 2)
        let left = try reader.readCrdtID(index: 3)
        try reader.skipCrdtID(index: 4)              // right
        try reader.expectTag(index: 5, type: .byte4)
        let deleted = try reader.readUInt32()
        return Preamble(parent: parent, id: id, left: left, deleted: deleted)
    }

    /// The strokes in the order the tablet draws them: the scene tree walked
    /// depth-first, each node's children in their chain order. File order is
    /// not that order — a reordering of layers rewrites no stroke at all.
    ///
    /// A node is left out when the user hid it (`0x02`) or took it out of the
    /// tree (`0x01`); everything under it goes too. Strokes whose parent the
    /// walk never reaches — a file without group blocks, or links that do not
    /// add up — are appended in file order rather than lost: order is worth
    /// less than the ink.
    private static func orderedScene(
        items: [SceneItem],
        events: [TreeEvent],
        hidden: Set<CrdtID>
    ) -> (
        strokes: [(stroke: Stroke, parent: CrdtID)],
        images: [PlacedImageItem]
    ) {
        // The nodes taken out of the tree, by applying the records in order.
        // Only an explicit removal counts: a node nobody added is not dropped,
        // or a file without tree records would draw nothing.
        var removed: Set<CrdtID> = []
        for event in events {
            if event.inTree { removed.remove(event.node) } else { removed.insert(event.node) }
        }

        let childrenOfNode = Dictionary(grouping: items.indices) { items[$0].parent }
        // The roots: nodes that hold items but are named by no group item —
        // the page root, ordinarily one.
        let interior = Set(items.compactMap { item -> CrdtID? in
            if case .group(let node) = item.content { return node }
            return nil
        })

        var result: [(stroke: Stroke, parent: CrdtID)] = []
        var images: [PlacedImageItem] = []
        var placed = Set<Int>()
        // A subtree that is not drawn, and whose items are nonetheless spoken
        // for: the fallback below must not resurrect a hidden layer.
        func claimSubtree(of node: CrdtID) {
            var stack = childrenOfNode[node] ?? []
            while let index = stack.popLast() {
                guard placed.insert(index).inserted else { continue }
                if case .group(let child) = items[index].content {
                    stack.append(contentsOf: childrenOfNode[child] ?? [])
                }
            }
        }

        // Depth first with a stack of its own rather than with the call stack:
        // groups nest as deeply as a page has of them, and the depth is the
        // file's to choose. `chainOrder` is iterative for the same reason: a
        // recursive walk could be driven into a stack overflow — which no
        // `try?` catches, because it is not an error but the end of the
        // process. Each frame is a node, its children in chain order, and how
        // far down them the walk has got.
        func walk(from root: CrdtID) {
            guard !removed.contains(root), !hidden.contains(root) else {
                claimSubtree(of: root)
                return
            }
            var stack: [(node: CrdtID, children: [Int], next: Int)] = [
                (root, chainOrder(childrenOfNode[root] ?? [], items: items), 0)
            ]
            while var frame = stack.popLast() {
                var descended = false
                while frame.next < frame.children.count {
                    let index = frame.children[frame.next]
                    frame.next += 1
                    guard !placed.contains(index) else { continue }
                    placed.insert(index)
                    guard items[index].deleted == 0 else { continue }
                    switch items[index].content {
                    case .stroke(let stroke):
                        result.append((stroke, frame.node))
                    case .group(let child):
                        guard !removed.contains(child), !hidden.contains(child) else {
                            claimSubtree(of: child)
                            continue
                        }
                        // The parent goes back with its place kept, and the
                        // child on top of it: that is what "depth first" is
                        // once the call stack is not doing the remembering.
                        stack.append(frame)
                        stack.append(
                            (child, chainOrder(childrenOfNode[child] ?? [], items: items), 0)
                        )
                        descended = true
                    case .image(let key, let vertices):
                        // Its place in the sequence travels as the number of
                        // strokes before it: the z-order is the sequence.
                        images.append(PlacedImageItem(
                            key: key,
                            vertices: vertices,
                            strokesBefore: result.count,
                            parent: frame.node
                        ))
                    case nil:
                        break
                    }
                    if descended { break }
                }
            }
        }
        for rootIndex in items.indices where !interior.contains(items[rootIndex].parent) {
            let root = items[rootIndex].parent
            guard !placed.contains(rootIndex) else { continue }
            walk(from: root)
        }

        // Whatever the walk never reached — in file order.
        for index in items.indices where !placed.contains(index) {
            guard items[index].deleted == 0 else { continue }
            let parent = items[index].parent
            guard !removed.contains(parent), !hidden.contains(parent) else { continue }
            switch items[index].content {
            case .stroke(let stroke):
                result.append((stroke, parent))
            case .image(let key, let vertices):
                images.append(PlacedImageItem(
                    key: key,
                    vertices: vertices,
                    strokesBefore: result.count,
                    parent: parent
                ))
            default:
                break
            }
        }
        return (result, images)
    }

    /// An image item as the scene walk hands it over: the attachment it
    /// names, its place in the drawing order, and the node it hangs on — the
    /// parent is what says whether it is anchored.
    private struct PlacedImageItem {
        let key: [UInt8]
        let vertices: [PageImage.Vertex]
        let strokesBefore: Int
        let parent: CrdtID
    }

    /// The attachment map (`0x0E`): a 16-byte opaque key to a file name in
    /// the document's index. One block declares every attachment of the page
    /// — it is a list, not a record per asset.
    private static func parseAttachmentMap(
        _ reader: inout RMBinaryReader,
        end: Int
    ) throws -> [[UInt8]: String] {
        var map: [[UInt8]: String] = [:]
        guard reader.matchTag(index: 1, type: .length4) else { return map }
        _ = try reader.readUInt32()
        let count = try reader.readCount()
        for _ in 0..<count {
            guard reader.offset < end, reader.matchTag(index: 0, type: .length4) else { break }
            let entryLength = Int(try reader.readUInt32())
            let entryEnd = reader.offset + entryLength
            guard entryEnd <= end else { break }
            let key = try reader.readBytes(16)
            if reader.matchTag(index: 1, type: .length4) {
                _ = try reader.readUInt32()
                if reader.matchTag(index: 1, type: .id) { _ = try reader.readBareCrdtID() }
                if reader.matchTag(index: 2, type: .length4) {
                    let stringLength = Int(try reader.readUInt32())
                    let name = try reader.readString(upTo: reader.offset + stringLength)
                    if !name.isEmpty { map[key] = name }
                }
            }
            try reader.seek(to: entryEnd)
        }
        return map
    }

    /// An image on the page (`0x0F`): the same preamble as a stroke, and a
    /// value of type 7 — the attachment's key and the four vertices
    /// `(x, y, u, v)` that place, scale, crop or turn it.
    ///
    /// `end` bounds the vertex list for the same reason it bounds the
    /// highlight's rectangles: the count in front of it is the file's word,
    /// not a measurement.
    private static func parseImageItem(
        _ reader: inout RMBinaryReader,
        end: Int
    ) throws -> SceneItem {
        let preamble = try parsePreamble(&reader)
        let tombstone = SceneItem(
            parent: preamble.parent,
            id: preamble.id,
            left: preamble.left,
            deleted: preamble.deleted,
            content: nil
        )
        guard reader.matchValue(before: end) else { return tombstone }
        _ = try reader.readUInt32()                      // value length
        // From here on the value is there, and the tombstone is no longer an
        // honest answer: it reads as "the user erased it", and whatever goes
        // wrong below was not erased, it was lost.
        let valueType = try reader.readUInt8()
        guard valueType == imageItemType else {
            throw ParseError.malformedPage("an image item's value is of type \(valueType), not an image")
        }

        var key: [UInt8] = []
        if reader.matchTag(index: 1, type: .length4) {
            let length = Int(try reader.readUInt32())
            let subEnd = reader.offset + length
            if reader.matchTag(index: 1, type: .id) { _ = try reader.readBareCrdtID() }
            // The key sits in a tag-2 wrapper of its own; the bare spelling
            // is kept as a fallback all the same.
            if reader.matchTag(index: 2, type: .length4) {
                let keyLength = Int(try reader.readUInt32())
                if keyLength >= 16 { key = try reader.readBytes(16) }
            } else if subEnd - reader.offset >= 16 {
                key = try reader.readBytes(16)
            }
            try reader.seek(to: subEnd)
        }
        _ = try? reader.readCrdtID(index: 2)

        var vertices: [PageImage.Vertex] = []
        if reader.matchTag(index: 3, type: .length4) {
            // The list is held to its own subblock, and the subblock to the
            // block: a count that claims more floats than the list holds is
            // refused before a float is read or a byte reserved.
            let listLength = Int(try reader.readUInt32())
            let listEnd = reader.offset + listLength
            guard listEnd <= end else {
                throw ParseError.malformedPage("an image's vertex list runs past its block")
            }
            let floats = try reader.readCount()
            guard reader.offset <= listEnd, floats <= (listEnd - reader.offset) / 4 else {
                throw ParseError.malformedPage("an image declares \(floats) vertex floats, more than its list holds")
            }
            var values: [Double] = []
            values.reserveCapacity(floats)
            for _ in 0..<floats {
                let value = Double(try reader.readFloat32())
                // Four vertices place, scale and crop the image, and there is
                // no placing it on three: one number that is not a number
                // makes the whole placement unusable. Thrown rather than
                // answered with the tombstone below — a tombstone reads as
                // "the user erased it", and this was not erased, it was lost.
                guard value.isFinite else {
                    throw ParseError.malformedPage("an image vertex is not a finite one")
                }
                values.append(value)
            }
            vertices = stride(from: 0, to: values.count - 3, by: 4).map { base in
                PageImage.Vertex(
                    x: values[base], y: values[base + 1],
                    u: values[base + 2], v: values[base + 3]
                )
            }
        }

        // The same refusal as the vertex that is not a number, for the same
        // reason: a key of another length names no attachment, and there is
        // no placing a picture on three corners.
        guard key.count == 16 else {
            throw ParseError.malformedPage("an image key is \(key.count) bytes, not 16")
        }
        guard vertices.count == 4 else {
            throw ParseError.malformedPage("an image has \(vertices.count) vertices, not 4")
        }
        return SceneItem(
            parent: preamble.parent,
            id: preamble.id,
            left: preamble.left,
            deleted: preamble.deleted,
            content: .image(key: key, vertices: vertices)
        )
    }

    /// A node's children in the order of their chain: from the head at `(0,
    /// 0)`, each record followed by whatever hangs on it, and a tie between
    /// records sharing a `left` going to the newer — larger — identifier.
    /// Iterative, because a chain is as long as a page has strokes and the
    /// walk must not be a stack overflow.
    private static func chainOrder(_ indices: [Int], items: [SceneItem]) -> [Int] {
        guard indices.count > 1 else { return indices }
        var byLeft = Dictionary(grouping: indices) { items[$0].left }
        var result: [Int] = []
        result.reserveCapacity(indices.count)
        var stack: [Int] = []
        func push(after cursor: CrdtID) {
            guard let children = byLeft.removeValue(forKey: cursor) else { return }
            // Ascending, because a stack pops from the end: the newest — the
            // one that goes first — has to be pushed last.
            stack.append(contentsOf: children.sorted { isOrderedBefore(items[$0].id, items[$1].id) })
        }
        push(after: CrdtID(author: 0, counter: 0))
        while let index = stack.popLast() {
            result.append(index)
            push(after: items[index].id)
        }
        // Links that did not add up — appended as they lie, not lost.
        guard !byLeft.isEmpty else { return result }
        let reached = Set(result)
        for index in indices where !reached.contains(index) { result.append(index) }
        return result
    }

    /// Which of two identifiers is the older — the chain's tie-break reads
    /// "newer first". The counters grow monotonically as a journal of edits,
    /// so the counter decides; two counters can only tie across authors,
    /// and there the **lower** author goes first in the chain. When two
    /// tablets each add a layer with the same counter after the same
    /// neighbour, the second author's layer is drawn over the first's — the
    /// higher author later in the chain, on top.
    private static func isOrderedBefore(_ left: CrdtID, _ right: CrdtID) -> Bool {
        if left.counter != right.counter { return left.counter < right.counter }
        return left.author > right.author
    }

    /// `end` is the end of the block, and the value has to lie inside it. The
    /// value declares its own length, and until that declaration is put
    /// against the block it is only the file's word: bounding the points by it
    /// alone would still leave a stroke free to claim gigabytes.
    private static func parseLineItem(
        _ reader: inout RMBinaryReader,
        pointVersion: UInt8,
        end: Int
    ) throws -> SceneItem {
        // The parent is a node of the tree. For handwriting anchored to text
        // it is what shows that its coordinates are counted from the text.
        let preamble = try parsePreamble(&reader)
        let parent = preamble.parent

        // No value means the item was deleted, and that is an everyday
        // matter: on a long-edited page there is more erased than left. It
        // must not be treated as an error, otherwise the erased looks lost.
        // The tombstone is kept all the same — it holds its place in the
        // chain, and a later record may hang on it.
        guard reader.matchValue(before: end) else {
            return SceneItem(
                parent: parent,
                id: preamble.id,
                left: preamble.left,
                deleted: preamble.deleted,
                content: nil
            )
        }
        let valueLength = Int(try reader.readUInt32())
        let valueEnd = reader.offset + valueLength
        guard valueEnd <= end else {
            throw ParseError.malformedPage("value length \(valueLength) runs past the block")
        }

        let itemType = try reader.readUInt8()
        guard itemType == lineItemType else {
            throw ParseError.malformedPage("unexpected value type \(itemType)")
        }

        try reader.expectTag(index: 1, type: .byte4)
        let toolID = Int(try reader.readUInt32())
        try reader.expectTag(index: 2, type: .byte4)
        let colorID = Int(try reader.readUInt32())
        try reader.expectTag(index: 3, type: .byte8)
        let thicknessScale = try reader.readFloat64()
        // Refused with the stroke, as a coordinate is: the setting travels
        // with the stroke to whatever draws it, and a NaN here reaches a JSON
        // export as `nan`, which no JSON reader takes.
        guard thicknessScale.isFinite else {
            throw ParseError.malformedPage("a stroke's thickness is not a finite one")
        }
        try reader.expectTag(index: 4, type: .byte4)
        _ = try reader.readFloat32()         // starting length

        guard reader.matchTag(index: 5, type: .length4) else {
            throw ParseError.malformedPage("stroke has no points")
        }
        let pointsLength = Int(try reader.readUInt32())
        let size = try pointSize(for: pointVersion)
        guard pointsLength.isMultiple(of: size) else {
            throw ParseError.malformedPage("points length \(pointsLength) is not a multiple of \(size)")
        }
        // The points have to lie inside the value they are declared in. A
        // declared `uint32` of them is three hundred million points — five
        // gigabytes reserved on the word of a sixty-byte file. Refused rather than clamped: a stroke whose points
        // do not fit is a broken stroke, and the caller counts it as one.
        guard pointsLength <= valueEnd - reader.offset else {
            throw ParseError.malformedPage(
                "points length \(pointsLength) runs past the value"
            )
        }

        var points: [StrokePoint] = []
        points.reserveCapacity(pointsLength / size)
        for _ in 0..<(pointsLength / size) {
            points.append(try parsePoint(&reader, version: pointVersion))
        }

        // The tail of the value: a timestamp, a move identifier and an
        // optional explicit colour. It must not be skipped: where a stroke's
        // colour is not one the palette names, this field is the only record
        // of it.
        //
        // Each looked for inside the value only. A value that stops short
        // of them ends where the next block begins, and that block's length
        // reads as a tag as well as anything: 388 spells the colour's `84 01`.
        if reader.offset < valueEnd { _ = try? reader.skipCrdtID(index: 6) }     // timestamp
        if reader.offset < valueEnd { _ = try? reader.skipCrdtID(index: 7) }     // move identifier
        var argb: UInt32?
        if reader.offset < valueEnd, reader.matchTag(index: 8, type: .byte4), reader.offset + 4 <= valueEnd {
            argb = try? reader.readUInt32()
        }
        // The stroke an eraser cut this one from — on a shader only, and what
        // tells the pieces of one stroke from strokes that merely cross.
        var sourceId: SceneItemID?
        let beforeSource = reader.offset
        if reader.offset < valueEnd, reader.matchTag(index: 9, type: .id),
           let source = try? reader.readBareCrdtID(), reader.offset <= valueEnd {
            sourceId = SceneItemID(source)
        } else {
            try? reader.seek(to: beforeSource)
        }

        // The rest of the tail is of no use to us — we jump to the end of the
        // subblock.
        try reader.seek(to: valueEnd)

        let stroke = Stroke(
            tool: PenTool(rawValue: toolID),
            color: PenColor(rawValue: colorID) ?? .black,
            thicknessScale: thicknessScale,
            points: points,
            argb: argb,
            id: SceneItemID(preamble.id),
            sourceId: sourceId
        )
        return SceneItem(
            parent: parent,
            id: preamble.id,
            left: preamble.left,
            deleted: preamble.deleted,
            content: .stroke(stroke)
        )
    }

    /// A scene tree node: its own identifier, whether it is shown, the sign
    /// of an anchor into the text and the anchor's own horizontal.
    ///
    /// The horizontal is the file's ready answer — `anchor_origin_x`, tag 10
    /// — and it cannot always be recomputed: on the boundary of two writing
    /// directions the caret is ambiguous. The remaining fields (the layer's
    /// name, the anchor type and threshold) are skipped by length.
    private struct TreeNode {
        let id: CrdtID
        let anchor: CrdtID?
        let originX: Double?
        let visible: Bool?
        /// The timestamp of the last write of `visible`: which of two edits
        /// of one node's visibility is the newer.
        let visibilityStamp: CrdtID
    }

    private static func parseTreeNode(
        _ reader: inout RMBinaryReader,
        end: Int
    ) throws -> TreeNode {
        let id = try reader.readCrdtID(index: 1)
        var anchor: CrdtID?
        var originX: Double?
        var visible: Bool?
        var visibilityStamp = CrdtID(author: 0, counter: 0)
        func node() -> TreeNode {
            TreeNode(id: id, anchor: anchor, originX: originX, visible: visible, visibilityStamp: visibilityStamp)
        }

        while reader.offset < end, let tag = try? reader.readTag() {
            switch tag.type {
            case RMBinaryReader.TagType.length4.rawValue:
                let length = Int(try reader.readUInt32())
                let subEnd = reader.offset + length
                guard subEnd <= end else { return node() }
                switch tag.index {
                case anchorTag:
                    // There are two identifiers here. The first is unique to
                    // the node, while the one pointing at a character of the
                    // text is the second.
                    _ = try? reader.readCrdtID(index: 1)
                    anchor = try? reader.readCrdtID(index: 2)
                case anchorOriginTag:
                    // The stamped spelling: a last-write-wins record — the
                    // timestamp, then the value. This is what the tablet
                    // writes, for this field and for the three beside it; the
                    // bare spelling is read below as well. A field lost to the
                    // difference would mean a silently recomputed horizontal.
                    _ = try? reader.readCrdtID(index: 1)
                    // Left unset when it is not a place, the way the text
                    // origin is: the horizontal is optional, and a renderer
                    // without it recomputes — a renderer with a NaN draws the
                    // handwriting nowhere.
                    if reader.matchTag(index: 2, type: .byte4),
                       let value = try? reader.readFloat32(), value.isFinite {
                        originX = Double(value)
                    }
                case visibilityTag:
                    // The timestamp of the last write and then the flag. The
                    // timestamp is kept: of two edits of one node's
                    // visibility, the newer wins. A layer never hidden or
                    // shown carries (0, 0); every hide and every show is an
                    // edit with a real identifier.
                    if let stamp = try? reader.readCrdtID(index: 1) { visibilityStamp = stamp }
                    if reader.matchTag(index: 2, type: .byte1) {
                        visible = (try? reader.readUInt8()) != 0
                    }
                default:
                    break
                }
                try reader.seek(to: subEnd)
            case RMBinaryReader.TagType.byte4.rawValue:
                if tag.index == anchorOriginTag {
                    let value = try reader.readFloat32()
                    if value.isFinite { originX = Double(value) }
                } else {
                    _ = try reader.readUInt32()
                }
            case RMBinaryReader.TagType.byte8.rawValue: _ = try reader.readFloat64()
            case RMBinaryReader.TagType.byte1.rawValue: _ = try reader.readUInt8()
            case RMBinaryReader.TagType.id.rawValue:
                _ = try reader.readUInt8()
                _ = try reader.readVarUInt()
            default:
                // An unknown type — going further into the block blind is not
                // an option.
                return node()
            }
        }
        return node()
    }

    /// The layout of typed text: where it starts and which line each
    /// character stands on.
    struct TextLayout: Sendable {
        let origin: (x: Double, y: Double)
        /// Where each character stands: its paragraph and how many characters
        /// of that paragraph come before the pen once it is typed. It is what
        /// locates anchored handwriting.
        let placeOfCharacter: [CrdtID: TextAnchor]
        /// The place an anchor points at.
        ///
        /// Most anchors name a character, and the answer is the pen position
        /// just past it. Two do not: the format has sentinel identifiers for
        /// the start and the end of the text, and handwriting placed before or
        /// after everything typed is anchored to those instead.
        ///
        /// They must not be left to the "nowhere" fallback: treating a
        /// sentinel as line zero drags every stroke anchored to it to the
        /// top of the text.
        func anchor(of anchor: CrdtID) -> TextAnchor? {
            if let exact = placeOfCharacter[anchor] { return exact }
            switch anchor.counter {
            case Self.startSentinel:
                return TextAnchor(paragraph: 0, offset: 0)
            case Self.endSentinel:
                // Just past the last character, the way any anchor is — and
                // a newline, like every newline, ends its own paragraph: text
                // ending in a Return puts the pen at the end of the paragraph
                // that Return closes, not in the empty one after it.
                // The offset is one past the letters: an anchor names the
                // character the pen stands before, and after the text that
                // is the one that would come next.
                // No text at all — no lines, or the one empty line the
                // parser starts with — ends where it starts.
                guard let last = lines.indices.last, lines != [""] else {
                    return TextAnchor(paragraph: 0, offset: 0)
                }
                let paragraph = lines[last].isEmpty && last > 0 ? last - 1 : last
                return TextAnchor(paragraph: paragraph, offset: lines[paragraph].unicodeScalars.count + 1)
            default: return nil
            }
        }

        /// `0xFFFFFFFFFFFE` and `0xFFFFFFFFFFFF` — the identifiers the format
        /// reserves for "before the text" and "after the text".
        static let startSentinel: UInt64 = 0xFFFF_FFFF_FFFE
        static let endSentinel: UInt64 = 0xFFFF_FFFF_FFFF

        /// The text itself, in document order, split at the newlines.
        ///
        /// Kept because typed text has to be drawn, not merely serve as a
        /// coordinate system for the handwriting anchored to it.
        let lines: [String]
        /// How a paragraph is presented, by its index in `lines`. Absent
        /// means plain text. The bullets and the checkboxes of a typed list
        /// live nowhere else in the file.
        let formatOfLine: [Int: ParagraphFormat]
        /// The bold and italic stretches, by line.
        let faces: [Int: [FaceRun]]
        /// The column width the block declares, when it declares one.
        let columnWidth: Double?
    }

    /// One item of text: its own identifier, its neighbours in the CRDT list
    /// and the characters themselves. The characters get identifiers running
    /// on from the item's identifier.
    private struct TextItem {
        let id: CrdtID
        let left: CrdtID
        let right: CrdtID
        let text: String
        /// How many characters this record deletes. Deleted characters keep
        /// their identifiers, so the next record's `left` counts past them —
        /// the ordering below has to step over them too.
        let deleted: UInt32
        /// The code a record carries when it is not text but a marker — any
        /// value but nought; `nil` for text. 1 bold on, 2 bold off, 3 italic
        /// on, 4 italic off: odd switches on and even switches off — but not
        /// one pair for every purpose, or italic would use the same two
        /// numbers as bold. 5 and 6 open and close a link, and the opening
        /// record's string is the address. `0xFFFFFFFF` is an image in the
        /// flow of the text, and its string is the `{UUID}` key of the
        /// image's row in block `0x0E`.
        ///
        /// Whatever its string, a marker takes exactly one identifier: the
        /// address of a link adds no characters to the text.
        let marker: UInt32?

        /// How many identifiers the record covers: the characters it carries,
        /// the ones it deleted, or the single one of a marker.
        var span: UInt64 {
            if marker != nil { return 1 }
            return text.isEmpty ? UInt64(deleted) : UInt64(text.unicodeScalars.count)
        }
    }

    /// The marker codes of a text record that are not faces.
    private static let linkStartMark: UInt32 = 5
    private static let linkEndMark: UInt32 = 6
    private static let inlineImageMark: UInt32 = 0xFFFF_FFFF
    /// What stands in the text for an image in its flow — the character the
    /// tablet's own layout puts there (U+FFFC).
    private static let objectReplacement: Unicode.Scalar = "\u{FFFC}"

    private static func parseRootText(
        _ reader: inout RMBinaryReader,
        end: Int
    ) throws -> TextLayout? {
        _ = try reader.readCrdtID(index: 1)

        var items: [TextItem] = []
        var styles: [(key: CrdtID, format: ParagraphFormat)] = []
        var origin: (x: Double, y: Double)?
        var columnWidth: Double?
        var settingsWidth: Double?

        while reader.offset < end, let tag = try? reader.readTag() {
            // The column width is the one field of this block that is not a
            // subblock; stopping at it would leave it unread.
            if tag.type == RMBinaryReader.TagType.byte4.rawValue {
                let value = Double(try reader.readFloat32())
                if tag.index == columnWidthTag, value.isFinite, value > 0 { columnWidth = value }
                continue
            }
            guard tag.type == RMBinaryReader.TagType.length4.rawValue else { break }
            let length = Int(try reader.readUInt32())
            let subEnd = reader.offset + length
            guard subEnd <= end else { break }

            if tag.index == textItemsTag {
                // Two lists live side by side in here: the text itself and
                // the styles of its paragraphs. The reader is handed the same
                // window twice — the items parser stops where its own list
                // ends, and the styles begin right after it.
                var forItems = reader
                items = (try? parseTextItems(&forItems, end: subEnd)) ?? []
                styles = (try? parseParagraphStyles(&forItems, end: subEnd)) ?? []
            } else if tag.index == textPositionTag, length >= 16 {
                let x = try reader.readFloat64()
                let y = try reader.readFloat64()
                // Left unset when it is not a place: the block ends with
                // `guard let origin`, so text nobody can lay out is refused
                // whole and counted, the same as text that will not parse.
                if x.isFinite, y.isFinite { origin = (x: x, y: y) }
            } else if tag.index == textSettingsTag {
                settingsWidth = Self.settingsWidth(&reader, end: subEnd)
            }
            try reader.seek(to: subEnd)
        }
        // The stamped width wins over the bare one: `tag 4` is the legacy
        // copy, taken only when the settings carry no width of their own.
        if let settingsWidth { columnWidth = settingsWidth }

        guard let origin else { return nil }
        let composed = compose(items)
        return TextLayout(
            origin: origin,
            placeOfCharacter: composed.placeOfCharacter,
            lines: composed.lines,
            formatOfLine: Self.lineFormats(styles, placeOfCharacter: composed.placeOfCharacter),
            faces: composed.faces,
            columnWidth: columnWidth
        )
    }

    /// The column width out of the text's settings (`tag 5`): a record whose
    /// `tag 1` is the width as a last-write-wins value — the stamp, then the
    /// `float32`. Pages nest it so, one level deeper than a bare LWW
    /// (`5:{1:{1:stamp, 2:f32}}`). Anything else, or a width that is not a
    /// width, answers `nil`.
    private static func settingsWidth(_ reader: inout RMBinaryReader, end: Int) -> Double? {
        guard reader.matchTag(index: 1, type: .length4),
              let length = try? reader.readUInt32()
        else { return nil }
        let widthEnd = reader.offset + Int(length)
        guard widthEnd <= end,
              (try? reader.readCrdtID(index: 1)) != nil,
              reader.matchTag(index: 2, type: .byte4),
              reader.offset + 4 <= widthEnd,
              let value = try? reader.readFloat32()
        else { return nil }
        let width = Double(value)
        return width.isFinite && width > 0 ? width : nil
    }

    /// Which line each paragraph style belongs to.
    ///
    /// A style is keyed by the character that **ends the paragraph before**
    /// it — the newline — and so belongs to the line after that one. The
    /// first paragraph has no newline before it and is keyed by the format's
    /// start-of-text sentinel instead.
    private static func lineFormats(
        _ styles: [(key: CrdtID, format: ParagraphFormat)],
        placeOfCharacter: [CrdtID: TextAnchor]
    ) -> [Int: ParagraphFormat] {
        var result: [Int: ParagraphFormat] = [:]
        // In file order, so that two styles landing on one line resolve the
        // same way on every run: the later one wins. Walked out of a
        // dictionary, the winner would be whichever its hash put last.
        for (key, style) in styles {
            if key == CrdtID(author: 0, counter: 0) {
                result[0] = style
            } else if let place = placeOfCharacter[key] {
                result[place.paragraph + 1] = style
            }
        }
        return result
    }

    /// The styles of the paragraphs, keyed by the character each one follows.
    ///
    /// The list stands right after the text items inside the same block. Its
    /// records are short: the key written bare, then the timestamp of the
    /// last write, then the style itself in a sub-block.
    private static func parseParagraphStyles(
        _ reader: inout RMBinaryReader,
        end: Int
    ) throws -> [(key: CrdtID, format: ParagraphFormat)] {
        guard reader.matchTag(index: 2, type: .length4) else { return [] }
        _ = try reader.readUInt32()
        guard reader.matchTag(index: 1, type: .length4) else { return [] }
        let listLength = Int(try reader.readUInt32())
        let listEnd = min(reader.offset + listLength, end)
        let count = try reader.readCount()

        var styles: [(key: CrdtID, format: ParagraphFormat)] = []
        for _ in 0..<count {
            guard reader.offset < listEnd else { break }
            let key = try reader.readBareCrdtID()
            // The timestamp of the last write. Kept only to step over it: with
            // one writer there is nothing to resolve.
            _ = try? reader.readCrdtID(index: 1)
            guard reader.matchTag(index: 2, type: .length4) else { break }
            let valueLength = Int(try reader.readUInt32())
            let valueEnd = reader.offset + valueLength
            guard valueEnd <= listEnd else { break }
            if reader.matchTag(index: 1, type: .byte1) {
                let raw = try reader.readUInt8()
                // The value goes on past the first field, and reading only
                // the first would run two different presentations together: an
                // emphasised paragraph and a subheading both carry `3`, and
                // apart they are told only by these.
                var hasFurtherFields = false
                var second: UInt8?
                var third: UInt32?
                if reader.matchTag(index: 2, type: .byte1) {
                    second = try reader.readUInt8()
                    hasFurtherFields = true
                }
                if reader.matchTag(index: 3, type: .byte4) {
                    third = try reader.readUInt32()
                    hasFurtherFields = true
                }
                // Stored as a pair, not interpreted field-by-field: telling
                // the known shapes apart is all the page needs. Two are
                // known: (2, 3) on the second heading, and
                // (3, state << 8 | family << 4 | depth) on a list item —
                // families 0…2, depths 0…2, and the state bits 8 (ticked) and
                // 9 (something nested is ticked) that a checkbox item may
                // carry, the first level included. Logged so that the
                // unknown reports itself — a third shape would otherwise
                // arrive in silence.
                let headingPair = second == 2 && third == 3
                let nestedListPair = second == 3
                    && third.map { $0 >> 10 == 0 && ($0 >> 4) & 0x0F <= 2 && $0 & 0x0F <= 2 } == true
                if hasFurtherFields, !headingPair, !nestedListPair {
                    RMLinesLog.debug(
                        """
                        page: paragraph style \(raw) carries an unseen pair \
                        (\(second.map(String.init) ?? "-"), \
                        \(third.map(String.init) ?? "-"))
                        """
                    )
                }
                styles.append((key: key, format: ParagraphFormat(raw: raw, second: second, third: third)))
                if ParagraphStyle(rawValue: raw) == nil {
                    // A style we do not know is kept and drawn as plain text,
                    // and said out loud.
                    RMLinesLog.debug("render: unknown paragraph style \(raw)")
                }
            }
            try reader.seek(to: valueEnd)
        }
        return styles
    }

    /// The text items lie in a nested list: a container, a list, a counter
    /// and then one record per item.
    private static func parseTextItems(
        _ reader: inout RMBinaryReader,
        end: Int
    ) throws -> [TextItem] {
        guard reader.matchTag(index: 1, type: .length4) else { return [] }
        _ = try reader.readUInt32()
        guard reader.matchTag(index: 1, type: .length4) else { return [] }
        let listLength = Int(try reader.readUInt32())
        let listEnd = min(reader.offset + listLength, end)
        let count = try reader.readCount()

        var items: [TextItem] = []
        for _ in 0..<count {
            guard reader.offset < listEnd, reader.matchTag(index: 0, type: .length4) else { break }
            let itemLength = Int(try reader.readUInt32())
            let itemEnd = reader.offset + itemLength
            guard itemEnd <= listEnd else { break }

            let id = try reader.readCrdtID(index: 2)
            let left = try reader.readCrdtID(index: 3)
            let right = try reader.readCrdtID(index: 4)
            try reader.expectTag(index: 5, type: .byte4)
            let deletedLength = try reader.readUInt32()

            var text = ""
            var marker: UInt32?
            if reader.matchTag(index: 6, type: .length4) {
                let valueLength = Int(try reader.readUInt32())
                // Held to the record: a value that claims more than its record
                // holds would otherwise read the next record's bytes as its
                // own — and a marker found there would quietly turn this
                // record's text into nothing.
                let valueEnd = min(reader.offset + valueLength, itemEnd)
                text = try reader.readString(upTo: valueEnd)
                // A record whose value goes on past the string is not text but
                // markup: the value carries a field an ordinary record has not
                // got, and that field says what the record marks. Bold and
                // italic are nowhere in the list of paragraph styles — a
                // paragraph with a bold word in it calls itself plain.
                //
                // Looked for whatever the string: a link's opening record
                // spells its address there, and an image in the flow its key,
                // and read as text either would land on the page as letters.
                // The tablet writes the field only when it is not nought.
                if reader.offset < valueEnd,
                   reader.matchTag(index: markerTag, type: .byte4),
                   reader.offset + 4 <= valueEnd {
                    let code = try reader.readUInt32()
                    if code != 0 { marker = code }
                }
                try reader.seek(to: valueEnd)
            }

            items.append(
                TextItem(
                    id: id,
                    left: left,
                    right: right,
                    text: text,
                    deleted: deletedLength,
                    marker: marker
                )
            )
            try reader.seek(to: itemEnd)
        }
        return items
    }

    /// The text, its line numbers and its faces — one walk of the items in
    /// document order.
    ///
    /// One walk and not three, so that what gets drawn, what the handwriting
    /// is positioned against and what is set in bold cannot drift apart. The
    /// order is set by the `left` links: an item follows the character its
    /// link points at. Sorting by the counter will not do — an item added
    /// later may stand in the middle, and the marks of a face are added last
    /// of all.
    private static func compose(_ items: [TextItem]) -> (
        lines: [String],
        placeOfCharacter: [CrdtID: TextAnchor],
        faces: [Int: [FaceRun]]
    ) {
        var lines: [String] = [""]
        var placeOfCharacter: [CrdtID: TextAnchor] = [:]
        // The face of every character, gathered into stretches below. Kept
        // per character rather than as ranges while reading, because bold and
        // italic switch independently and a range would have to be broken and
        // begun again at each of the four marks.
        var marks: [[Face]] = [[]]
        var face = Face(bold: false, italic: false)
        // Scalars in the current paragraph get their own counter:
        // `String.count` counts graphemes, and a combining mark does not
        // grow it while the file does give it an identifier.
        var scalars = 0

        for item in inDocumentOrder(items) {
            if let mark = item.marker {
                switch mark {
                case 1: face.bold = true
                case 2: face.bold = false
                case 3: face.italic = true
                case 4: face.italic = false
                case linkStartMark, linkEndMark:
                    // A link of typed text: kept by the tablet, not drawn as
                    // a link. Its characters are the ordinary
                    // records between the two marks, and they stay text.
                    break
                case inlineImageMark:
                    // An image in the flow is one character of the text — the
                    // object replacement character — and takes its place in
                    // the paragraph, so the offsets after it are the tablet's.
                    // A deleted one is no character at all.
                    guard item.deleted == 0 else { break }
                    let paragraph = lines.count - 1
                    lines[paragraph].unicodeScalars.append(objectReplacement)
                    marks[marks.count - 1].append(face)
                    scalars += 1
                    placeOfCharacter[item.id] = TextAnchor(paragraph: paragraph, offset: scalars)
                default:
                    RMLinesLog.debug("render: unknown text mark \(mark)")
                }
                continue
            }
            // By Unicode scalars, not by graphemes: the file numbers
            // characters as scalars. On NFC Latin and Cyrillic the two
            // agree; on Arabic diacritics they do not, and a grapheme count
            // shifts every style key and anchor after the first such mark.
            var offset = 0
            for scalar in item.text.unicodeScalars {
                // The characters run on from the item's own identifier. On a
                // corrupted file that identifier can sit at the top of the
                // range, and the sum would be a trap — which takes the process
                // rather than the page. The text is still worth drawing; what
                // is lost is the anchoring of handwriting to these characters.
                let (counter, overflowed) = item.id.counter.addingReportingOverflow(UInt64(offset))
                let id = overflowed ? nil : CrdtID(author: item.id.author, counter: counter)
                offset += 1
                let paragraph = lines.count - 1
                if scalar == "\n" {
                    // A newline ends its paragraph, and the pen that typed it
                    // stood at the end of that paragraph rather than at the
                    // start of the next one. It is the paragraph's character
                    // after the last letter, and the pen stands before the
                    // character an anchor names — so one past the letters,
                    // not on the last of them.
                    if let id { placeOfCharacter[id] = TextAnchor(paragraph: paragraph, offset: scalars + 1) }
                    lines.append("")
                    marks.append([])
                    scalars = 0
                } else {
                    lines[paragraph].unicodeScalars.append(scalar)
                    marks[marks.count - 1].append(face)
                    scalars += 1
                    // The character's own number, counted from one: the
                    // renderer stands the pen before the character an anchor
                    // names.
                    if let id { placeOfCharacter[id] = TextAnchor(paragraph: paragraph, offset: scalars) }
                }
            }
        }

        return (lines, placeOfCharacter, faces(from: marks))
    }

    /// The face of a single character.
    private struct Face: Hashable {
        var bold: Bool
        var italic: Bool
    }

    /// Neighbouring characters of one face gathered into a stretch. Plain
    /// text yields nothing: most of a page is plain, and an entry per line
    /// saying so would be an entry for nothing.
    private static func faces(from marks: [[Face]]) -> [Int: [FaceRun]] {
        var result: [Int: [FaceRun]] = [:]
        for (number, row) in marks.enumerated() {
            var runs: [FaceRun] = []
            var start = 0
            while start < row.count {
                let face = row[start]
                var end = start + 1
                while end < row.count, row[end] == face { end += 1 }
                if face.bold || face.italic {
                    runs.append(FaceRun(range: start..<end, bold: face.bold, italic: face.italic))
                }
                start = end
            }
            if !runs.isEmpty { result[number] = runs }
        }
        return result
    }

    /// The items in the order they read.
    ///
    /// The order is set by the `left` links: an item follows the character
    /// its link points at. Sorting by the counter will not do here — an item
    /// added later may stand in the middle.
    private static func inDocumentOrder(_ items: [TextItem]) -> [TextItem] {
        // By the same index `chainOrder` uses, and for the same reason:
        // filtering the whole of what is left at every step and deleting from
        // the middle of it would be quadratic in the number of records — and
        // a page accumulates a record per edit, so the number is the file's
        // to choose. On a page big enough that is the parse itself hanging,
        // in a task nothing interrupts.
        var byLeft: [CrdtID: [Int]] = [:]
        for index in items.indices { byLeft[items[index].left, default: []].append(index) }
        var taken = [Bool](repeating: false, count: items.count)

        // The order in which one bucket's records leave it depends on that
        // bucket and on nothing else — not on the cursor, not on what has been
        // read elsewhere — so it is worked out once per bucket rather than
        // derived again on every visit: a page whose records all name one
        // `left` would re-scan the whole tie on every one of them, and the
        // cost would grow with the square, inside a parse nothing interrupts.
        var queue = byLeft.mapValues { ArraySlice(tieOrder($0, items: items)) }

        var ordered: [TextItem] = []
        ordered.reserveCapacity(items.count)
        var cursor = CrdtID(author: 0, counter: 0)

        while ordered.count < items.count {
            // A record leaves its bucket once, so what is still in the queue is
            // exactly what has not been taken — no filtering left to do.
            guard let index = queue[cursor]?.popFirst() else { break }
            taken[index] = true
            let item = items[index]
            ordered.append(item)
            // The characters this record covers: the ones it carries, the
            // ones it deleted — a deletion holds its place in the sequence —
            // or the one of a marker, whatever its string spells. Counted in
            // Unicode scalars, the way the identifiers run.
            let span = item.span
            // The same sum as in `compose`, and the same reason for asking
            // rather than adding: an identifier at the top of the range is a
            // trap here. An overflow leaves the cursor on the item itself —
            // the chain will not add up and the rest is appended in file
            // order, which is what this walk already does with broken links.
            if span == 0 {
                cursor = item.id
            } else {
                let (counter, overflowed) = item.id.counter.addingReportingOverflow(span - 1)
                cursor = overflowed ? item.id : CrdtID(author: item.id.author, counter: counter)
            }
        }
        // The links did not add up — the rest is appended as it lies, in file
        // order, so as not to lose it.
        for index in items.indices where !taken[index] { ordered.append(items[index]) }
        return ordered
    }

    /// The order in which the records of one tie leave it.
    ///
    /// Two records with the same left neighbour are an everyday matter in a
    /// CRDT. The one that comes first is the one whose own right link points
    /// at another record of the same tie — a record inserted between `left`
    /// and an existing record carries that record's id as its `right` and
    /// stands before it. Where none does, file order decides.
    ///
    /// That rule reads a record against **what is still left of the tie**,
    /// but it need not be asked afresh at every step: taking
    /// a record can only shrink the set of identifiers the tie holds, so a
    /// record whose right has already fallen outside can never fall back in.
    /// Both answers the rule needs — the first record still in the tie, and
    /// the first one still pointing inside it — therefore only ever move
    /// forward, and two marks walking the tie once give the whole order in
    /// time proportional to its size instead of to its square.
    private static func tieOrder(_ bucket: [Int], items: [TextItem]) -> [Int] {
        guard bucket.count > 1 else { return bucket }

        // How many records of the tie still carry each identifier. Counted and
        // not gathered into a set: two records may share an id, and the id
        // leaves the tie only with the last of them.
        var idCount: [CrdtID: Int] = [:]
        for index in bucket { idCount[items[index].id, default: 0] += 1 }

        // Which positions point at each identifier, so that the identifier
        // leaving the tie can put them all out at once. Every position leaves
        // at most once, which is what keeps the total linear.
        var dependents: [CrdtID: [Int]] = [:]
        var pointsInside = [Bool](repeating: false, count: bucket.count)
        for (position, index) in bucket.enumerated() where idCount[items[index].right] != nil {
            pointsInside[position] = true
            dependents[items[index].right, default: []].append(position)
        }

        var gone = [Bool](repeating: false, count: bucket.count)
        // The two marks. Neither ever goes back: a position it has passed is
        // either gone from the tie or has stopped pointing inside it, and
        // neither is undone.
        var pointing = 0
        var present = 0
        var order: [Int] = []
        order.reserveCapacity(bucket.count)

        while order.count < bucket.count {
            while pointing < bucket.count, gone[pointing] || !pointsInside[pointing] {
                pointing += 1
            }
            let position: Int
            if pointing < bucket.count {
                position = pointing
            } else {
                while present < bucket.count, gone[present] { present += 1 }
                guard present < bucket.count else { break }
                position = present
            }

            gone[position] = true
            order.append(bucket[position])

            let id = items[bucket[position]].id
            guard let carried = idCount[id] else { continue }
            if carried > 1 {
                idCount[id] = carried - 1
            } else {
                idCount[id] = nil
                for pointer in dependents[id] ?? [] { pointsInside[pointer] = false }
            }
        }
        return order
    }

    private static func pointSize(for version: UInt8) throws -> Int {
        switch version {
        case 1: 0x18
        case 2: 0x0E
        default: throw ParseError.unsupportedFormat("point version \(version)")
        }
    }

    /// After the coordinates, version one stores speed, direction, width and
    /// pressure, each a float32; version two stores speed and width as uint16
    /// and direction and pressure as bytes, in the order speed, width,
    /// direction, pressure.
    private static func parsePoint(
        _ reader: inout RMBinaryReader,
        version: UInt8
    ) throws -> StrokePoint {
        let x = try reader.readFloat32()
        let y = try reader.readFloat32()
        // A coordinate that is not a number is not a coordinate. It travels
        // through `CGRect` and `CGPath` without a complaint of any kind and
        // comes out in the sheet's own size, where a NaN width is a PDF no
        // reader opens; worse, whether it is noticed at all depends on where
        // in the stroke it sits, because `min` and `max` keep the argument
        // they are given first. Refused here, at the one door every point
        // comes through. The stroke is lost whole rather than mended: joining
        // the neighbours of a dropped point draws a line the user never made,
        // and the caller already counts an unreadable stroke as the loss it is.
        guard x.isFinite, y.isFinite else {
            throw ParseError.malformedPage("a point is not at a finite place")
        }

        if version == 1 {
            // Speed is scaled as the width is, by analogy: the version-one
            // speed unit is not known.
            let speed = try reader.readFloat32() * 4
            _ = try reader.readFloat32()                     // direction
            let width = try reader.readFloat32() * 4
            let pressure = try reader.readFloat32() * 255
            // The same door for the width and the pressure: a NaN here is a
            // NaN pen, and it travels as far as a NaN coordinate does. Checked
            // after the scaling, because a finite float near the top overflows
            // by it.
            guard width.isFinite, pressure.isFinite else {
                throw ParseError.malformedPage("a point's pen is not a finite one")
            }
            // Not a door for the speed: nothing is drawn by it, so the stroke
            // is not lost for one that is not a number — it reads as nought
            // instead. Checked after the scaling, because a finite float near
            // the top overflows by it.
            return StrokePoint(
                x: x, y: y, width: width, pressure: pressure,
                speed: speed.isFinite ? speed : 0
            )
        }

        let speed = Float(try reader.readUInt16())
        let width = Float(try reader.readUInt16())
        _ = try reader.readUInt8()                            // direction
        let pressure = Float(try reader.readUInt8())
        return StrokePoint(x: x, y: y, width: width, pressure: pressure, speed: speed)
    }
}
