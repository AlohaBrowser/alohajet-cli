import Foundation

/// A CLICK THAT CHANGES ITS OWN TARGET LEAVES NO OTHER TRACE, and that is how a finished task
/// turns into a destroyed one.
///
/// Measured across six nav-33 runs (33918469392, 33956015125, 33958787300, 33966206093,
/// 33968816635, 33993714531): every attempt the harness discarded as `data_invalid` was a reddit
/// WRITE row, and rows 595-599 — "open the thread of a trending post and subscribe" — are in that
/// set in every run. The trace of one is the whole argument: the model clicks `Subscribe`, the
/// click lands, the URL does not move, `pageFingerprint` sees the same generation and the same
/// element count, so the receipt says the page did not change and no snapshot is attached. The
/// model, correctly, concludes the click did nothing and clicks again. The repeat guard counts
/// the pair, bails, and alohajet exits non-zero; the runner maps a non-zero exit onto
/// `alohajet crashed before any LLM round` and voids the attempt. The subscription was already
/// made on the first click. Between them those 19 voided attempts had made 1,112 llmdex rounds,
/// and 0-5 attempts per run score 1.0 and are thrown away this way.
///
/// The evidence the click worked was on the button the whole time: its label went `Subscribe` ->
/// `Unsubscribe`. Nothing read it.
///
/// WHY THESE PROPERTIES AND NOT A DIFF OF THE PAGE. A toggle is defined by the few things a
/// control is allowed to say about itself — its accessible label, and the ARIA/DOM state flags
/// browsers and component libraries already maintain because assistive technology depends on
/// them. `aria-pressed` on a toggle button, `checked` on a box, `aria-expanded` on a disclosure,
/// `aria-selected` on a tab, `disabled` on a control that has done its job. None of that is a
/// property of Postmill, or of reddit, or of this corpus: a page that does not maintain them
/// produces no note and pays nothing, and one that does gets its receipt on any site.
struct ControlState: Equatable {
    var present: Bool
    var name: String
    var pressed: String?
    var checked: String?
    var expanded: String?
    var selected: String?
    var disabled: String?
    var value: String?

    static let absent = ControlState(present: false, name: "", pressed: nil, checked: nil,
                                     expanded: nil, selected: nil, disabled: nil, value: nil)

    /// Parses what the in-page probe returned. Anything unreadable is nil, never a throw: this is
    /// a probe on the side of a working receipt and must never be able to break one.
    static func parse(_ json: String?) -> ControlState? {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        func text(_ key: String) -> String? {
            guard let v = raw[key] else { return nil }
            if v is NSNull { return nil }
            if let s = v as? String { return s }
            if let b = v as? Bool { return b ? "true" : "false" }
            return nil
        }
        return ControlState(
            present: (raw["present"] as? Bool) ?? false,
            name: text("name") ?? "",
            pressed: text("pressed"), checked: text("checked"),
            expanded: text("expanded"), selected: text("selected"),
            disabled: text("disabled"), value: text("value"))
    }
}

enum ControlStateChange {
    /// The sentence to append to a click receipt, or nil when the control did not move.
    ///
    /// The wording carries one instruction, because one behaviour is what this exists to stop: the
    /// model clicked a control that worked, was told nothing, and clicked it again. Saying only
    /// "the label changed" leaves the re-click available. So the note states what changed AND that
    /// it is the confirmation, in the same breath.
    static func note(from before: ControlState?, to after: ControlState?) -> String? {
        guard let before, let after, before != after else { return nil }

        // GONE IS A CHANGE, not a failure to read. A control that submitted itself away, or a row
        // that the click removed, is the clearest possible evidence the click did something — and
        // it is the case most likely to be misread as "the element could not be found".
        if before.present, !after.present {
            return " The control you clicked is NO LONGER IN THE PAGE — the click removed or"
                + " replaced it. That is this click's receipt: it did something. Do not look for"
                + " that aloha-id again, and do not repeat the click."
        }
        guard before.present, after.present else { return nil }

        var parts: [String] = []
        if before.name != after.name, !before.name.isEmpty || !after.name.isEmpty {
            parts.append("its label went \(quoted(before.name)) -> \(quoted(after.name))")
        }
        appendFlag("aria-pressed", before.pressed, after.pressed, &parts)
        appendFlag("checked", before.checked, after.checked, &parts)
        appendFlag("aria-expanded", before.expanded, after.expanded, &parts)
        appendFlag("aria-selected", before.selected, after.selected, &parts)
        appendFlag("disabled", before.disabled, after.disabled, &parts)
        if before.value != after.value, before.value != nil || after.value != nil {
            parts.append("its value went \(quoted(before.value ?? "")) -> \(quoted(after.value ?? ""))")
        }
        guard !parts.isEmpty else { return nil }

        return " The control you clicked CHANGED STATE: " + joined(parts) + "."
            + " That is this click's receipt — it worked, even though the page did not navigate."
            + " Do not click it again to check."
    }

    private static func appendFlag(_ label: String, _ before: String?, _ after: String?,
                                   _ parts: inout [String]) {
        guard before != after, before != nil || after != nil else { return }
        parts.append("\(label) went \(before ?? "unset") -> \(after ?? "unset")")
    }

    private static func quoted(_ s: String) -> String {
        s.isEmpty ? "(empty)" : "\"\(s)\""
    }

    /// "a", "a and b", "a, b and c" — the note is read as prose, not parsed.
    private static func joined(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
    }
}
