import Testing
import Foundation
@testable import BrowserTools
import ToolABI

/// An agent that types into a field got back a page that could not confirm what it typed.
///
/// The walker has always captured `input.value`; `parseDomNode` never read `inputData`; so the
/// serializer rendered `input("From")` whether the box was empty, held `01/01/2023`, or held
/// `1/1/23`. Measured on WebArena rows 705-713, whose `program_html` gold IS the field's exact
/// value (`document.querySelector('[id="sales_report_from"]').value`, exact_match "1/1/2023"): the
/// model was graded on a string it was structurally unable to read. Its own context repeated the
/// same `input("From")` line across steps 3-11 while it typed, saw nothing change, and typed again
/// -- and a taught rule in that same context told it to "READ THE FIELD BACK AND LEAVE WHAT IT
/// SHOWS", which the serializer made impossible.
///
/// `<select>` has always rendered its current selection. These pin the same courtesy for the
/// controls whose whole purpose is to hold a value -- and pin the two things that keep it from
/// costing anything: an empty field renders exactly as before, and a secret one never leaks.
@Suite struct InputValueRenderingTests {

    @Test("a filled field shows what is in it")
    func filled() throws {
        let out = try #require(renderInputValue(DomInputData(value: "1/1/2023")))
        #expect(out == "value=\"1/1/2023\"")
    }

    @Test("an empty field renders nothing, so a blank form costs no extra tokens")
    func empty() {
        #expect(renderInputValue(DomInputData(value: "")) == nil)
        #expect(renderInputValue(DomInputData(value: nil)) == nil)
        #expect(renderInputValue(nil) == nil)
        // Whitespace is not contents.
        #expect(renderInputValue(DomInputData(value: "   \n  ")) == nil)
    }

    @Test("a password is reported as FILLED without being handed over")
    func secretsNeverLeak() throws {
        let out = try #require(renderInputValue(DomInputData(value: "hunter2", isSecret: true)))
        #expect(out == "value=(hidden)")
        #expect(!out.contains("hunter2"))
    }

    @Test("a secret that is empty is still just empty")
    func emptySecret() {
        #expect(renderInputValue(DomInputData(value: "", isSecret: true)) == nil)
    }

    @Test("a long body is cut and its real length named")
    func longValueIsCapped() throws {
        let body = String(repeating: "x", count: 5_435)
        let out = try #require(renderInputValue(DomInputData(value: body)))
        #expect(out.contains("(5435 chars)"))
        #expect(out.count < 200)
        #expect(out.contains("\u{2026}"))
    }

    @Test("a value at the cap is not truncated")
    func atTheCap() throws {
        let exact = String(repeating: "y", count: inputValueCap)
        let out = try #require(renderInputValue(DomInputData(value: exact)))
        #expect(!out.contains("chars)"))
        #expect(out == "value=\"\(exact)\"")
    }

    @Test("newlines in a value do not break the one-line observation format")
    func multiline() throws {
        let out = try #require(renderInputValue(DomInputData(value: "line one\nline two")))
        #expect(!out.contains("\n"))
        #expect(out.contains("line one"))
        #expect(out.contains("line two"))
    }

    // MARK: the rows this was built for

    @Test("the date field the gold actually reads")
    func theDateField() throws {
        // WebArena 708 wants exact_match "1/1/2023"; 712 wants "5/1/21". Whatever the page holds,
        // the model can now see it and compare -- which is all this change claims to do.
        #expect(try #require(renderInputValue(DomInputData(value: "1/1/2023"))) == "value=\"1/1/2023\"")
        #expect(try #require(renderInputValue(DomInputData(value: "01/01/2023"))) == "value=\"01/01/2023\"")
        #expect(try #require(renderInputValue(DomInputData(value: "5/1/21"))) == "value=\"5/1/21\"")
    }

    @Test("the two formats a picker might normalise between are distinguishable")
    func formatsAreDistinct() {
        #expect(renderInputValue(DomInputData(value: "1/1/2023"))
                != renderInputValue(DomInputData(value: "1/1/23")))
    }

    /// The whole line, as the model reads it: the type the page declared, the format it
    /// advertises, the label, and what the box holds now. A plain empty text box keeps its old
    /// shape byte for byte.
    @Test("a date box reads as the page's own affordances plus its contents")
    func theWholeLine() {
        func input(_ data: DomInputData?) -> String {
            let node = DomNode(
                id: "42ba-00000001",
                element: DomElement(tagName: "input", attributes: ["aria-label": "From"]),
                content: DomContent(inputData: data),
                interactivity: DomInteractivity(isInteractive: true, isInput: true, isHighlighted: true))
            return emitInViewportElement(node, 0, [:])
        }
        #expect(input(DomInputData(type: "date", placeholder: "MM/DD/YYYY", value: "01/01/2023"))
            .hasPrefix("input(date, placeholder=\"MM/DD/YYYY\", \"From\", value=\"01/01/2023\")"))
        #expect(input(nil).hasPrefix("input(\"From\") {aloha-id="))
        #expect(input(DomInputData(value: "")).hasPrefix("input(\"From\") {aloha-id="))
    }
}

/// The one control whose whole purpose is to hold text was the one printing only its label.
///
/// `<input>` gained `value=` and `<select>` always rendered its selection; `case "textarea"` in
/// `emitInViewportElement` built `textarea("Body")` from the label and stopped. So an agent that
/// typed a post body could not read back a single character of it, and on run 34345778871
/// `textarea("Body")` was rendered 55 times without contents while
/// `unverified_write_share_of_answers` stood at 0.67 -- every answer given after a write nobody
/// had confirmed.
@Suite struct TextareaValueRenderingTests {

    private func textarea(label: String?, value: String?, secret: Bool = false) -> String {
        var attributes: [String: String] = [:]
        if let label { attributes["aria-label"] = label }
        let node = DomNode(
            id: "42ba-34373b52",
            element: DomElement(tagName: "textarea", attributes: attributes),
            content: DomContent(inputData: DomInputData(value: value, isSecret: secret)),
            interactivity: DomInteractivity(isInteractive: true, isInput: true, isHighlighted: true))
        return emitInViewportElement(node, 0, [:])
    }

    @Test("a filled textarea shows what is in it")
    func filled() {
        let out = textarea(label: "Body", value: "Diffusion models could help historians.")
        #expect(out.contains("textarea(\"Body\", value=\"Diffusion models could help historians.\")"))
        #expect(out.contains("aloha-id=\"42ba-34373b52\""))
    }

    @Test("an EMPTY textarea renders exactly as it did before, so a blank form costs nothing")
    func emptyIsUnchanged() {
        #expect(textarea(label: "Body", value: "").contains("textarea(\"Body\")"))
        #expect(textarea(label: "Body", value: nil).contains("textarea(\"Body\")"))
        #expect(!textarea(label: "Body", value: "").contains("value="))
    }

    @Test("a textarea with no label at all keeps its bare form")
    func noLabel() {
        let bare = textarea(label: nil, value: nil)
        #expect(bare.contains("textarea {"))
        #expect(!bare.contains("textarea("))
        // ... and gains parentheses only once there is something to put in them.
        #expect(textarea(label: nil, value: "typed").contains("textarea(value=\"typed\")"))
    }

    @Test("the policy is NOT reimplemented here: the cap and the secret rule come along for free")
    func delegatesToTheOwner() {
        let long = String(repeating: "x", count: 5_435)
        let out = textarea(label: "Body", value: long)
        #expect(out.contains("(5435 chars)"))
        #expect(out.count < 300)
        #expect(textarea(label: "Notes", value: "hunter2", secret: true).contains("value=(hidden)"))
        #expect(!textarea(label: "Notes", value: "hunter2", secret: true).contains("hunter2"))
    }

    @Test("a multi-line body does not break the one-line observation format")
    func multilineStaysOnOneLine() {
        let out = textarea(label: "Body", value: "first para\n\nsecond para")
        #expect(!out.contains("\n"))
        #expect(out.contains("first para"))
        #expect(out.contains("second para"))
    }
}

/// `parseDomNode` is where the walker's `inputData` becomes a `DomInputData` -- and where it was
/// being dropped on the floor. These pin what is read (value, placeholder, an informative type),
/// what is deliberately NOT read (the default `text` type, `required`, `disabled`) and the secrecy
/// decision, which is taken here so that no renderer downstream has to know the rule.
@Suite struct InputDataParsingTests {

    private func inputNode(type: String, value: String, placeholder: String = "",
                           autocomplete: String = "", attributes: [(String, JSValue)] = []) -> DomNode? {
        parseDomNode(.object([
            ("id", .string("n1")),
            ("element", .object([("tagName", .string("input")), ("attributes", .object(attributes))])),
            ("content", .object([("inputData", .object([
                ("type", .string(type)),
                ("value", .string(value)),
                ("placeholder", .string(placeholder)),
                ("autocomplete", .string(autocomplete)),
                ("required", .bool(true)),
                ("disabled", .bool(true))
            ]))]))
        ]))
    }

    @Test func parsesTheFieldsContents() {
        let node = inputNode(type: "text", value: "01/01/2023")
        #expect(node?.content.inputData?.value == "01/01/2023")
        #expect(node?.content.inputData?.isSecret == false)
    }

    @Test func dropsTheDefaultTypeAndKeepsAnInformativeOne() {
        // `text` on every ordinary box would be noise on every page.
        #expect(inputNode(type: "text", value: "x")?.content.inputData?.type == nil)
        #expect(inputNode(type: "", value: "x")?.content.inputData?.type == nil)
        #expect(inputNode(type: "TEXT", value: "x")?.content.inputData?.type == nil)
        // `date` tells the agent the field takes ISO, which is the whole question it could not
        // previously answer about a date box.
        #expect(inputNode(type: "date", value: "2023-01-01")?.content.inputData?.type == "date")
        #expect(inputNode(type: "number", value: "42")?.content.inputData?.type == "number")
    }

    @Test func carriesThePagesOwnFormatHint() {
        let node = inputNode(type: "text", value: "", placeholder: "MM/DD/YYYY")
        #expect(node?.content.inputData?.placeholder == "MM/DD/YYYY")
    }

    /// `required` would print on every mandatory field and `disabled` would change
    /// `isElementDisabled` across the whole serializer: neither is this change's business.
    @Test func requiredAndDisabledStayUnparsed() {
        let data = inputNode(type: "text", value: "x")?.content.inputData
        #expect(data?.required == false)
        #expect(data?.disabled == nil)
    }

    @Test func marksSecretsSoTheyAreNeverSerialized() {
        #expect(inputNode(type: "password", value: "hunter2")?.content.inputData?.isSecret == true)
        // The SITE's own marking, which beats any guess from a name or placeholder.
        #expect(inputNode(type: "text", value: "4111",
                          autocomplete: "cc-number")?.content.inputData?.isSecret == true)
        #expect(inputNode(type: "text", value: "x",
                          autocomplete: "current-password")?.content.inputData?.isSecret == true)
        #expect(inputNode(type: "text", value: "Ada")?.content.inputData?.isSecret == false)
    }

    /// The page-side predicate (`__alohaIsSensitiveField`) masks a credential field's value before
    /// it crosses the wire. That mask is a field the model may not read, not the field's contents:
    /// it renders `value=(hidden)`, never `value="[redacted: credential field]"`.
    @Test func thePagesOwnMaskIsASecretToo() throws {
        let node = try #require(inputNode(type: "text", value: sensitiveFieldMaskText))
        #expect(node.content.inputData?.isSecret == true)
        var masked = node
        masked.interactivity = DomInteractivity(isInteractive: true, isInput: true, isHighlighted: true)
        let line = emitInViewportElement(masked, 0, [:])
        #expect(line.contains("value=(hidden)"))
        #expect(!line.contains("redacted"))
    }

    @Test func aNodeWithNoInputDataStillParses() {
        let node = parseDomNode(.object([
            ("id", .string("n1")),
            ("element", .object([("tagName", .string("div")), ("attributes", .object([]))])),
            ("content", .object([("comprehensiveText", .string("hello"))]))
        ]))
        #expect(node?.content.inputData == nil)
        #expect(node?.content.comprehensiveText == "hello")
    }
}
