// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Testing
@testable import RMLines

// The style record decoded. Three of the tablet's presentations cannot be
// told apart by `tag 1` alone, and the arithmetic that tells them apart is
// the kind that is right until somebody tidies it: a heading level read off
// the presence of two further fields, a nesting depth packed into half a
// byte. Written down here so that tidying it breaks a test rather than a
// page.

@Test("Heading 2 and heading 3 both carry tag 1 = 3 and are told apart by what follows")
func headingLevelsComeFromTheWholeRecord() {
    #expect(ParagraphFormat(style: .heading).headingLevel == 1)
    #expect(ParagraphFormat(style: .subheading, second: 2, third: 3).headingLevel == 2)
    #expect(ParagraphFormat(style: .subheading).headingLevel == 3)
    #expect(ParagraphFormat(style: .plain).headingLevel == nil)
    // The short spelling the fixtures use has to agree with the long one.
    #expect(ParagraphFormat(style: .subheading, hasFurtherFields: true).headingLevel == 2)
    #expect(ParagraphFormat(style: .subheading, hasFurtherFields: false).headingLevel == 3)
}

@Test("The nesting depth is the low half of tag 3, counted from one")
func listLevelsComeFromTheLowNibble() {
    // The first level carries no tag 3 at all.
    #expect(ParagraphFormat(style: .bullet).level == 1)
    #expect(ParagraphFormat(style: .checkbox).level == 1)
    // bullet 0x01/0x02, checkbox 0x11/0x12, numbered 0x21/0x22 — the family
    // is the high half and must not reach the answer.
    #expect(ParagraphFormat(style: .bulletNested, second: 3, third: 0x01).level == 2)
    #expect(ParagraphFormat(style: .bulletNested, second: 3, third: 0x02).level == 3)
    #expect(ParagraphFormat(style: .checkboxNested, second: 3, third: 0x11).level == 2)
    #expect(ParagraphFormat(style: .checkboxNested, second: 3, third: 0x12).level == 3)
    #expect(ParagraphFormat(style: .numberedNested, second: 3, third: 0x21).level == 2)
    #expect(ParagraphFormat(style: .numberedNested, second: 3, third: 0x22).level == 3)
    // A paragraph that is not a list item has no depth, whatever tag 3 holds.
    #expect(ParagraphFormat(style: .plain, second: 3, third: 0x12).level == 1)
}

@Test("A style nobody has named is kept rather than dropped")
func anUnknownStyleSurvivesAsItsRawValue() {
    // A new style arrives exactly this way — as a value nobody has written
    // down. Dropping the record would lose the paragraph's indent
    // along with the marker it could not draw.
    let unseen = ParagraphFormat(raw: 99, second: 7, third: 7)
    #expect(unseen.style == nil)
    #expect(unseen.raw == 99)
    #expect(unseen.hasFurtherFields)
    #expect(unseen.headingLevel == nil)
    #expect(unseen.level == 1)
}

@Test("A list item knows its family whatever its level")
func listFamiliesGroupTheStyles() {
    #expect(ParagraphStyle.bullet.listFamily == .bullet)
    #expect(ParagraphStyle.bulletNested.listFamily == .bullet)
    #expect(ParagraphStyle.checkbox.listFamily == .checkbox)
    #expect(ParagraphStyle.checkboxChecked.listFamily == .checkbox)
    #expect(ParagraphStyle.checkboxNested.listFamily == .checkbox)
    #expect(ParagraphStyle.numbered.listFamily == .numbered)
    #expect(ParagraphStyle.numberedNested.listFamily == .numbered)
    #expect(ParagraphStyle.plain.listFamily == nil)
    #expect(ParagraphStyle.heading.listFamily == nil)

    for style in ParagraphStyle.allListItems {
        #expect(style.isListItem, "\(style) is one of a list")
        #expect(style.listFamily != nil, "\(style) belongs to a family")
    }
    #expect(!ParagraphStyle.plain.isListItem)
    #expect(!ParagraphStyle.heading.isListItem)
}

private extension ParagraphStyle {
    static let allListItems: [ParagraphStyle] = [
        .bullet, .bulletNested, .checkbox, .checkboxChecked, .checkboxNested,
        .numbered, .numberedNested,
    ]
}
