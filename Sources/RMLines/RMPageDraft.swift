// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// A page to be written: everything `RMWriter.page` needs, in the same
/// vocabulary the parser answers in.
///
/// The draft speaks values, not settings: stroke points carry the raw
/// numbers the file stores (a width of 12, not a pen with a ramp), and a
/// mark carries the horizontal its pen stands at — where that number comes
/// from is the caller's business, because the format knows no layout.
public struct RMPageDraft: Sendable {
    /// The sheet the page declares, the three ways the tablet declares
    /// it. Which sheet it is decides where absolute units land — a page
    /// claiming the legacy 1404 × 1872 puts its text in the side area of
    /// a Paper Pro Move.
    public struct Sheet: Sendable {
        /// `tag 5` of SceneInfo — the size as whole units.
        public var screenWidth: UInt32
        public var screenHeight: UInt32
        /// `tags 7` and `8` — the same size unrounded, and the one the
        /// format calls authoritative.
        public var canvasWidth: Double
        public var canvasHeight: Double

        public init(
            screenWidth: UInt32,
            screenHeight: UInt32,
            canvasWidth: Double,
            canvasHeight: Double
        ) {
            self.screenWidth = screenWidth
            self.screenHeight = screenHeight
            self.canvasWidth = canvasWidth
            self.canvasHeight = canvasHeight
        }
    }

    /// The typed-text column: its width in the file's own units, and which
    /// of the tablet's three settings that is — `tag 9` stores the setting,
    /// not the width. The two have to agree.
    public struct Column: Sendable {
        public var width: Float
        public var setting: UInt8

        /// The pair as the tablet keeps it. `TextColumn` spells the three
        /// values the tablet actually offers, and taking one of those is how
        /// a caller is kept from inventing a fourth or pairing a width with
        /// the wrong setting.
        public init(_ column: TextColumn) {
            self.init(width: column.width, setting: column.setting)
        }

        /// A width and a setting chosen outright, for a page this package has
        /// no name for. It is on the caller that the two agree.
        public init(width: Float, setting: UInt8) {
            self.width = width
            self.setting = setting
        }
    }

    /// One paragraph of the typed text.
    public struct Paragraph: Sendable {
        public var text: String
        /// The `tag 1` style value; nil writes no style record (plain body).
        public var style: UInt8?
        /// `tag 2` / `tag 3` of the style record (emphasised paragraphs,
        /// nested lists).
        public var second: UInt8?
        public var third: UInt32?
        public var bold: Bool
        public var italic: Bool

        public init(
            _ text: String,
            style: UInt8? = nil,
            second: UInt8? = nil,
            third: UInt32? = nil,
            bold: Bool = false,
            italic: Bool = false
        ) {
            self.text = text
            self.style = style
            self.second = second
            self.third = third
            self.bold = bold
            self.italic = italic
        }
    }

    /// One sample of a stroke, with the raw numbers the file stores beside
    /// the coordinates. The drawn half-width is `width / 4` in sheet
    /// units; the writer stores, it does not interpret.
    public struct Point: Sendable {
        public var x: Float
        public var y: Float
        public var speed: UInt16
        public var width: UInt16
        public var direction: UInt8
        public var pressure: UInt8

        public init(
            x: Float,
            y: Float,
            speed: UInt16 = 0,
            width: UInt16 = 12,
            direction: UInt8 = 0,
            pressure: UInt8 = 6
        ) {
            self.x = x
            self.y = y
            self.speed = speed
            self.width = width
            self.direction = direction
            self.pressure = pressure
        }
    }

    /// One stroke: the tool, the colour, and the points as written.
    public struct Stroke: Sendable {
        public var tool: PenTool
        /// The palette index, `tag 2` of the stroke.
        public var color: PenColor
        /// `tag 8`, `0xAARRGGBB`. Set only where an index cannot name the
        /// colour: the highlighter's blue and orange, and the shader's
        /// colours.
        public var argb: UInt32?
        /// `thicknessScale` — the setting on the tablet, 1, 2 or 3, and not
        /// a factor: whatever it does to the line is already in `width`.
        public var thickness: Double
        public var points: [Point]

        public init(
            tool: PenTool,
            color: PenColor,
            argb: UInt32? = nil,
            thickness: Double = 2,
            points: [Point]
        ) {
            self.tool = tool
            self.color = color
            self.argb = argb
            self.thickness = thickness
            self.points = points
        }
    }

    /// What an anchored stroke hangs on.
    ///
    /// Frozen: this framework ships in lockstep with what links it, so there is
    /// no ABI to protect — and an exhaustive `switch` over these cases in a
    /// consumer is the point. A new case must break its build, not fall into an
    /// `@unknown default`.
    @frozen
    public enum Anchor: Sendable {
        /// The first character of the paragraph: `anchor_type 1`,
        /// threshold 0.
        case firstCharacter(paragraph: Int)
        /// The sentinel "before the text": a line anchor, `anchor_type 2`,
        /// threshold 35.75.
        case beforeText
        /// The sentinel "after the text" — the end of the last typed line.
        case afterText
    }

    /// A stroke hung on the typed text rather than on the sheet: its
    /// coordinates are counted from the pen, so the ink follows the text
    /// when it reflows.
    public struct Mark: Sendable {
        public var anchor: Anchor
        /// `anchor_origin_x` — where the pen stands. The left edge of the
        /// text for most anchors; the end of the last line for the sentinel
        /// after it. The end of a line is the layout's to know, and the
        /// format has no layout — so the number arrives from the caller.
        public var penOrigin: Float
        public var stroke: Stroke

        public init(anchor: Anchor, penOrigin: Float, stroke: Stroke) {
            self.anchor = anchor
            self.penOrigin = penOrigin
            self.stroke = stroke
        }
    }

    /// A picture placed on the page. The pixels are not in the `.rm`: the
    /// file lives beside the page (`<doc>/<page>/<file>`), and the page
    /// carries only the 16-byte key and the placement. The key is opaque —
    /// minted at insert, not a hash
    /// of the pixels — and the UV corners of an uncropped image are plain
    /// noughts and ones.
    public struct Image: Sendable {
        /// The attachment's file name as the map spells it: `<uuid>.png`,
        /// extension included.
        public var file: String
        /// The 16 opaque bytes the item and the attachment map share.
        ///
        /// Sixteen exactly, or the writer refuses the draft: the item and the
        /// map have to name the attachment with the same bytes, and a key of
        /// another length would be written out all the same, read back as no
        /// image at all, and counted nowhere. A picture that disappears
        /// without a word is the one failure this writer must not have, so
        /// `RMWriter.page` checks the length before it writes a byte and
        /// throws `WriteError.imageKeyNotSixteenBytes` for a key of any other
        /// size. Not checked here: a draft is data, and data that traps the
        /// process it was built in is the one thing a framework must not do.
        public var key: [UInt8]
        /// The axis-aligned placement, in sheet units: x from the middle,
        /// y from the top — or, for an anchored image, both counted from the
        /// pen at the anchor, the way a mark's points are.
        public var x: Float
        public var y: Float
        public var width: Float
        public var height: Float
        /// Fastened to the typed text rather than to the sheet, when set.
        /// The tablet hangs such an image on a group
        /// carrying the same four anchor fields a mark's group does, and the
        /// item's parent is that group instead of the layer.
        public var anchor: Anchor?
        /// `anchor_origin_x` for the anchored placement — where the pen
        /// stands, exactly as on a mark. Read only when `anchor` is set.
        public var penOrigin: Float

        public init(
            file: String,
            key: [UInt8],
            x: Float,
            y: Float,
            width: Float,
            height: Float,
            anchor: Anchor? = nil,
            penOrigin: Float = 0
        ) {
            self.file = file
            self.key = key
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.anchor = anchor
            self.penOrigin = penOrigin
        }
    }

    /// The page's author, author index 1 of its identifier table. A
    /// document's `.content` spells the same UUID.
    public var author: UUID
    /// The author the formatting marks are written under, when the text
    /// carries any.
    ///
    /// A page with a bold or an italic stretch names a second author: on a
    /// tablet's page those marks are another session's edits, and their author
    /// index has to resolve in the table. What the value *is* decides nothing
    /// that is drawn — only that the index resolves.
    ///
    /// `nil` derives one from `author`, and derives it the same way every
    /// time, so the same draft writes the same bytes on every call. Set this
    /// where the caller has a real second identity to name.
    public var marksAuthor: UUID?
    public var sheet: Sheet
    public var column: Column
    public var paragraphs: [Paragraph]
    /// Strokes hung on nothing, in the sheet's own coordinates.
    public var strokes: [Stroke]
    /// Strokes hung on the text.
    public var marks: [Mark]
    /// Pictures placed on the page. They stand at the end of the drawing
    /// chain, over the strokes — where a freshly inserted image stands on a
    /// page the tablet wrote.
    public var images: [Image]

    public init(
        author: UUID,
        sheet: Sheet,
        column: Column,
        paragraphs: [Paragraph],
        strokes: [Stroke] = [],
        marks: [Mark] = [],
        images: [Image] = [],
        marksAuthor: UUID? = nil
    ) {
        self.author = author
        self.marksAuthor = marksAuthor
        self.sheet = sheet
        self.column = column
        self.paragraphs = paragraphs
        self.strokes = strokes
        self.marks = marks
        self.images = images
    }
}
