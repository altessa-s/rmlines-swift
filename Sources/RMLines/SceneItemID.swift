// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// The identifier of one item of a page's scene: a stroke, or a highlight
/// over the text of an imported PDF.
///
/// What the page itself calls the item — the author of the edit and its
/// counter — and so the one handle that still names the same item after the
/// page has been read, measured and put away: an edit made later
/// (`RMEditor`) finds the item by it, and by nothing about its looks.
///
/// Spelled `author:counter` as a string, for a consumer that has to carry
/// it without knowing this type.
public struct SceneItemID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let author: UInt8
    public let counter: UInt64

    public init(author: UInt8, counter: UInt64) {
        self.author = author
        self.counter = counter
    }

    /// The identifier out of its `author:counter` spelling; `nil` for
    /// anything else.
    public init?(_ string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let author = UInt8(parts[0]),
              let counter = UInt64(parts[1])
        else { return nil }
        self.init(author: author, counter: counter)
    }

    public var description: String { "\(author):\(counter)" }

    init(_ id: CrdtID) {
        self.init(author: id.author, counter: id.counter)
    }
}
