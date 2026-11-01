// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics

/// A highlight over the text of an imported PDF.
///
/// Not a stroke, and that is the point of the type. Running the marker over
/// the text of a PDF writes a *glyph range*: the text, its place in the text
/// layer, and ready-made rectangles. The stroke recorded beside it is
/// degenerate — two points at one and the same x, for example, while
/// the band the tablet draws runs hundreds of points wide. Draw the stroke and
/// nothing appears; draw these rectangles and it does.
public struct Highlight: Sendable, Hashable {
    /// The bands, in the page's own coordinates — the same space the strokes
    /// live in.
    public let rectangles: [CGRect]
    public let color: PenColor
    /// The explicit colour, when the file carries one, as on a stroke: where
    /// it is set it wins over `color`.
    public let argb: UInt32?
    /// The words under the marker, as the tablet copied them out of the text
    /// layer. Not needed to draw — the page underneath carries them — but
    /// the only way to say what was highlighted without reading the PDF
    /// back. `nil` when the block carries no text.
    public let text: String?
    /// What the page calls this highlight: the handle an edit finds it by.
    /// `nil` for a highlight that was never read out of a page.
    public let id: SceneItemID?

    public init(
        rectangles: [CGRect],
        color: PenColor,
        argb: UInt32? = nil,
        text: String? = nil,
        id: SceneItemID? = nil
    ) {
        self.rectangles = rectangles
        self.color = color
        self.argb = argb
        self.text = text
        self.id = id
    }
}
