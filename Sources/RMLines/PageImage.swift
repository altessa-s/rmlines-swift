// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// An image placed on the page — an insertion or an Image Capture.
///
/// The pixels do not live in the `.rm`: the file names an attachment that
/// lies in the document's index one level deeper than a page —
/// `<document>/<page>/<uuid>.png` — and has to be fetched as a blob of its
/// own.
public struct PageImage: Sendable, Hashable {
    /// One corner of the quad: where it stands on the page and which point
    /// of the texture it pins there. The texture coordinates run 0…1, so the
    /// quad can crop the image as well as move and scale it.
    public struct Vertex: Sendable, Hashable {
        public let x: Double
        public let y: Double
        public let u: Double
        public let v: Double

        public init(x: Double, y: Double, u: Double, v: Double) {
            self.x = x
            self.y = y
            self.u = u
            self.v = v
        }
    }

    /// The attachment's file name in the document's index, e.g. "<uuid>.png".
    public let file: String
    /// The four corners, in the order the file gives them — the indexes
    /// `0 1 2 2 3 0` make a quad of them.
    public let vertices: [Vertex]
    /// How many strokes of the page are drawn before this image. The scene
    /// is one sequence and the z-order is the sequence: an image can lie
    /// over some strokes and under others.
    public let strokesBefore: Int
    /// Where in the typed text the image is fastened, when it is. An image
    /// inserted into the text flow hangs on an anchored group exactly the way
    /// handwriting does, and its vertices are then counted from the pen at
    /// that anchor rather than from the sheet: the tablet tombstones the
    /// loose item and re-hangs the image on a group carrying the anchor
    /// fields of `0x02`.
    public let anchor: TextAnchor?

    public init(file: String, vertices: [Vertex], strokesBefore: Int, anchor: TextAnchor? = nil) {
        self.file = file
        self.vertices = vertices
        self.strokesBefore = strokesBefore
        self.anchor = anchor
    }
}
