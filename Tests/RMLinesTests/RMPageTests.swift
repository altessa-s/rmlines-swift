// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import Testing
@testable import RMLines

// `RMPage.with(templateName:)` rebuilds the whole page around one new field,
// and its own documentation calls that a trap: leaving a field out would be
// harmless only while nothing carries it, and the next field added to the page
// would go the same way with nothing to say so. This is the something that
// says so.

private func fullPage(templateName: String? = nil) -> RMPage {
    RMPage(
        strokes: [
            Stroke(tool: .fineliner2, color: .red, thicknessScale: 2,
                   points: [StrokePoint(x: 1, y: 2, width: 3, pressure: 4)],
                   argb: 0xFF00_FF00,
                   anchor: TextAnchor(paragraph: 1, offset: 2, originX: -3)),
        ],
        skippedBlocks: 7,
        templateName: templateName,
        paperSize: CGSize(width: 1620, height: 2160),
        backgroundVisible: false,
        rootDocumentVisible: false,
        text: TextBlock(
            originX: -468, originY: 234, lines: ["one", "two"],
            formats: [0: ParagraphFormat(style: .heading)],
            faces: [1: [FaceRun(range: 0..<3, bold: true, italic: false)]],
            columnWidth: 936
        ),
        anchoredStrokes: 5,
        highlights: [
            Highlight(rectangles: [CGRect(x: 1, y: 2, width: 3, height: 4)],
                      color: .yellow, argb: 0xFFFF_FF00, text: "marked"),
        ],
        images: [
            PageImage(file: "a.png",
                      vertices: [PageImage.Vertex(x: 1, y: 2, u: 0, v: 1)],
                      strokesBefore: 1,
                      anchor: TextAnchor(paragraph: 0, offset: 1)),
        ]
    )
}

@Test("Stamping a template changes the template and carries everything else")
func withTemplateNameLosesNothing() {
    let stamped = fullPage().with(templateName: "Grid")
    #expect(stamped.templateName == "Grid")
    #expect(stamped == fullPage(templateName: "Grid"), "every other field travelled")
    // And back the other way: nil is a value, not "leave it alone".
    #expect(fullPage(templateName: "Grid").with(templateName: nil) == fullPage())
}

@Test("A field added to the page has to be added to with(templateName:) as well")
func theFieldCountIsWatched() {
    // Not a style rule: the only way `with(templateName:)` can be wrong is by
    // forgetting a field, and forgetting is silent. When this number changes,
    // the test above has to be given the new field before it is raised.
    let fields = Mirror(reflecting: fullPage()).children.count
    #expect(fields == 10, "RMPage gained or lost a field — check with(templateName:)")
}
