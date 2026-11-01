// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// The whole style record of a paragraph, not merely its first field.
///
/// Two paragraphs both carrying `tag 1 = 3` are drawn by the tablet in
/// different sizes, and the only thing telling them apart is whether the
/// record goes on:
///
/// ```
///    {1: 2}              heading 1          size 64
///    {1: 3, 2: 2, 3: 3}  heading 2          size 46
///    {1: 3}              heading 3          size 36
/// ```
///
/// What `tag 2` and `tag 3` mean apart is unknown, and taking them apart is
/// not needed: it is enough to tell the sets of
/// fields from one another.
public struct ParagraphFormat: Sendable, Hashable {
    /// `tag 1` as it stands in the file, known to us or not.
    public let raw: UInt8
    /// `tag 2` and `tag 3`, as the record carries them.
    public let second: UInt8?
    public let third: UInt32?

    /// The kind of paragraph, when the value is one we know. A record with a
    /// value we do not know is kept rather than dropped: dropping it loses the
    /// paragraph's own indent along with the marker, and the number itself is
    /// what says which value to look into next.
    public var style: ParagraphStyle? { ParagraphStyle(rawValue: raw) }

    /// Whether the record carried anything past `tag 1`.
    public var hasFurtherFields: Bool { second != nil || third != nil }

    /// Which level of heading the paragraph is, when it is one.
    ///
    /// The tablet has three. The first has its own `tag 1` value; the second
    /// and the third share the value `3` and are told apart by the
    /// `tag 2`/`tag 3` pair, present on the second and absent on the third.
    public var headingLevel: Int? {
        switch style {
        case .heading: 1
        case .subheading: hasFurtherFields ? 2 : 3
        default: nil
        }
    }

    /// How deep an item of a list is nested, counting from one.
    ///
    /// The first level carries no `tag 3`, or — a checkbox item — one at
    /// depth nought with state bits above it; a nested one packs
    /// the family into the high half of the byte and the depth into the low
    /// half:
    ///
    /// ```
    ///    bullet         0x01  second level     0x02  third
    ///    checkbox       0x11  second level     0x12  third
    ///    numbered       0x21  second level     0x22  third
    /// ```
    ///
    /// Three levels and no more: the tablet does not let a list nest deeper, so
    /// the low half of the byte never goes past two. Read as a level all the
    /// same — the arithmetic is shorter than a table of six values, and it
    /// keeps the bullet, whose family half is nought, from looking like a
    /// special case.
    public var level: Int {
        guard style?.isListItem == true, let third else { return 1 }
        return Int(third & 0x0F) + 1
    }

    /// Whether the item's checkbox is ticked.
    ///
    /// The style says so for an item with nothing nested under it (`7`, `9`).
    /// The high half of `tag 3` says so for every item: bit 8 is the tick —
    /// and it is the only place an item with nested items keeps it, because
    /// such an item stays style `6` whatever its state (`0x310` is drawn
    /// ticked, `0x210` not).
    public var isTicked: Bool {
        if style == .checkboxChecked || style == .checkboxCheckedNested { return true }
        return style?.listFamily == .checkbox && (third ?? 0) & Self.tickedBit != 0
    }

    /// Whether any item nested under this one is ticked — bit 9 of `tag 3`.
    /// It stands on a parent with all of its nested items
    /// ticked (`0x310`, beside bit 8) and on one with some ticked (`0x210`),
    /// while a parent with none ticked carries no `tag 3` at all.
    public var hasTickedNestedItems: Bool {
        style?.listFamily == .checkbox && (third ?? 0) & Self.tickedNestedBit != 0
    }

    private static let tickedBit: UInt32 = 0x100
    private static let tickedNestedBit: UInt32 = 0x200

    public init(style: ParagraphStyle, second: UInt8? = nil, third: UInt32? = nil) {
        self.init(raw: style.rawValue, second: second, third: third)
    }

    public init(raw: UInt8, second: UInt8? = nil, third: UInt32? = nil) {
        self.raw = raw
        self.second = second
        self.third = third
    }

    /// The same format written the short way, for tests and fixtures: the pair
    /// (2, 3) is what an emphasised paragraph carries.
    public init(style: ParagraphStyle, hasFurtherFields: Bool) {
        self.init(
            style: style,
            second: hasFurtherFields ? 2 : nil,
            third: hasFurtherFields ? 3 : nil
        )
    }
}
