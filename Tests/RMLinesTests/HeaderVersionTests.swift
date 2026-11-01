// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMLines
import Testing

// The header, and the difference the application above this package rests on:
// a page of an older generation is refused *by its version*, and bytes of no
// known shape are refused as a format nobody can name. What a document does
// with either — keeping the page's place, filing it in the journal once —
// belongs to the layer that holds documents; here it is only the reading.

@Test("The version is read out of the header rather than matched against a list")
func headerCarriesItsVersion() {
    #expect(RMParser.version(inHeader: "reMarkable .lines file, version=3          ") == 3)
    #expect(RMParser.version(inHeader: "reMarkable .lines file, version=5          ") == 5)
    #expect(RMParser.version(inHeader: RMParser.header) == 6)
    // A generation nobody has written down yet has to arrive as a number too:
    // that is the difference between "an older format" and "we cannot tell".
    #expect(RMParser.version(inHeader: "reMarkable .lines file, version=7          ") == 7)
}

@Test("Bytes that are not a page header carry no version")
func aStrangeHeaderHasNoVersion() {
    #expect(RMParser.version(inHeader: "reMarkable lines with selections and layers") == nil)
    #expect(RMParser.version(inHeader: "reMarkable .lines file, version=           ") == nil)
    #expect(RMParser.version(inHeader: "%PDF-1.4") == nil)
}

@Test("An older page is refused by its version, not as an unrecognisable file")
func olderPagesAreRefusedByVersion() {
    for version in [3, 5] {
        #expect(throws: ParseError.unsupportedVersion(version)) {
            try RMParser.parsePage(oldPage(version: version))
        }
    }
}

@Test("A header of no known shape stays an unrecognised format")
func strangeBytesStayUnrecognised() {
    // The distinction is the point: the app tells the user "an older format"
    // only where it has read a version. Anything else is a file we cannot
    // name, and saying otherwise would be a guess in front of the user.
    #expect(throws: ParseError.unsupportedFormat("reMarkable lines with selections")) {
        try RMParser.parsePage(Data("reMarkable lines with selections and layers ".utf8))
    }
}

// MARK: - Fixtures

/// A page of an older generation. Its header is all we need and all we can
/// honestly write: what follows it is a flat container this project has never
/// parsed, and inventing one would be a fixture testing itself.
private func oldPage(version: Int) -> Data {
    Data("\(RMParser.headerPrefix)\(version)          ".utf8)
}
