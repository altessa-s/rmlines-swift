// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// How a paragraph of typed text is presented.
///
/// The numbers are the tablet's own. Anything unknown
/// is read as plain text rather than guessed at — a wrong marker is worse
/// than none.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum ParagraphStyle: UInt8, Sendable, Hashable {
    case basic = 0
    case plain = 1
    case heading = 2
    /// Headings of the second and the third level: the tablet has three,
    /// and `tag 1` covers the lower two. Which one it is, `tag 2` and
    /// `tag 3` say (`ParagraphFormat.headingLevel`).
    case subheading = 3
    case bullet = 4
    case bulletNested = 5
    case checkbox = 6
    case checkboxChecked = 7
    /// A ticked checkbox of a nested list — the ticked counterpart of
    /// `checkboxNested` (`CheckboxCheckedIndented`).
    case checkboxCheckedNested = 9
    /// The paragraph that holds an image in the flow of the text: one object
    /// replacement character between two newlines. How it is drawn is not
    /// known.
    case imageBlock = 12
    /// A numbered list. The number itself is nowhere in the file — the tablet
    /// counts the consecutive items and so do we.
    case numbered = 10

    /// An item of a list nested under another. The value says the family, and
    /// `tag 3` of the same record says how deep — see `ParagraphFormat.level`.
    /// The first level uses the values above and carries no `tag 3`, save a
    /// checkbox item's state (`ParagraphFormat.isTicked`).
    ///
    /// The bullet's nested value is `5`; reading that as a *filled* bullet on
    /// the strength of its name alone would be wrong. It is not a shape at
    /// all: the shape follows the level.
    case checkboxNested = 8
    case numberedNested = 11

    /// Which family of list the value belongs to, whatever its level.
    public var listFamily: ListFamily? {
        switch self {
        case .bullet, .bulletNested: .bullet
        case .checkbox, .checkboxChecked, .checkboxNested, .checkboxCheckedNested: .checkbox
        case .numbered, .numberedNested: .numbered
        default: nil
        }
    }

    /// Whether the paragraph is one of a list: those get a marker drawn in
    /// front of them and their text moved out of its way.
    public var isListItem: Bool {
        switch self {
        case .bullet, .bulletNested, .checkbox, .checkboxChecked, .numbered,
             .checkboxNested, .checkboxCheckedNested, .numberedNested: true
        default: false
        }
    }
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
extension ParagraphStyle {
    public static func == (a: ParagraphStyle, b: ParagraphStyle) -> Bool {
        a.rawValue == b.rawValue
    }
}
