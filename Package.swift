// swift-tools-version: 6.3
// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

// The tablet's file format, both ways: the `.rm` v6 stream, the page and its
// strokes, typed text and its paragraphs. Reading and writing only — nothing
// here draws, and nothing here has ever heard of the cloud, the index or
// Finder. That is what keeps it testable against a corpus of files and
// nothing else: this package depends on nothing but the platform, and says
// what it could not read through `RMLinesLog`, whose sink the host
// installs.
import PackageDescription

let package = Package(
    name: "RMLines",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RMLines", targets: ["RMLines"]),
    ],
    targets: [
        .target(
            name: "RMLines",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RMLinesTests",
            dependencies: ["RMLines"],
            // Copied rather than processed: these are `.rm` files, the bytes
            // matter, and a resource processor has no business touching them.
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
