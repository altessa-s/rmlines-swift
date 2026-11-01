// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// A stretch of a line set in a face of its own.
///
/// Bold and italic are not properties of a paragraph: they are marked up on
/// the characters, by a pair of empty text records fencing the stretch off.
/// The range counts characters of the line it belongs to, from nought.
public struct FaceRun: Sendable, Hashable {
    public let range: Range<Int>
    public let bold: Bool
    public let italic: Bool

    public init(range: Range<Int>, bold: Bool, italic: Bool) {
        self.range = range
        self.bold = bold
        self.italic = italic
    }
}
