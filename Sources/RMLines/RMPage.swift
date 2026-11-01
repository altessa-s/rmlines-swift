// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics

/// A parsed notebook page.
public struct RMPage: Sendable, Hashable {
    public let strokes: [Stroke]
    /// Marker over the text of an imported PDF. Empty on a notebook, which
    /// has no text layer to highlight.
    public let highlights: [Highlight]
    /// The typed text, if the page has any.
    public let text: TextBlock?
    /// How many strokes were positioned from the text rather than from the
    /// sheet.
    ///
    /// Diagnostic, like `skippedBlocks`: anchored handwriting that fails to
    /// find its anchor stays at its raw coordinates and lands on top of
    /// whatever is there, which looks like a drawing bug rather than like a
    /// parsing one. A number makes the difference visible.
    public let anchoredStrokes: Int
    /// The blocks we did not understand: unknown types, and known ones whose
    /// body failed to parse. Counted so that a silent loss of content is visible.
    public let skippedBlocks: Int
    /// The page's template. The name comes from the document's `.content`
    /// rather than from the page itself: a `.rm` file knows nothing about its
    /// own background.
    public let templateName: String?
    /// The sheet size declared by the page itself in the scene info block.
    /// More accurate than what `.content` writes; `nil` on files without such
    /// a block.
    public let paperSize: CGSize?
    /// Whether the page's template is shown. The user can hide the background
    /// on the tablet; the flag lives in the scene info block, and a renderer
    /// that ignores it shows the template anyway on a page that hid it —
    /// content the tablet does not show.
    public let backgroundVisible: Bool
    /// Whether the imported document behind the page is shown. Same block,
    /// same reason: hiding the source PDF is the user's own edit, and drawing
    /// it regardless shows what they put away.
    public let rootDocumentVisible: Bool
    /// The images placed on the page, in the scene's order. A page of
    /// captures carries nothing else — unread, it comes out blank.
    public let images: [PageImage]

    public init(
        strokes: [Stroke],
        skippedBlocks: Int,
        templateName: String? = nil,
        paperSize: CGSize? = nil,
        backgroundVisible: Bool = true,
        rootDocumentVisible: Bool = true,
        text: TextBlock? = nil,
        anchoredStrokes: Int = 0,
        highlights: [Highlight] = [],
        images: [PageImage] = []
    ) {
        self.highlights = highlights
        self.strokes = strokes
        self.skippedBlocks = skippedBlocks
        self.templateName = templateName
        self.paperSize = paperSize
        self.backgroundVisible = backgroundVisible
        self.rootDocumentVisible = rootDocumentVisible
        self.text = text
        self.anchoredStrokes = anchoredStrokes
        self.images = images
    }

    /// The same page with the given template.
    ///
    /// Everything else travels, `highlights` included: leaving a field out
    /// here would be harmless only while a page of an imported PDF is the
    /// sole carrier of it and this is called on notebooks — a trap all the
    /// same, since the next field added to the page would go the same way
    /// with nothing to say so.
    public func with(templateName: String?) -> RMPage {
        RMPage(
            strokes: strokes,
            skippedBlocks: skippedBlocks,
            templateName: templateName,
            paperSize: paperSize,
            backgroundVisible: backgroundVisible,
            rootDocumentVisible: rootDocumentVisible,
            text: text,
            anchoredStrokes: anchoredStrokes,
            highlights: highlights,
            images: images
        )
    }
}
