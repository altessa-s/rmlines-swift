// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import Testing
@testable import RMLines

// Where a stroke's coordinates are counted from. The format reserves two
// identifiers for "before the text" and "after the text", and the layout the
// parser assembles is what turns either into a paragraph and an offset —
// before any font or column width is known, which is why it is tested here
// and not with the renderer that draws the result.

@Test("Handwriting anchored to the end of the text goes below it")
func endSentinelAnchorsToTheLastLine() {
    // The format reserves two identifiers for "before the text" and "after
    // the text", and handwriting placed around the typed block is anchored
    // to those rather than to a character. Taking the end sentinel for an
    // unknown character puts every such stroke on line zero — on top of a
    // drawing that sits above the text.
    let layout = RMParser.TextLayout(
        origin: (x: 0, y: 0),
        placeOfCharacter: [CrdtID(author: 1, counter: 37): TextAnchor(paragraph: 2, offset: 1)],
        lines: ["one", "two", "three", "four"],
        formatOfLine: [:],
        faces: [:],
        columnWidth: nil
    )

    #expect(
        layout.anchor(of: CrdtID(author: 1, counter: 37)) == TextAnchor(paragraph: 2, offset: 1),
        "a character keeps its own place"
    )
    #expect(
        layout.anchor(of: CrdtID(author: 0, counter: RMParser.TextLayout.startSentinel))
            == TextAnchor(paragraph: 0, offset: 0)
    )
    // The last line, not the first. And one past its
    // last letter — an anchor names the character the pen stands before,
    // and "after everything typed" is before the character that would come
    // next.
    #expect(
        layout.anchor(of: CrdtID(author: 0, counter: RMParser.TextLayout.endSentinel))
            == TextAnchor(paragraph: 3, offset: 5)
    )
    // Anything genuinely unknown has no answer — guessing zero for it piles
    // the strokes up on line zero.
    #expect(layout.anchor(of: CrdtID(author: 9, counter: 999)) == nil)

    // Text ending with newlines leaves empty paragraphs behind it. "After
    // the text" is just past the last character, and the last Return ends
    // the paragraph it closes — the second one here, not the empty third.
    let trailing = RMParser.TextLayout(
        origin: (x: 0, y: 0),
        placeOfCharacter: [:],
        lines: ["Test test", "", ""],
        formatOfLine: [:],
        faces: [:],
        columnWidth: nil
    )
    #expect(
        trailing.anchor(of: CrdtID(author: 0, counter: RMParser.TextLayout.endSentinel))
            == TextAnchor(paragraph: 1, offset: 1)
    )
}

@Test("A text of nothing but newlines ends where its last Return stands")
func endSentinelOnEmptyParagraphsGoesToTheBottom() {
    // Nineteen Returns and no letter, with handwriting anchored to
    // paragraphs 0, 4 and 17 and one block to the end. The tablet draws that
    // block one line under the one at 17 — paragraph 18, which the last
    // Return closes. The first paragraph puts it on top of the others; the
    // last, a line too low.
    let layout = RMParser.TextLayout(
        origin: (x: 0, y: 0),
        placeOfCharacter: [:],
        lines: Array(repeating: "", count: 20),
        formatOfLine: [:],
        faces: [:],
        columnWidth: nil
    )
    #expect(
        layout.anchor(of: CrdtID(author: 0, counter: RMParser.TextLayout.endSentinel))
            == TextAnchor(paragraph: 18, offset: 1)
    )
}

@Test("No text at all ends where it starts")
func endSentinelOnNoTextStaysAtTheStart() {
    // Both shapes of "nothing typed": no lines, and the single empty line
    // the parser starts every text with.
    for lines in [[], [""]] as [[String]] {
        let layout = RMParser.TextLayout(
            origin: (x: 0, y: 0),
            placeOfCharacter: [:],
            lines: lines,
            formatOfLine: [:],
            faces: [:],
            columnWidth: nil
        )
        #expect(
            layout.anchor(of: CrdtID(author: 0, counter: RMParser.TextLayout.endSentinel))
                == TextAnchor(paragraph: 0, offset: 0),
            "\(lines)"
        )
    }
}
