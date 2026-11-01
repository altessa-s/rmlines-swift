// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// Where in the typed text a stroke of handwriting is fastened.
///
/// The file fastens it to a **character**, and the tablet counts the stroke's
/// coordinates from the pen: x where that character ends, y on the baseline of
/// the visual line it stands on. For example, on a page whose body wraps
/// over four lines, the handwriting below the text counts from 504.23 and
/// 1298.5 — the baseline and the end of the **fourth** line, not of the
/// paragraph.
///
/// Which visual line a character falls on is a matter of the font and the
/// column width, so this stays a place in the text until drawing time, where
/// both are known.
public struct TextAnchor: Sendable, Hashable {
    /// The paragraph, by its index in `TextBlock.lines`.
    public let paragraph: Int
    /// How many of that paragraph's characters stand before the anchor,
    /// counted in **Unicode scalars** — the way the file numbers them, and the
    /// way both the parser and the layout count them. Not graphemes: on NFC
    /// Latin and Cyrillic the two agree, and on Arabic diacritics they do not,
    /// where a grapheme count would shift every anchor after the first mark.
    public let offset: Int
    /// The horizontal the file itself declares — `anchor_origin_x`, tag 10 of
    /// the tree node. Where the layout is computable it agrees with what the
    /// layout gives; where it is not — a caret on the boundary of two writing
    /// directions — it is the only right answer. The vertical stays computed:
    /// two renderings of one notebook, set in different fonts, share their x
    /// to a tenth of a unit and differ in y.
    public let originX: Double?

    public init(paragraph: Int, offset: Int, originX: Double? = nil) {
        self.paragraph = paragraph
        self.offset = offset
        self.originX = originX
    }
}
