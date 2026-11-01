// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// The width of the typed-text column — the setting the tablet offers
/// under the text tool, and one of exactly three values.
///
/// It reaches the file three times over: as the origin of the text box, as
/// the declared width of that box, and as `tag 9` of the scene block,
/// which stores the setting rather than the width. The three have to
/// agree — which is why the numbers live here, with the writer that spells
/// them, rather than with any one caller that builds a page from them.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum TextColumn: String, Sendable, CaseIterable {
    case narrow
    case medium
    case wide

    /// The width of the box in the file's own units. The column is centred
    /// on the sheet, so the origin is half of it to the left.
    public var width: Float {
        switch self {
        case .narrow: 740
        case .medium: 936
        case .wide: 1152
        }
    }

    /// `tag 9` of SceneInfo: which of the three the user chose.
    public var setting: UInt8 {
        switch self {
        case .narrow: 0
        case .medium: 1
        case .wide: 2
        }
    }

    /// The widest of the three that stands on a sheet **with a margin**: on a
    /// Move only the narrow one does.
    ///
    /// The margin is the whole of the rule, and without it the answer is
    /// wrong on exactly one device. A Move's sheet is 954 units and the medium
    /// column is 936: it "fits" with nine units to spare on each side, which
    /// is no margin at all — a page of text running into both edges. The
    /// tablet's own widest choice shows what it considers a margin: on a
    /// reMarkable 2, `wide` is 1152 of 1404, leaving 9% of the sheet on each
    /// side.
    ///
    /// So the column has to leave a share of the sheet rather than merely be
    /// no wider than it. The ceiling below is a hair looser than the tablet's
    /// own — it has to admit `wide` on a reMarkable 2, which is the shape the
    /// tablet itself writes — and it turns the Move down to `narrow`.
    public static func widest(fittingSheetWidth sheetWidth: Double) -> TextColumn {
        let usable = sheetWidth * textShareOfSheet
        return allCases.last { Double($0.width) <= usable } ?? .narrow
    }

    /// How much of the sheet's width typed text may claim. Set against the
    /// tablet's own pairing of column to device: 1152 / 1404 = 0.82 is what
    /// it does on a reMarkable 2, so 0.85 admits that and nothing wider.
    private static let textShareOfSheet = 0.85
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
extension TextColumn {
    public static func == (a: TextColumn, b: TextColumn) -> Bool {
        a.rawValue == b.rawValue
    }
}
