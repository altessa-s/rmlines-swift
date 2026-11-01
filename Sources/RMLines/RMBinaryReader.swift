// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// The errors of parsing a notebook page.
///
/// Named for what it is. Not a rendering error, and not a case about a PDF
/// context this package has never opened: those belong to the drawing, and
/// the drawing lives a package away. What is thrown here is a file that would
/// not read, and nothing else.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum ParseError: Error, Sendable, Equatable {
    case unexpectedEndOfData
    /// The bytes do not begin the way a page does at all. The first of them
    /// travel along, because a header nobody recognises is the one thing
    /// worth looking at.
    case unsupportedFormat(String)
    /// A page of the format all right, written to a version this reader does
    /// not parse — the version is the number in its header.
    ///
    /// Told apart from `unsupportedFormat` because the answers differ. This
    /// one is a known shape of file, and the honest answer is to leave the
    /// page out and say which format it is in; the other is bytes we cannot
    /// name, and lumping the two together would have the app tell a user
    /// about "an older format" it never read a version out of.
    case unsupportedVersion(Int)
    case malformedPage(String)
}

/// Low-level reading of the `.rm` format: little-endian numbers, varuints,
/// tags and subblocks. A value type, so that the read position does not drift
/// apart between calls.
struct RMBinaryReader {
    /// The format's tag types.
    enum TagType: UInt8 {
        case id = 0xF
        case length4 = 0xC
        case byte8 = 0x8
        case byte4 = 0x4
        case byte1 = 0x1
    }

    /// The bytes are read in place rather than copied into an array first:
    /// a notebook is parsed page by page in a loop, and a copy would be a
    /// per-page allocation for nothing.
    private let data: Data
    /// A `Data` slice keeps its parent's indices, so every read below goes
    /// through this base — a slice must parse the same as a fresh copy.
    private let base: Data.Index
    private(set) var offset: Int

    var count: Int { data.count }
    var remaining: Int { data.count - offset }

    init(_ data: Data) {
        self.data = data
        base = data.startIndex
        offset = 0
    }

    mutating func seek(to position: Int) throws {
        guard position >= 0, position <= data.count else { throw ParseError.unexpectedEndOfData }
        offset = position
    }

    mutating func readBytes(_ length: Int) throws -> [UInt8] {
        let start = try advance(by: length)
        return [UInt8](data[start..<(start + length)])
    }

    /// Claims `length` bytes and answers where they begin in `data`, so that
    /// a number is read out of the bytes where they lie: a point costs four
    /// to six of these reads, and an array per read would be an allocation
    /// per coordinate of every stroke on the page.
    private mutating func advance(by length: Int) throws -> Data.Index {
        guard length >= 0, offset <= data.count - length else {
            throw ParseError.unexpectedEndOfData
        }
        defer { offset += length }
        return base + offset
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw ParseError.unexpectedEndOfData }
        defer { offset += 1 }
        return data[base + offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let start = try advance(by: 2)
        return UInt16(data[start]) | UInt16(data[start + 1]) << 8
    }

    mutating func readUInt32() throws -> UInt32 {
        let start = try advance(by: 4)
        return UInt32(data[start])
            | UInt32(data[start + 1]) << 8
            | UInt32(data[start + 2]) << 16
            | UInt32(data[start + 3]) << 24
    }

    mutating func readFloat32() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    mutating func readFloat64() throws -> Double {
        let start = try advance(by: 8)
        var pattern: UInt64 = 0
        for index in 0..<8 {
            pattern |= UInt64(data[start + index]) << (8 * UInt64(index))
        }
        return Double(bitPattern: pattern)
    }

    /// A variable-length integer: 7 bits per byte, the top bit meaning "more
    /// to come".
    mutating func readVarUInt() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try readUInt8()
            // The tenth byte has one bit's worth of room left. Swift's shift
            // drops whatever does not fit without a word, so a number too wide
            // for the type would arrive as a different number — refused
            // instead of quietly rewritten.
            if shift == 63, byte & 0x7E != 0 {
                throw ParseError.malformedPage("varuint wider than 64 bits")
            }
            result |= UInt64(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 { break }
            guard shift < 64 else { throw ParseError.malformedPage("varuint too long") }
        }
        return result
    }

    /// A count the file declares, as an `Int`.
    ///
    /// A varuint is 64 bits wide and a count is an index into memory. Written
    /// `Int(...)`, a value above `Int.max` is a trap rather than an error —
    /// and a trap on a corrupted blob takes the process down past every
    /// per-block recovery the parser has.
    mutating func readCount() throws -> Int {
        let value = try readVarUInt()
        guard let count = Int(exactly: value) else {
            throw ParseError.malformedPage("count \(value) is out of range")
        }
        return count
    }

    /// A string as the format spells one: a length in **bytes**, a one-byte
    /// encoding marker, then the bytes themselves.
    ///
    /// The length is a byte count and not a count of characters, whatever the
    /// field is called elsewhere: outside ASCII the two are different numbers,
    /// and the writer spells it `utf8.count` for the same reason. In one place
    /// because it is read in three — the typed text, a highlight's words, an
    /// attachment's file name — and three copies of this are three chances to
    /// get that wrong in one of them.
    ///
    /// `end` bounds the read. The length in front of the bytes is the file's
    /// word and not a measurement, so it is clamped to what the field it sits
    /// in can actually hold: a short or padded field then cannot shift
    /// whatever is read after it. Nothing left to read is an empty string and
    /// not an error — an empty record is how the format fences a bold stretch.
    ///
    /// The position is left where the bytes ended. Callers that own a field
    /// seek to its end afterwards.
    mutating func readString(upTo end: Int) throws -> String {
        guard offset < end else { return "" }
        let byteCount = try readCount()
        guard offset < end else { return "" }
        _ = try readUInt8()                      // encoding marker
        let available = max(0, min(byteCount, end - offset))
        return String(decoding: try readBytes(available), as: UTF8.self)
    }

    /// A tag: a varuint whose upper bits are the field index and lower bits
    /// the value type.
    mutating func readTag() throws -> (index: Int, type: UInt8) {
        let raw = try readVarUInt()
        return (index: Int(raw >> 4), type: UInt8(raw & 0xF))
    }

    /// Check that the expected tag comes next without moving the position on
    /// a mismatch: the format has optional fields.
    ///
    /// A question, not a read: a tag that is not there, or bytes that are not
    /// a tag at all, are both answered `false` with the position restored.
    /// Nothing about that is an error, so this does not throw.
    mutating func matchTag(index: Int, type: TagType) -> Bool {
        let saved = offset
        guard remaining > 0 else { return false }
        if let tag = try? readTag(), tag.index == index, tag.type == type.rawValue {
            return true
        }
        offset = saved
        return false
    }

    /// Whether a scene item's value follows its preamble inside the block
    /// that ends at `end`.
    ///
    /// Asked with the block's end, not of the stream: a tombstone's block
    /// ends right behind its preamble, and the byte after that is the next
    /// block's length. A length of 108 spells `0x6C` — the very tag of a
    /// value — and a tombstone would be read as a living item with
    /// the next block's header for its value.
    ///
    /// The whole tag has to lie inside the block, not only its first byte:
    /// a tag is a varuint, and `0xEC` closing a block with the next one's
    /// `0x00` behind it reads as the same `0x6C`.
    mutating func matchValue(before end: Int) -> Bool {
        let saved = offset
        guard offset < end, matchTag(index: 6, type: .length4) else { return false }
        guard offset <= end else {
            offset = saved
            return false
        }
        return true
    }

    mutating func expectTag(index: Int, type: TagType) throws {
        guard matchTag(index: index, type: type) else {
            throw ParseError.malformedPage("expected tag \(index)/\(type)")
        }
    }

    /// A CRDT identifier: a byte plus a varuint. We have no use for the
    /// value, but skipping it correctly is essential — otherwise the whole
    /// parse slides out of place.
    mutating func skipCrdtID(index: Int) throws {
        _ = try readCrdtID(index: index)
    }

    /// The same identifier, but with its value: it is what ties a stroke to a
    /// node of the tree, and a node to an anchor in the text.
    mutating func readCrdtID(index: Int) throws -> CrdtID {
        try expectTag(index: index, type: .id)
        return try readBareCrdtID()
    }

    /// An identifier written with no tag in front of it. The list of
    /// paragraph styles is keyed that way: the key stands bare, and only the
    /// fields after it carry tags.
    mutating func readBareCrdtID() throws -> CrdtID {
        let author = try readUInt8()
        let counter = try readVarUInt()
        return CrdtID(author: author, counter: counter)
    }
}

/// The identifier of a scene element: the author of the edit and its counter.
struct CrdtID: Hashable, Sendable {
    let author: UInt8
    let counter: UInt64
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
extension ParseError {
    public static func == (a: ParseError, b: ParseError) -> Bool {
        switch (a, b) {
        case (.unexpectedEndOfData, .unexpectedEndOfData): true
        case let (.unsupportedFormat(x), .unsupportedFormat(y)): x == y
        case let (.unsupportedVersion(x), .unsupportedVersion(y)): x == y
        case let (.malformedPage(x), .malformedPage(y)): x == y
        default: false
        }
    }
}
