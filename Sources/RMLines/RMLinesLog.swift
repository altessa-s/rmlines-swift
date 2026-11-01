// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Synchronization

/// Where the parser's diagnostics go.
///
/// This package parses bytes and does nothing else: it has no logger of its
/// own, no opinion about files or the system log, and no dependency on the
/// host that gives it a page. What it does have is a handful of lines worth
/// saying out loud — a stroke it could not read, a paragraph style this
/// parser does not know, an image whose name is missing from the attachment
/// map. Each one is a piece of a page that will not be drawn, and each one is
/// the kind of thing that is found months later, in someone's notebook,
/// because nothing ever said it.
///
/// So the lines are written to whatever the host installed, and to nothing at
/// all until it does. Not called is the supported state — a corpus test wants
/// no log — and the default is silence rather than `print`, because a library
/// that writes to a terminal nobody is watching is a library that has to be
/// worked around.
///
/// Nothing here is ever a secret: every value in every message below is a
/// count, a block type or a raw style number. The page's writing, its text
/// and its file names do not reach a sink, so the host is free to install one
/// that writes a file and keep it.
public enum RMLinesLog {
    /// How much the line matters. Two levels and not five: a piece of the
    /// page was lost (`error`), or the format held something this parser does
    /// not know and read past (`debug`).
    ///
    /// Frozen: this framework ships in lockstep with what links it, so there is
    /// no ABI to protect — and an exhaustive `switch` over these cases in a
    /// consumer is the point. A new case must break its build, not fall into an
    /// `@unknown default`.
    @frozen
    public enum Level: Sendable {
        case debug
        case error
    }

    /// What a host installs. Called on whichever thread parsed the page —
    /// `RMParser` is called from wherever the work is, and a sink that
    /// touches shared state must say so itself.
    public typealias Sink = @Sendable (Level, String) -> Void

    /// Name the sink for this process. Once, at its start, from the
    /// composition root; a later call replaces the earlier one.
    public static func install(_ sink: @escaping Sink) {
        installed.withLock { $0 = sink }
    }

    /// Go back to silence. For a test that installed a sink and must not
    /// leave it behind for the next one.
    public static func silence() {
        installed.withLock { $0 = nil }
    }

    // MARK: - What the parser calls

    static func error(_ message: @autoclosure () -> String) {
        write(.error, message)
    }

    static func debug(_ message: @autoclosure () -> String) {
        write(.debug, message)
    }

    /// The message is built behind an autoclosure and the closure is read
    /// under the lock: with no sink installed nothing is interpolated at all,
    /// which is what makes a `debug` line on a hot parsing path free.
    private static func write(_ level: Level, _ message: () -> String) {
        guard let sink = installed.withLock({ $0 }) else { return }
        sink(level, message())
    }

    private static let installed = Mutex<Sink?>(nil)
}
