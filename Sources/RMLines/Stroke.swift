// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// A single pen stroke.
public struct Stroke: Sendable, Hashable {
    public let tool: PenTool?
    public let color: PenColor
    public let thicknessScale: Double
    public let points: [StrokePoint]

    /// The explicit colour from the file, `0xAARRGGBB`, when the file
    /// carries one.
    ///
    /// Where it is set it wins over `color`: it is the only record of a
    /// colour the palette does not name.
    public let argb: UInt32?

    /// The place in the typed text this stroke's coordinates are counted from,
    /// when they are counted from the text rather than from the sheet.
    ///
    /// A place and not a shift, and that is the point: turning one into the
    /// other takes a font and a column width, and both belong to drawing —
    /// see `TextAnchor`.
    public let anchor: TextAnchor?

    /// What the page calls this stroke: the handle an edit finds it by.
    /// `nil` for a stroke that was never read out of a page.
    public let id: SceneItemID?

    /// The stroke this one is a piece of, when the eraser cut it (`tag 9`).
    ///
    /// Only the eraser sets it, and only on a shader: every piece left of a
    /// shader stroke cut in two carries the original's id — or, when that
    /// was a piece already, the original's own `sourceId` — so the pieces of
    /// one stroke name one source however often it was cut. The tablet draws
    /// neighbouring pieces of one source as one stroke, so the translucent
    /// shader does not deepen where they meet. `nil` for every other
    /// stroke.
    public let sourceId: SceneItemID?

    public init(
        tool: PenTool?,
        color: PenColor,
        thicknessScale: Double,
        points: [StrokePoint],
        argb: UInt32? = nil,
        anchor: TextAnchor? = nil,
        id: SceneItemID? = nil,
        sourceId: SceneItemID? = nil
    ) {
        self.tool = tool
        self.color = color
        self.thicknessScale = thicknessScale
        self.points = points
        self.argb = argb
        self.anchor = anchor
        self.id = id
        self.sourceId = sourceId
    }

    /// The same stroke, counted from a place in the typed text.
    public func anchored(to place: TextAnchor) -> Stroke {
        Stroke(
            tool: tool,
            color: color,
            thicknessScale: thicknessScale,
            points: points,
            argb: argb,
            anchor: place,
            id: id,
            sourceId: sourceId
        )
    }
}
