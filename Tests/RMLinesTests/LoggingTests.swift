// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import Synchronization
import Testing
@testable import RMLines

// The one seam this package has with its host. The parser says what it could
// not read; where that goes is the host's to decide, and until it decides,
// nowhere — a library that writes to a terminal nobody is watching is a
// library that has to be worked around.

@Suite("The diagnostics sink", .serialized)
struct RMLinesLogTests {
    private final class Collected: Sendable {
        let lines = Mutex<[(RMLinesLog.Level, String)]>([])
        func install() {
            RMLinesLog.install { level, message in
                self.lines.withLock { $0.append((level, message)) }
            }
        }
        var messages: [String] { lines.withLock { $0.map(\.1) } }
    }

    @Test("An installed sink receives the line with its level")
    func installedSinkReceivesLines() {
        let collected = Collected()
        collected.install()
        defer { RMLinesLog.silence() }
        RMLinesLog.error("page: a stroke was lost")
        RMLinesLog.debug("render: unknown paragraph style 10")
        let seen = collected.lines.withLock { $0 }
        #expect(seen.contains { $0.0 == .error && $0.1 == "page: a stroke was lost" })
        #expect(seen.contains { $0.0 == .debug && $0.1 == "render: unknown paragraph style 10" })
    }

    @Test("With no sink installed nothing is built and nothing is written")
    func silenceIsTheDefault() {
        let collected = Collected()
        collected.install()
        RMLinesLog.silence()
        // The message is behind an autoclosure: with no sink there is not even
        // an interpolation, which is what makes a debug line on the parsing
        // path free. `built` proves the closure was never entered.
        let built = Mutex(false)
        RMLinesLog.debug({ built.withLock { $0 = true }; return "never" }())
        #expect(built.withLock { $0 } == false)
        #expect(collected.messages.isEmpty)
    }

    // The one place a parse and a sink are exercised together. It belongs in
    // this suite and not beside the other recovery tests: the sink is
    // process-wide, and a test that installs one races any test that silences
    // one. `.serialized` on this suite is what keeps them apart — and the
    // races it prevents are silent, which is why this note is here.
    @Test("A lost stroke reaches the sink as an error")
    func aLostStrokeIsSaidOutLoud() throws {
        let collected = Collected()
        collected.install()
        defer { RMLinesLog.silence() }

        var bytes = [UInt8](RMParser.header.utf8)
        // A stroke block whose payload is not a stroke.
        let payload = [UInt8](repeating: 0, count: 24)
        bytes += withUnsafeBytes(of: UInt32(payload.count).littleEndian) { Array($0) }
        bytes += [0, 1, 1, 0x05] + payload

        let page = try RMParser.parsePage(Data(bytes))
        #expect(page.skippedBlocks == 1)
        #expect(collected.messages.contains { $0.contains("unreadable") })
    }

    // The two losses a tombstone would hide: an image item and a group item
    // whose value is there but not of its shape, which the page would read
    // as erasures with no line written for either.
    // The bytes are built in `ParseRecoveryTests`; the sink half is here for
    // the reason given above.
    @Test("A lost image reaches the sink as an error")
    func aLostImageIsSaidOutLoud() throws {
        let collected = Collected()
        collected.install()
        defer { RMLinesLog.silence() }

        let page = try RMParser.parsePage(try imagePageWithThreeCorners())
        #expect(page.skippedBlocks == 1)
        let seen = collected.lines.withLock { $0 }
        #expect(seen.contains { $0.0 == .error && $0.1.contains("1 other blocks") })
        #expect(seen.contains { $0.0 == .error && $0.1.contains("3 vertices, not 4") })
    }

    @Test("A lost group item reaches the sink as an error")
    func aLostGroupItemIsSaidOutLoud() throws {
        let collected = Collected()
        collected.install()
        defer { RMLinesLog.silence() }

        let page = try RMParser.parsePage(try strokePageWithAMistypedGroupItem())
        #expect(page.skippedBlocks == 1)
        let seen = collected.lines.withLock { $0 }
        #expect(seen.contains { $0.0 == .error && $0.1.contains("not a group") })
    }

    @Test("A second install replaces the first")
    func theLatestSinkStands() {
        let first = Collected()
        let second = Collected()
        first.install()
        second.install()
        defer { RMLinesLog.silence() }
        RMLinesLog.error("page: an image without a name in the attachment map is lost")
        #expect(first.messages.isEmpty)
        #expect(second.messages.count == 1)
    }
}
