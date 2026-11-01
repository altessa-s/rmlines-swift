// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// The scales the `.rm` format itself is written in: what the numbers in the
/// file mean before anything is drawn.
///
/// Apart from the drawing on purpose, and the line between them is not where
/// the numbers came from but what they are about. These four say how to
/// *read* a stroke — a width in file units divided by four is a width in page
/// units, a translucent stroke with nothing else said is a quarter opaque.
/// Pens, palettes, type metrics and templates are about *drawing* and belong
/// to the renderer. Reading needs none of them.
public enum InkScale {
    /// What the width in the file is divided by to become a width on the
    /// page. The ratio is exact: on the two tools the tablet strokes rather
    /// than fills, the width on the page is the file's width over four.
    public static let unitsPerRawWidth = 4.0

    /// Thin strokes have to stay visible in print; the format's own smallest
    /// is 1.5 units, so this never fires on a width the tablet wrote.
    public static let minimumStrokeWidth = 0.7

    /// A guard against a number that is not a width at all — a corrupt file,
    /// a NaN out of a float32. It sits far above anything the tablet writes:
    /// the widest is 128 raw, which is 32 units.
    public static let maximumStrokeWidth = 200.0

    /// How opaque a translucent stroke is when the file does not say: byte
    /// `0x40` of the shader's own `argb`, the opacity the tablet draws it
    /// with.
    public static let faintAlpha = 0.25098
}
