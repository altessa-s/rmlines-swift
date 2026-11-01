# RMLines

Reading and writing the reMarkable `.rm` v6 page format: the page and its strokes, typed text and its paragraphs, highlights and images — and
writing fresh pages the tablet accepts (`RMWriter`). Nothing here draws, and nothing here has heard of the cloud, the document index or Finder.

A standalone Swift package with no dependencies at all. Consumers link either the sources or the `RMLines.xcframework` this repository builds. For
other platforms there is **[rmlines-lib](https://github.com/altessa-s/rmlines-lib)**, the same format as a portable C23 library: the two read the
same pages to the same strokes, text and styles, and write the same draft to the same bytes.

Part of **[Slate Drive](https://slatedrive.app)** ([repository](https://github.com/altessa-s/slatedrive)), the macOS app that shows a reMarkable
library in Finder. Its sibling **[rmdoc-swift](https://github.com/altessa-s/rmdoc-swift)** packs and unpacks the `.rmdoc` container these pages
travel in.

## Why it exists

A notebook on disk is a CRDT of tagged blocks, not a picture. Turning one into the other is two jobs: **read the file**, then **draw what was read**.
One package would blur that: a parser throwing a rendering error about a PDF context it never opened, line widths and type faces sitting next to the
binary reader, and a corpus test that cannot run without CoreGraphics.

The wall is this package's boundary. This side answers "what is on the page?"; a renderer, wherever it lives, answers "what does that look like?".

## What it depends on

Nothing. Foundation and CoreGraphics from the platform, `Synchronization` for one lock, and no package of anyone's. Diagnostics go to a sink the host
installs and nowhere at all until it does (see [Diagnostics](#diagnostics)): knowing nothing of the cloud, the index, Finder or a logger is what keeps
this testable against a corpus of files and nothing else.

CoreGraphics is the one platform type in the public API — `CGRect` on a highlight, `CGSize` on the sheet — and it is what pins the package to Apple
platforms, alongside the `.macOS(.v15)` the manifest declares. That is a deliberate trade: the alternative is a pair of geometry types every consumer
would convert at the boundary. Off Apple platforms, use [rmlines-lib](https://github.com/altessa-s/rmlines-lib).

## Design

**Read, do not draw.** `InkScale` says what a number in the file means (raw width ÷ 4 is a width on the page). Palettes, blend modes, type metrics and
templates belong to a renderer: they are measurements of a picture, and reading needs none of them.

**A page that will not parse is not a broken document.** An unreadable stroke is counted and the rest of the page is kept. A header of version 3 or 5
is `ParseError.unsupportedVersion`, not "unrecognisable bytes": the answers differ, and only a version that was actually read can be named to the
user.

**Loss is numbered, deletion is not.** `RMPage.skippedBlocks` is strokes and blocks this version could not read. The three service blocks every page
opens with (author table, migration, counters) hold nothing to draw and are not a loss. Erased items keep their place in the CRDT chain and are not a
loss either.

**A place, not a shift.** Handwriting anchored to typed text is fastened to a character. Turning that into coordinates takes a font and a column
width, both of which belong to drawing, so `TextAnchor` travels as a paragraph and an offset until then.

**Unknown markup is kept.** A paragraph style this package does not know is kept as its raw value and drawn as plain text rather than dropped —
dropping it loses the indent with the marker.

**A number that is not one does not reach the page.** A stroke whose thickness, width or pressure is NaN or infinite is a counted loss; a speed that is not a number
reads as nought, and an anchor's horizontal that is not one is left unset.

**The writer makes fresh pages only.** It never edits an existing file — inserting into somebody else's CRDT chains is a different contract, with a
user's notebook at stake. It writes a deliberately small subset of the format; the parser's tolerance is no licence for the writer.

## Parsing

`RMParser.parsePage` is the door. It accepts version **6** only. Versions 3 and 5 share the 43-byte header and nothing else: a flat container of
counters, not the tagged CRDT blocks below. The version is read out of the header rather than compared against a list of known spellings, so a future
7 is named as 7 instead of called unrecognisable.

The drawing order is the scene's, not the file's. Layers are the chain of `0x04` records; strokes are the chain within a layer. A hidden or deleted
layer is dropped here rather than at drawing time, so that it widens no sheet and shifts no anchor.

```swift
let page = try RMParser.parsePage(data)
// page.strokes, page.text, page.highlights, page.images
```

`parsePage` throws three of the four:

| Error | When |
|---|---|
| `ParseError.unsupportedVersion` | A `.rm` whose header names a generation this reader does not read. |
| `ParseError.unsupportedFormat` | Bytes that do not begin as a page at all. The first of them travel with the error. |
| `ParseError.unexpectedEndOfData` | The stream is shorter than a header, or a block declares a length past the end of the file. A field that fails inside a block costs only that block, and fewer than eight bytes left over after the last block are ignored. A broken list of text items or paragraph styles is the exception: it is dropped uncounted, and the text comes back without those records or styles. |

The fourth, `ParseError.malformedPage`, is what the individual block parsers raise — a length past the block, a NaN coordinate, a count too large for
the machine — and it does not reach the caller. A page is not lost for one stroke it could not read: the block is stepped over, the loss is added to
`RMPage.skippedBlocks`, and an `error` line goes to the diagnostics sink. `ParseRecoveryTests` is where that is written down.

A count the file declares is checked against the block it sits in before anything is reserved. The file's word alone is enough to claim gigabytes.

The work is bounded as well as the memory. A `.rm` arrives from a device or a sync service and is parsed inside somebody's application and its
extensions, in a task nothing interrupts, so a page that takes an hour is a hang the sender gets to choose. Both CRDT walks — the scene's chain of
strokes and the text's chain of records — read a tie once rather than once per record in it. `ParseRecoveryTests` holds a page built to be hostile
rather than broken: 20 000 records all naming one predecessor.

## The page

| Type | What it is |
|---|---|
| `RMPage` | One parsed page: strokes in scene order, typed text, highlights, images, the sheet the scene block declared, and whether the template and the imported document are shown. |
| `Stroke` | A pen stroke. Tool, palette index, points (position, width, pressure). `argb` when the file carries an explicit colour, which wins over the palette index. |
| `StrokePoint` | One sample. Speed and direction are in the file; drawing needs coordinates, width and pressure. |
| `PenTool` / `PenColor` | The tablet's own numbers. `isEraser` is here because an eraser *is* a stroke in the file, and drawing it covers the page where the user was erasing; `isHighlighter` because over handwriting the marker is a stroke too, and its band is the only record that anything was marked. How an index is coloured is not. |
| `Highlight` | A marker over the text of an imported PDF: ready-made rectangles, not a stroke, and the words under them as the tablet copied them out of the text layer. |
| `PageImage` | An insertion or a capture. The pixels are not in the `.rm`: the file names an attachment (`<page>/<uuid>.png`) and four vertices. `strokesBefore` is the z-order — an image can sit between strokes. |
| `InkScale` | The four numbers that belong to reading: units per raw width, a floor so a print stays visible, a ceiling against a NaN, and how opaque a translucent stroke is when the file does not say. |

The template name is not on the page. A `.rm` knows nothing about its background; `.content` / `.pagedata` do, and the caller stamps it with
`RMPage.with(templateName:)`.

`paperSize` comes from the scene info block, not from `.content`, which on some devices still holds the legacy 1404 × 1872 while the sheet is larger.

## Typed text

| Type | What it is |
|---|---|
| `TextBlock` | Lines in document order, where the column begins, how wide it is, paragraph formats and face runs. A page can carry this and no strokes at all. |
| `ParagraphStyle` | The tablet's `tag 1` values: body, three headings, bullets, checkboxes, numbered lists, and the nested forms of each. |
| `ParagraphFormat` | The whole record, not merely `tag 1`. Heading 2 and heading 3 both carry `3`; the `tag 2`/`tag 3` pair is what tells them apart. `level` reads nesting from the low nibble of `tag 3`. |
| `FaceRun` | Bold and italic on characters, not on the paragraph. Empty records fence a stretch; a paragraph with a bold word in it still calls itself plain. |
| `TextAnchor` | The character a stroke's coordinates are counted from: a paragraph index and a Unicode-scalar offset. `originX` is the file's own horizontal when the caret sits on a bidi boundary. |

Characters are numbered as Unicode scalars, the way the file numbers them. On NFC Latin and Cyrillic that agrees with graphemes; on Arabic diacritics
it does not, and a grapheme count shifts every style key and anchor after the first mark.

## Writing

`RMWriter.page` turns an `RMPageDraft` into the bytes of one page: the service blocks first and in the tablet's order, the attachment map where the
draft places images, the root text, a one-layer scene tree, then the strokes, the marks and the images. The draft speaks values, not settings — a
point carries the raw width the file stores, not a pen with a ramp, and a mark carries the horizontal its pen stands at, because the format knows no
layout and the end of a line is the layout's to know.

| Draft part | What it declares |
|---|---|
| `Sheet` | The ways the tablet declares a sheet — screen and canvas. Which sheet decides where absolute units land: a page claiming the legacy 1404 × 1872 puts its text in the side area of a larger device. |
| `Column`, `Paragraph` | The text column's width and setting; each paragraph's text, style record (`style`, `second`, `third`) and its bold and italic. |
| `Stroke`, `Point` | Loose or anchored strokes, points as the file stores them. |
| `Mark` | A stroke anchored to a character, with the horizontal the caller laid out. |
| `Image` | A placed picture: the attachment's file name, the sixteen bytes the item and the map share, its placement, and an anchor where it hangs on the text. |
| `author` / `marksAuthor` | The page's author, and the second one a page names when its text carries bold or italic — the formatting marks are another author's edits, and their author index has to resolve in the table. Leave `marksAuthor` unset and it is derived from `author`, the same way every time. |

The same draft writes the same bytes, however often it is written: a byte-level regression test is possible, and content-addressed storage sees no
change where there is none.

`RMWriter.page` throws rather than traps. A draft is built by code and a bad one is the caller's bug, but this package ships as a framework inside
somebody else's process — a `preconditionFailure` there takes the host down, and the host can neither catch it nor fall back to anything.

| Error | When |
|---|---|
| `WriteError.anchorOutOfRange` | A mark or an image is fastened to a paragraph the draft does not have. Written anyway, the ink would hang on nothing and vanish without a trace. |
| `WriteError.tooManyToNumber` | More items of one kind than a page's identifier ranges can name. Past the limit two items would be handed one counter, and the file cannot tell two meanings of one counter apart. |
| `WriteError.imageKeyNotSixteenBytes` | An image keyed by anything but the sixteen bytes an attachment key is. |
| `WriteError.pageTooLarge` | A draft so large that a block of the page would run past the 4 GiB its 32-bit length field can state. Checked before anything is laid out. |

Nothing is written in any case: a half-page is worse than none.

## Editing

`RMEditor.erasing(_:in:)` erases strokes and highlights from an existing page by the identifiers the page calls them by (`SceneItemID`,
`author:counter`), the way the tablet's own eraser does: each item stays as a tombstone, and every other byte goes out as it came in. The result is read
back before it is returned. `RMEditor.highlighterItems(in:)` answers every living mark of the highlighter, hidden layers included.

## Diagnostics

The parser has a handful of lines worth saying out loud — a stroke it could not read, a paragraph style it does not know, an image whose name is
missing from the attachment map. Each one is a piece of a page that will not be drawn.

So they go to a sink the host installs, and nowhere at all until it does. Silence is the supported default: a corpus test wants no log, and a library
that writes to a terminal nobody is watching is a library that has to be worked around.

```swift
import OSLog
import RMLines

let logger = Logger(subsystem: "com.example.app", category: "rmlines")
RMLinesLog.install { level, message in
    switch level {
    case .error: logger.error("\(message, privacy: .public)")
    case .debug: logger.debug("\(message, privacy: .public)")
    }
}
```

Nothing in a message is ever a secret: every value is a count, a block type or a raw style number. The page's writing, its text and its file names do
not reach a sink, so a host is free to install one that writes a file.

Two levels, not five: a piece of the page was lost (`error`), or the format held something this parser does not know and read past (`debug`).

## Using this package

**As a source dependency:**

```swift
dependencies: [
    .package(url: "https://github.com/altessa-s/rmlines-swift.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [.product(name: "RMLines", package: "rmlines-swift")]
    ),
]
```

`package:` is the package's **identity**, not the `name:` in its manifest — for a path or a URL dependency that is the directory or the repository,
`rmlines-swift`. Spelled `RMLines`, SwiftPM answers `unknown package 'RMLines' in dependencies of target 'YourTarget'`.

**As a binary.** `Scripts/build-xcframework.sh` produces `RMLines.xcframework`, and the consumer names it as a binary target:

```swift
targets: [
    .binaryTarget(name: "RMLines", path: "RMLines.xcframework"),
]
```

The framework is **dynamic**. Xcode embeds a package's binary framework into the application bundle whatever it holds: it refuses a static framework
for want of an `Info.plist`, and would otherwise copy in megabytes nothing loads. Dynamic also means one copy of the parser in a process — an app and
its extensions share it through the bundle's `Frameworks` — and two copies of a type in one process is how `catch let error as SomeError` quietly stops
catching.

What the binary does cost is `@testable import RMLines` on the consumer's side: a binary module carries no testability, so a consumer's tests see the
public API only. For the same reason every public enum in this package that has cases is `@frozen` — without it, library evolution makes them
resilient and every `switch` in every consumer needs an `@unknown default`. The caseless ones (`RMParser`, `RMWriter`, `InkScale`, `RMLinesLog`) are
namespaces with nothing to switch over, and carry no such attribute.

## Building the framework

```sh
Scripts/build-xcframework.sh                        # -> build/RMLines.xcframework
Scripts/build-xcframework.sh ../some-app/Frameworks # and install it there too
```

`Package.swift` is the real project; `project.yml` beside it declares the same sources once more as a framework target, because SwiftPM cannot produce
a framework — archiving its library product leaves a bare `.o`. The script generates that project with XcodeGen, archives it for macOS (arm64 and
x86_64), checks that what came out is a dynamic framework and that both slices are in it, and wraps it. Both checks are there because either failure
is silent until it reaches a consumer: a static framework is refused by Xcode's copy phase, and a single-slice one fails the release link of a
universal app.

## Releasing

Push a tag. `1.2.0` and `v1.2.0` both work, and a hyphen makes it a pre-release (`1.2.0-beta.2`).

```sh
git tag 1.2.0
git push origin 1.2.0
```

The tag runs the corpus first, then builds the framework, zips it with `ditto` (an `.xcframework` is a bundle of symlinks, and a plain `zip` unpacks
into something Xcode declines), and publishes it with the lines a consumer pastes:

```swift
.binaryTarget(
    name: "RMLines",
    url: "https://github.com/altessa-s/rmlines-swift/releases/download/1.2.0/RMLines.xcframework.zip",
    checksum: "…"
)
```

The checksum is computed in the same step from the very bytes that are uploaded: a remote binary target resolves by `url` **and** `checksum`, and one
worked out on somebody's laptop is a checksum of what was on that laptop.

The tag is also the version the framework declares. `project.yml` carries 0.0.0 — a number that says only "not a release" — and the release overrides
it. To reproduce a release build locally:

```sh
RMLINES_VERSION=1.2.0 Scripts/build-xcframework.sh
```

## Tests

```sh
swift test
```

The corpus is the one that matters. `V6SampleCorpusTests` reads third-party pages from
[remarkable_rust](https://github.com/hiteshjoshi/remarkable_rust)'s sample corpus, and the expected numbers are what the parser read when each was
taken in. A format change that breaks the parser shows up there first — which is only true because CI runs it on every push.

The rest:

| Suite | What it holds |
|---|---|
| `RMWriterTests` | The writer against the parser: a draft written and read back must answer with the same text, styles, strokes and anchors. Also the drafts this writer refuses, and text outside ASCII, where a length in bytes and a count of scalars stop being the same number. |
| `RMEditorTests`, `HiddenLayerEraseTests` | Erasing in place: one item, several, hidden layers, and the refusals. |
| `ParseRecoveryTests`, `CyclicGroupTests` | What a page that will not wholly parse does: truncation and a block declared past the end are errors; an unknown block and an unreadable stroke cost their block and are counted in `skippedBlocks`. Also what a page built to be hostile costs. |
| `FormatEdgeCaseTests`, `HardeningTests` | Hand-built and sample pages for the format's less common shapes, and values that are not numbers. |
| `TextLayoutAnchorTests` | Where handwriting anchored before, inside and after the text is placed. |
| `HeaderVersionTests` | An older generation is refused *by its version*, strange bytes as a format nobody can name. |
| `ParagraphFormatTests` | The style record decoded: a heading level read off the fields that follow `tag 1`, a nesting depth packed into half a byte. |
| `TextColumnTests` | The widest column that leaves a margin. |
| `RMPageTests` | `RMPage.with(templateName:)` carries every other field, and a field added to the page has to be added there too. |
| `BinaryReaderTests` | A count the file declares is a declaration, not a measurement — believed, it traps the process or reserves memory nobody has. |
| `LoggingTests` | The diagnostics sink: silence is the default, a message is not even built without one, and the latest install stands. |

What is deliberately not here: anything that needs a picture. Ink widths, palettes, type metrics and templates are measurements of a drawing, and the
tests that own them belong with whatever does the drawing.

## See also

- **[rmlines-lib](https://github.com/altessa-s/rmlines-lib)** — the same format as a portable C23 library, with a `rmdump` tool.
- **[rmdoc-swift](https://github.com/altessa-s/rmdoc-swift)** — the `.rmdoc` container a document and its pages are exported and imported in.
- **[Slate Drive](https://slatedrive.app)** ([repository](https://github.com/altessa-s/slatedrive)) — the app these packages are part of.

## Acknowledgements

The `.rm` format is not published by reMarkable. This package is built on openly available information and on the research of third-party
developers who documented the format, among them [rmscene](https://github.com/ricklupton/rmscene) and
[remarkable_rust](https://github.com/hiteshjoshi/remarkable_rust).

## Licence

MIT — see [LICENSE](LICENSE). The sample corpus under `Tests/RMLinesTests/Fixtures/v6-samples/` comes from
[remarkable_rust](https://github.com/hiteshjoshi/remarkable_rust) and carries its own licence beside it.

reMarkable is a trademark of reMarkable AS. This project is not affiliated with, endorsed by or sponsored by reMarkable AS.
