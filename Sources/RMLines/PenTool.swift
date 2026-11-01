// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// The tool a stroke was made with. The numbers come from the tablet's
/// format.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum PenTool: Int, Sendable, CaseIterable {
    case paintbrush1 = 0
    case pencil1 = 1
    case ballpoint1 = 2
    case marker1 = 3
    case fineliner1 = 4
    case highlighter1 = 5
    case eraser = 6
    case mechanicalPencil1 = 7
    case eraserArea = 8
    case paintbrush2 = 12
    case mechanicalPencil2 = 13
    case pencil2 = 14
    case ballpoint2 = 15
    case marker2 = 16
    case fineliner2 = 17
    case highlighter2 = 18
    case caligraphy = 21
    case shader = 23

    // How a tool draws — how it blends over what is already drawn, and
    // whether it is stroked instead of filled — belongs to the renderer; the
    // scales for reading are in `InkScale`. Both follow the tablet's own
    // output, not inventions.

    /// The eraser must not be drawn. Its strokes look like ordinary lines,
    /// and drawing them covers the page in lines exactly where the user was
    /// erasing.
    public var isEraser: Bool {
        self == .eraser || self == .eraserArea
    }

    /// The marker, whose band says something about what lies under it.
    ///
    /// Over the text of an imported PDF the tablet does not use this tool at
    /// all: it writes a glyph range with the words spelled out (`Highlight`).
    /// Over handwriting, and over a scan with no text layer to snap to, it
    /// writes an ordinary stroke — so a band of this tool is the only record
    /// that anything was marked there.
    public var isHighlighter: Bool {
        self == .highlighter1 || self == .highlighter2
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
extension PenTool {
    public static func == (a: PenTool, b: PenTool) -> Bool {
        a.rawValue == b.rawValue
    }
}
