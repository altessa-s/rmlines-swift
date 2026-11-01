// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

// The byte half of writing a page: little-endian scalars, varuints, tags,
// identifiers and tagged subblocks. The mirror of `RMBinaryReader`, and
// internal like it — the public door is `RMWriter`.
//
// Every byte here is one the tablet itself writes, and nothing below may
// change one of them unless the tablet is shown to accept the change.

/// An identifier inside a page: the author who minted it and their
/// counter.
typealias WriterID = (author: UInt8, counter: UInt64)

struct RMBinaryWriter {
    private(set) var bytes: [UInt8] = []

    mutating func append(_ byte: UInt8) { bytes.append(byte) }

    mutating func append(uint16 value: UInt16) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8(value >> 8))
    }

    mutating func append(uint32 value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }

    mutating func append(float value: Float) {
        append(uint32: value.bitPattern)
    }

    mutating func append(double value: Double) {
        let pattern = value.bitPattern
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8((pattern >> UInt64(shift)) & 0xFF))
        }
    }

    mutating func append(varuint value: UInt64) {
        var rest = value
        repeat {
            var byte = UInt8(rest & 0x7F)
            rest >>= 7
            if rest != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while rest != 0
    }

    mutating func appendTag(index: Int, type: UInt8) {
        append(varuint: UInt64(index) << 4 | UInt64(type))
    }

    mutating func appendID(index: Int, _ value: WriterID) {
        appendTag(index: index, type: 0xF)
        append(value.author)
        append(varuint: value.counter)
    }

    mutating func appendBareID(_ value: WriterID) {
        append(value.author)
        append(varuint: value.counter)
    }

    /// A last-writer-wins field: who set the value, then the value.
    ///
    /// A typed page carries six of them, in three shapes — a byte, a float, a
    /// subblock — and only the shape of the value differs. Written out each
    /// time, the stamp would be the field easiest to leave at the wrong id.
    mutating func appendStamped(index: Int, by stamp: WriterID, u8 value: UInt8) {
        appendStamped(index: index, by: stamp) {
            $0.appendTag(index: 2, type: 0x1)
            $0.append(value)
        }
    }

    mutating func appendStamped(index: Int, by stamp: WriterID, float value: Float) {
        appendStamped(index: index, by: stamp) {
            $0.appendTag(index: 2, type: 0x4)
            $0.append(float: value)
        }
    }

    mutating func appendStamped(index: Int, by stamp: WriterID, block value: [UInt8]) {
        appendStamped(index: index, by: stamp) { $0.appendBlock(index: 2, value) }
    }

    private mutating func appendStamped(
        index: Int,
        by stamp: WriterID,
        _ value: (inout RMBinaryWriter) -> Void
    ) {
        var body = RMBinaryWriter()
        body.appendID(index: 1, stamp)
        value(&body)
        appendBlock(index: index, body.bytes)
    }

    /// A string as the format spells one: the length in **bytes**, the
    /// encoding marker, then the bytes.
    ///
    /// The mirror of `RMBinaryReader.readString(upTo:)`, and in one place for
    /// the same reason: the length is a byte count, not a count of
    /// characters, and outside ASCII the two are different numbers. Four
    /// places write a string — a paragraph, a face mark, a node's name, an
    /// attachment's file name — and four copies would be four chances for one
    /// of them to count the wrong thing.
    mutating func append(string value: String) {
        let utf8 = Array(value.utf8)
        append(varuint: UInt64(utf8.count))
        append(1)                                         // encoding: UTF-8
        append(contentsOf: utf8)
    }

    /// A tagged subblock: the tag, the length of what follows, and the bytes.
    mutating func appendBlock(index: Int, _ body: [UInt8]) {
        appendTag(index: index, type: 0xC)
        append(uint32: UInt32(body.count))
        append(contentsOf: body)
    }

    mutating func append(contentsOf other: [UInt8]) {
        bytes.append(contentsOf: other)
    }
}

/// A top-level block: the 8-byte header, then the payload. The versions
/// default to what the tablet writes for most of its blocks; a block that
/// carries other numbers says so at the call.
func writerBlock(
    _ type: UInt8,
    minVersion: UInt8 = 1,
    currentVersion: UInt8 = 1,
    _ payload: [UInt8]
) -> [UInt8] {
    var out = RMBinaryWriter()
    out.append(uint32: UInt32(payload.count))
    out.append(0)
    out.append(minVersion)
    out.append(currentVersion)
    out.append(type)
    out.append(contentsOf: payload)
    return out.bytes
}
