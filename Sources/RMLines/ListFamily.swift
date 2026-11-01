// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// Which family of list a paragraph belongs to. The high half of `tag 3` says
/// the same thing for a nested item: `0` bullet, `1` checkbox, `2` numbered.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum ListFamily: Sendable, Hashable {
    case bullet
    case checkbox
    case numbered
}

// Equality spelled out rather than synthesised.
//
// `@frozen` lets a consumer compare two values directly, through the witness
// the compiler derives — and that witness is internal, so it is absent from
// this module's symbol table when RMLines is linked as a binary framework.
// The reference resolves in a release build, where the comparison is inlined,
// and fails to link in a debug one. Declaring `==` here puts the comparison
// behind an exported symbol, which costs nothing and keeps `@frozen`: a new
// case must still break a consumer's build rather than fall into an
// `@unknown default`.
extension ListFamily {
    public static func == (a: ListFamily, b: ListFamily) -> Bool {
        switch (a, b) {
        case (.bullet, .bullet), (.checkbox, .checkbox), (.numbered, .numbered): true
        default: false
        }
    }
}
