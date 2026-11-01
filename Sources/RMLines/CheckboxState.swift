// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

/// How a checkbox of a list is shown.
///
/// Not the paragraph style alone: an item with items nested under it keeps
/// the style of an unticked box (`6`) and is shown by the tablet from what is
/// under it — ticked and struck through when every nested item is ticked, a
/// box with a dash when only some are. The file says which in the high bits
/// of `tag 3` (`ParagraphFormat.isTicked`, `hasTickedNestedItems`).
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum CheckboxState: Sendable, Hashable {
    case unticked
    case ticked
    /// Some of the nested items are ticked and some are not.
    case partial
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
extension CheckboxState {
    public static func == (a: CheckboxState, b: CheckboxState) -> Bool {
        switch (a, b) {
        case (.unticked, .unticked), (.ticked, .ticked), (.partial, .partial): true
        default: false
        }
    }
}

extension TextBlock {
    /// How the checkbox of a line is shown, or `nil` when the line is not an
    /// item of a checkbox list.
    ///
    /// Ticked when the file says so; partial when it says something under
    /// the item is ticked. Without those bits — a parent with nothing ticked
    /// under it, or a page that does not write them — the nested items
    /// themselves are read: partial when anything under the item is ticked,
    /// unticked when nothing is.
    public func checkboxState(ofLine line: Int) -> CheckboxState? {
        guard let format = formats[line], format.style?.listFamily == .checkbox else { return nil }
        if format.isTicked { return .ticked }
        if format.hasTickedNestedItems { return .partial }

        // The nested items are the lines after this one that stand deeper,
        // up to the first that does not — whatever their own families.
        var next = line + 1
        while next < lines.count {
            let level = formats[next].map { $0.style?.isListItem == true ? $0.level : 0 } ?? 0
            guard level > format.level else { break }
            if formats[next]?.isTicked == true { return .partial }
            next += 1
        }
        return .unticked
    }
}
