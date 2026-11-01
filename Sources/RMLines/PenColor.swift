// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// A stroke's colour. The values are indexes into the tablet's palette.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum PenColor: Int, Sendable, CaseIterable {
    case black = 0
    case gray = 1
    case white = 2
    case yellow = 3
    case green = 4
    case pink = 5
    case blue = 6
    case red = 7
    case grayOverlap = 8
    case highlight = 9
    case green2 = 10
    case cyan = 11
    case magenta = 12
    case yellow2 = 13
    /// The highlighter's blue and orange under indexes of their own. The
    /// tablet's palette names them (`HighlighterBlue = 0xFFBEEAFE`,
    /// `HighlighterOrange = 0xFFFFC38C`), and the format admits them in
    /// `tag 2` with no `argb` beside it; pages usually spell the same two
    /// colours as `9` plus `argb`. Index 16 (`LastColor`) closes the
    /// enumeration and is no colour at all.
    case highlighterBlue = 14
    case highlighterOrange = 15

    // How an index is coloured belongs to the renderer: the tablet keeps
    // three palettes over one set of indexes (pen, highlighter, text
    // highlight), and each has to be taken from the tablet's own output
    // rather than guessed.
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
extension PenColor {
    public static func == (a: PenColor, b: PenColor) -> Bool {
        a.rawValue == b.rawValue
    }
}
