// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Testing
@testable import RMLines

// The widest column that stands on a sheet with a margin. The rule is not
// "no wider than the sheet", and the difference matters on exactly one device:
// a Move's sheet is 954 units and the medium column is 936, which fits with
// nine units to spare on each side — a page of text running into both edges.
// The share of the sheet is the whole of the rule, and a test is what keeps
// somebody from simplifying it back to a comparison.

@Test("The widest column is the widest that still leaves a margin")
func theColumnLeavesAShareOfTheSheet() {
    // reMarkable Paper Pro Move: only the narrow column has a margin here.
    #expect(TextColumn.widest(fittingSheetWidth: 954) == .narrow)
    // reMarkable 2 — the tablet's own pairing: wide is 1152 of 1404.
    #expect(TextColumn.widest(fittingSheetWidth: 1404) == .wide)
    // Paper Pro, wider still.
    #expect(TextColumn.widest(fittingSheetWidth: 1620) == .wide)
    // A sheet between the two: medium has a margin, wide does not.
    #expect(TextColumn.widest(fittingSheetWidth: 1200) == .medium)
    // Narrower than anything, and still an answer rather than a crash.
    #expect(TextColumn.widest(fittingSheetWidth: 1) == .narrow)
    #expect(TextColumn.widest(fittingSheetWidth: 0) == .narrow)
}

@Test("The width and the setting of a column travel as one pair")
func widthsAndSettingsAgree() {
    #expect(TextColumn.narrow.width == 740)
    #expect(TextColumn.medium.width == 936)
    #expect(TextColumn.wide.width == 1152)
    #expect(TextColumn.narrow.setting == 0)
    #expect(TextColumn.medium.setting == 1)
    #expect(TextColumn.wide.setting == 2)
    // The cases are ordered by width, which is what `widest` leans on.
    #expect(TextColumn.allCases.map(\.width) == [740, 936, 1152])
}

@Test("A draft column built from a TextColumn cannot mismatch its setting")
func aDraftColumnTakesBothNumbersAtOnce() {
    for column in TextColumn.allCases {
        let drafted = RMPageDraft.Column(column)
        #expect(drafted.width == column.width)
        #expect(drafted.setting == column.setting)
    }
}
