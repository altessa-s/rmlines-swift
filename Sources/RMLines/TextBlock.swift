// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// Typed text on a page.
///
/// The tablet lets one type as well as write, and such a page can carry no
/// strokes at all — only this. A renderer that ignores it shows a typed
/// notebook as blank.
public struct TextBlock: Sendable, Hashable {
    /// Where the text begins, in the page's own coordinates: x counted from
    /// the middle of the sheet, y growing downwards.
    public let originX: Double
    public let originY: Double
    /// The lines as they read, already in document order.
    public let lines: [String]
    /// How a paragraph is presented, by its index in `lines`. Absent means
    /// plain text — most paragraphs are.
    public let formats: [Int: ParagraphFormat]
    /// The bold and italic stretches of a line, by its index in `lines`.
    public let faces: [Int: [FaceRun]]
    /// How wide the column of text is, in page units, when the file declares
    /// it. The tablet writes it twice — as this field and through the origin
    /// — and this one is the better of the two: deriving the width from the
    /// origin holds only while the column is centred on the sheet.
    public let columnWidth: Double?

    public init(
        originX: Double,
        originY: Double,
        lines: [String],
        formats: [Int: ParagraphFormat] = [:],
        faces: [Int: [FaceRun]] = [:],
        columnWidth: Double? = nil
    ) {
        self.originX = originX
        self.originY = originY
        self.lines = lines
        self.formats = formats
        self.faces = faces
        self.columnWidth = columnWidth
    }
}
