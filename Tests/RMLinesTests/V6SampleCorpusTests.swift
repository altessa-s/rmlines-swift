// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMLines
import Testing

// Third-party pages from remarkable_rust's sample corpus (see the LICENSE
// beside them): the one set of `.rm` bytes in this repository that our own
// writer did not produce, spanning the v6 format from its first pages on. A
// change on the tablet must not break the parser silently, and pages we
// assemble ourselves can only ever prove the parser reads what the writer
// writes.
//
// The expected numbers are a reading, not a wish: what the parser reads
// out of each page, checked against what the sample's name says the page
// holds — `Bold_Heading_Bullet_Normal` really decodes to those four
// paragraph styles, `test-crdt-ordering` really assembles to `A12_Z`.

/// What the parser reads out of a sample.
private struct Expected {
    var strokes = 0
    var highlights = 0
    /// The typed lines, when the page has text; nil for ink-only pages.
    var lines: [String]?
}

private let corpus: [String: Expected] = [
    "Bold_Heading_Bullet_Normal.rm": Expected(
        lines: ["A", "new line", "B is a letter of the alphabet", "C"]
    ),
    "Color_and_tool_v3.14.4.rm": Expected(strokes: 25, highlights: 6),
    "Lines_v2.rm": Expected(strokes: 10),
    "Lines_v2_updated.rm": Expected(strokes: 10, lines: [""]),
    "More_color_highlight_shader_v3.15.4.2.rm": Expected(strokes: 23),
    "Normal_AB.rm": Expected(lines: ["AB"]),
    "Normal_A_stroke_2_layers.rm": Expected(strokes: 2, lines: ["A"]),
    "Normal_A_stroke_2_layers_v3.2.2.rm": Expected(strokes: 3, lines: ["A", "v3.2.2"]),
    "Normal_A_stroke_2_layers_v3.3.2.rm": Expected(
        strokes: 9,
        lines: [
            "A", "v3.2.2", "Normal bold italic", "Bold italic normal",
            "Bold line", "Normal line", "Heading line",
        ]
    ),
    "Wikipedia_highlighted_p1.rm": Expected(highlights: 4),
    "Wikipedia_highlighted_p2.rm": Expected(highlights: 2),
    "With_SceneInfo_Block.rm": Expected(strokes: 13, lines: ["TEST TEXT", "Test text from keyboard"]),
    "test-crdt-ordering.rm": Expected(lines: ["A12_Z"]),
]

private func sampleURLs() throws -> [URL] {
    let directory = try #require(Bundle.module.resourceURL)
        .appendingPathComponent("Fixtures/v6-samples")
    return try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "rm" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

@Test func sampleCorpusParsesToWhatItHolds() throws {
    let urls = try sampleURLs()
    #expect(Set(urls.map(\.lastPathComponent)) == Set(corpus.keys))
    for url in urls {
        let name = url.lastPathComponent
        guard let expected = corpus[name] else { continue }
        let page = try RMParser.parsePage(Data(contentsOf: url))
        #expect(page.strokes.count == expected.strokes, "\(name)")
        #expect(page.highlights.count == expected.highlights, "\(name)")
        #expect(page.text?.lines == expected.lines, "\(name)")
        #expect(page.images.isEmpty, "\(name)")
        // Every block in every sample is one the parser understands — a
        // new block type shows up here first.
        #expect(page.skippedBlocks == 0, "\(name)")
    }
}

// The sample's name promises the four styles in order; our decoding of the
// style codes has to land on the same four. This crosses two independent
// readings: theirs of what the tablet wrote, ours of what the codes mean.
@Test func paragraphStylesMatchTheSampleName() throws {
    let url = try #require(
        sampleURLs().first { $0.lastPathComponent == "Bold_Heading_Bullet_Normal.rm" }
    )
    let text = try #require(RMParser.parsePage(Data(contentsOf: url)).text)
    #expect(text.formats[0]?.raw == 3)  // bold paragraph
    #expect(text.formats[1]?.raw == 2)  // heading
    #expect(text.formats[2]?.raw == 4)  // bullet
    #expect(text.formats[3]?.raw == 1)  // plain
}

// Bold and italic fences survive a page whose text moved around: the
// `Normal_A_stroke_2_layers_v3.3.2` sample carries two lines with face runs.
@Test func faceRunsSurviveMovedText() throws {
    let url = try #require(
        sampleURLs().first { $0.lastPathComponent == "Normal_A_stroke_2_layers_v3.3.2.rm" }
    )
    let text = try #require(RMParser.parsePage(Data(contentsOf: url)).text)
    #expect(text.faces.count == 2)
}
