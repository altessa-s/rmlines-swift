// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import Testing
@testable import RMLines

// A count in the file is a declaration, not a measurement. Believed, it either
// traps the process — a trap goes past every `try?` in the parser and takes
// the host with it — or reserves memory nobody has. These two reach into the reader directly
// because that is where the arithmetic is; what a whole page declaring a
// number it does not carry does is `RMParser`'s, and is tested through it.

@Test("A count too large for the machine is an error, not a trap")
func rejectsCountOutOfRange() throws {
    // `UInt64.max` is a valid varuint and not a valid `Int`. Written
    // `Int(...)`, that conversion is a crash rather than a throw.
    var reader = RMBinaryReader(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]))
    #expect(try reader.readVarUInt() == .max, "the ten-byte form is a legal varuint")

    var again = RMBinaryReader(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]))
    #expect(throws: ParseError.self) { try again.readCount() }
}

@Test("A varuint wider than the type is refused, not silently narrowed")
func rejectsOverWideVarUInt() {
    // The tenth byte has one bit's worth of room. Shifting the rest
    // out in silence would let a number the format cannot hold come back as another
    // number that it can — the worst way to be wrong.
    var reader = RMBinaryReader(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x03]))
    #expect(throws: ParseError.self) { try reader.readVarUInt() }
}
