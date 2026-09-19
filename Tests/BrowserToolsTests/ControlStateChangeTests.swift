import Testing
import Foundation
import ToolABI
@testable import BrowserTools

/// A click that toggles its own target is invisible to every other signal on that path: same
/// document generation, same element count, same URL. So the receipt reported "the page did not
/// change" about a click that had just done exactly what was asked.
///
/// Measured across six nav-33 runs: every attempt the harness threw away as `data_invalid` was a
/// reddit write row, and 595-599 ("open the thread of a trending post and subscribe") appear in
/// that set in every one of them. The model subscribes, is told nothing changed, clicks again,
/// trips the repeat guard, and the bail is recorded as a crash that voids the attempt — after
/// 1,112 llmdex rounds across the 19 attempts in run 33993714531 alone.
///
/// These assert the Swift half. The JS probe was replayed under node against fake DOM objects
/// before this landed, which is the only check available on a machine that cannot build the package.
struct ControlStateChangeTests {

    private func state(_ name: String, present: Bool = true, pressed: String? = nil,
                       checked: String? = nil, expanded: String? = nil, selected: String? = nil,
                       disabled: String? = nil, value: String? = nil) -> ControlState {
        ControlState(present: present, name: name, pressed: pressed, checked: checked,
                     expanded: expanded, selected: selected, disabled: disabled, value: value)
    }

    @Test("the row this was built for: Subscribe becomes Unsubscribe")
    func subscribeToggle() throws {
        let note = try #require(ControlStateChange.note(from: state("Subscribe"),
                                                       to: state("Unsubscribe")))
        #expect(note.contains("\"Subscribe\" -> \"Unsubscribe\""))
        #expect(note.contains("CHANGED STATE"))
        // The instruction is the point. Naming the change without forbidding the repeat leaves
        // the exact behaviour this exists to stop still available.
        #expect(note.contains("Do not click it again"))
    }

    @Test("a control that did not move produces no note at all")
    func unchanged() {
        #expect(ControlStateChange.note(from: state("Subscribe"), to: state("Subscribe")) == nil)
    }

    @Test("an unreadable probe on either side is silence, never a claim")
    func unreadable() {
        #expect(ControlStateChange.note(from: nil, to: state("Unsubscribe")) == nil)
        #expect(ControlStateChange.note(from: state("Subscribe"), to: nil) == nil)
        #expect(ControlStateChange.note(from: nil, to: nil) == nil)
    }

    @Test("a control the click removed reports that, rather than reading as a lost element")
    func vanished() throws {
        let note = try #require(ControlStateChange.note(from: state("Delete"),
                                                        to: ControlState.absent))
        #expect(note.contains("NO LONGER IN THE PAGE"))
        #expect(note.contains("Do not look for that aloha-id again"))
    }

    @Test("an element absent on BOTH sides is not a change")
    func absentThroughout() {
        #expect(ControlStateChange.note(from: ControlState.absent, to: ControlState.absent) == nil)
    }

    @Test("a control that only ever appears after the click makes no claim")
    func appeared() {
        // before.present is false, so there is no before-state to have changed FROM.
        #expect(ControlStateChange.note(from: ControlState.absent, to: state("Save")) == nil)
    }

    @Test("aria flags carry the toggle when the label does not")
    func ariaFlags() throws {
        let pressed = try #require(ControlStateChange.note(
            from: state("Bold", pressed: "false"), to: state("Bold", pressed: "true")))
        #expect(pressed.contains("aria-pressed went false -> true"))

        let checked = try #require(ControlStateChange.note(
            from: state("", checked: "false"), to: state("", checked: "true")))
        #expect(checked.contains("checked went false -> true"))

        let expanded = try #require(ControlStateChange.note(
            from: state("Filters", expanded: "false"), to: state("Filters", expanded: "true")))
        #expect(expanded.contains("aria-expanded went false -> true"))
    }

    @Test("a flag that appears from nothing reads as unset, not as a crash")
    func flagAppears() throws {
        let note = try #require(ControlStateChange.note(
            from: state("Tab"), to: state("Tab", selected: "true")))
        #expect(note.contains("aria-selected went unset -> true"))
    }

    @Test("several changes at once read as prose")
    func several() throws {
        let note = try #require(ControlStateChange.note(
            from: state("Subscribe", pressed: "false"),
            to: state("Unsubscribe", pressed: "true")))
        #expect(note.contains(" and "))
        #expect(note.contains("\"Subscribe\" -> \"Unsubscribe\""))
        #expect(note.contains("aria-pressed went false -> true"))
    }

    @Test("an empty label is named rather than printed as nothing")
    func emptyLabel() throws {
        let note = try #require(ControlStateChange.note(from: state(""), to: state("Saved")))
        #expect(note.contains("(empty) -> \"Saved\""))
    }

    // MARK: what the page actually sends back

    @Test("the probe's JSON parses, including nulls and a real bool")
    func parsing() throws {
        let parsed = try #require(ControlState.parse(
            "{\"present\":true,\"name\":\"Unsubscribe\",\"pressed\":null,\"checked\":\"false\","
            + "\"expanded\":null,\"selected\":null,\"disabled\":null,\"value\":null}"))
        #expect(parsed.present)
        #expect(parsed.name == "Unsubscribe")
        #expect(parsed.pressed == nil)
        #expect(parsed.checked == "false")
    }

    @Test("a JSON bool is read as a flag, not dropped")
    func parsesBools() throws {
        let parsed = try #require(ControlState.parse("{\"present\":true,\"name\":\"x\",\"checked\":true}"))
        #expect(parsed.checked == "true")
    }

    @Test("absence parses as absence")
    func parsesAbsent() throws {
        let parsed = try #require(ControlState.parse("{\"present\":false}"))
        #expect(parsed.present == false)
    }

    @Test("garbage, empty and nil are all nil — a probe cannot break a working receipt")
    func parseFailures() {
        #expect(ControlState.parse(nil) == nil)
        #expect(ControlState.parse("") == nil)
        #expect(ControlState.parse("not json") == nil)
        #expect(ControlState.parse("[1,2,3]") == nil)
    }
}
