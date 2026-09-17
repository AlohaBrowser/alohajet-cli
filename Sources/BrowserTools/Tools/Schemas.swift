import Foundation
import ToolABI

/// The `inputSchema` uses the same `JSValue` shape as an OpenAI function tool's
/// `parameters` and an Anthropic tool's `input_schema`, and the same shape MCP's
/// `tools/list` expects — so the nine entries below advertise to any of the
/// three with no translation.
public struct NativeToolSchema: Sendable, Equatable {
    public var name: String
    public var description: String?
    public var inputSchema: JSValue?

    public init(name: String, description: String? = nil, inputSchema: JSValue? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// `minimum`/`maximum`/`minItems`/`maxItems` exist because every limit these
/// tools enforce used to be prose the schema could not state: the 20-element
/// batch caps, the 30-second wait clamp, the zero-based option index. A
/// validating provider could not see any of them, so a call that the runtime was
/// about to clamp or truncate was accepted as-is.
private func schemaField(
    type: String,
    description: String? = nil,
    enumValues: [String]? = nil,
    defaultValue: JSValue? = nil,
    items: JSValue? = nil,
    minimum: Double? = nil,
    maximum: Double? = nil,
    minItems: Int? = nil,
    maxItems: Int? = nil
) -> JSValue {
    var members: [(String, JSValue)] = [("type", .string(type))]
    if let enumValues {
        members.append(("enum", .array(enumValues.map { .string($0) })))
    }
    if let items {
        members.append(("items", items))
    }
    if let description {
        members.append(("description", .string(description)))
    }
    if let defaultValue {
        members.append(("default", defaultValue))
    }
    if let minimum {
        members.append(("minimum", .number(minimum)))
    }
    if let maximum {
        members.append(("maximum", .number(maximum)))
    }
    if let minItems {
        members.append(("minItems", .number(Double(minItems))))
    }
    if let maxItems {
        members.append(("maxItems", .number(Double(maxItems))))
    }
    return .object(members)
}

/// NO TOP-LEVEL COMBINATOR, BY CONSTRUCTION. OpenAI rejects a chat request whose function
/// `parameters` carry `anyOf`/`oneOf`/`allOf`/`enum`/`const`/`not` at the top level — and it
/// rejects the WHOLE request, every tool in it, so one such schema costs the agent every turn.
/// An `anyOf` listing alternative required-key sets shipped here and did exactly that in
/// production. The two tools that take either of two shapes say so in their description
/// instead, and their executors refuse a call that names neither.
private func objectSchema(_ properties: [(String, JSValue)], required: [String]) -> JSValue {
    .object([
        ("type", .string("object")),
        ("properties", .object(properties)),
        ("required", .array(required.map { .string($0) }))
    ])
}

private let manageTabsDescription = """
Work with browser tabs. Six actions.

**list** — every open tab: its id, title, URL, and which one is in use.

**read** — returns one tab's page as interactive markdown: headings, lists, links, tables and paragraphs, with every actionable element (link, button, input, select) carrying a trailing {aloha-id="..."} marker. Those ids are what page_click, page_type, page_select and get_text address. A tab that cannot produce interactive markdown (a non-web tab, or one with no attached DOM) falls back to plain markdown with no ids.

**open** — opens a new tab at url AND returns its page in the same result, so one call navigates and reads. Only http and https URLs are accepted. Pass controlled_by: "user" instead when you are handing the user a link to read rather than a page you will drive; that opens an ordinary background tab and returns only its id.

**close** — closes a tab by id. Close the tabs you opened once you are done with them. Only those: a tab that was already open when this session started, or that the user opened, is refused — "list" marks them.

**use** — makes an existing tab the one the page tools address. Exactly one tab is in use at a time; open takes it too, unless you pass use: false.

**unuse** — clears that selection, leaving no tab in use.

Page state is never pushed to you and nothing refreshes a page you have already read: after any click, type or navigation, call read again on that tab to see where it now is.
"""

private let manageTabsSchema = objectSchema([
    ("action", schemaField(
        type: "string",
        description: "Which operation to run.",
        enumValues: ["list", "read", "open", "close", "use", "unuse"]
    )),
    ("tab_id", schemaField(
        type: "string",
        description: "The tab to act on. Required by \"read\", \"close\" and \"use\"; ignored otherwise."
    )),
    ("url", schemaField(
        type: "string",
        description: "The page to load. Required by \"open\"; http and https only."
    )),
    ("use", schemaField(
        type: "boolean",
        description: "Applies to \"open\". Default true: the new tab becomes the one the page tools address, sparing a separate \"use\" call. The page comes back in the result either way. Pass false for a batch of opens, or when you do not intend to interact with the page. Ignored when controlled_by is \"user\".",
        defaultValue: .bool(true)
    )),
    ("controlled_by", schemaField(
        type: "string",
        description: "Applies to \"open\". \"agent\" (the default) opens a tab this session owns: it is marked agent-controlled, so the host shows its AI indicator and exempts it from background throttling, its network traffic is recorded when the session logs it, and it is taken into use with its page in the result. \"user\" opens an ordinary background tab instead, exactly as if the user had middle-clicked the link — no indicator, no recording, not taken into use, no page in the result, and close refuses it afterwards because it counts as the user's. Use it for links you are handing the user to read, not pages you intend to drive.",
        enumValues: ["agent", "user"],
        defaultValue: .string("agent")
    )),
    ("include_screenshot", schemaField(
        type: "boolean",
        description: "Applies to \"read\" and \"open\". Attaches a viewport screenshot next to the markdown, so layout, modals and anything the markdown cannot express are visible. Costs image tokens."
    ))
], required: ["action"])

private let pageClickDescription =
    "Click an element on the active tab by its aloha-id. click_type selects single/double/triple/right-click."

private let pageClickSchema = objectSchema([
    ("aloha_id", schemaField(type: "string", description: "The aloha-id of the element to click.")),
    ("click_type", schemaField(
        type: "string",
        description: "Which kind of click to dispatch.",
        enumValues: ["single", "double", "triple", "right"],
        defaultValue: .string("single")
    ))
], required: ["aloha_id"])

// A CAPABILITY THE MODEL IS NOT TOLD ABOUT IS NOT A CAPABILITY. A form filled one field per round
// costs a round per field, and the standing prompt is re-sent on every round. The description leads
// with the batch form because that is the one that saves the rounds.
private let pageTypeDescription =
    "Type text into input/textarea/contenteditable elements by aloha-id. "
    + "To fill a FORM, pass all of its fields in one call as \"fields\": "
    + "[{\"aloha_id\":\"1f3a9c2b\",\"text\":\"...\"},{\"aloha_id\":\"7b21e40d\",\"text\":\"...\"}] (up to 20, filled in order) "
    + "with submit:true to press Enter once at the end — one call instead of one per field. "
    + "For a single field, pass aloha_id and text directly. One of the two shapes is required: "
    + "either aloha_id with text, or fields."

private let pageTypeSchema = objectSchema([
    ("aloha_id", schemaField(type: "string", description: "The aloha-id of the element to type into. Omit when using \"fields\".")),
    ("text", schemaField(type: "string", description: "The text to type. Omit when using \"fields\".")),
    ("fields", schemaField(
        type: "array",
        description: "Several fields to fill in one call, in order. "
            + "Values are taken literally, so text containing commas is safe. If any field fails, the others "
            + "stay filled and Enter is NOT pressed.",
        // `items` DECLARED, matching every other array in this file: a provider running strict function-calling
        // rejects an array parameter with no item schema outright, which would cost the tool its whole call
        // rather than degrade it.
        items: objectSchema([
            ("aloha_id", schemaField(type: "string", description: "The aloha-id of the element to type into.")),
            ("text", schemaField(type: "string", description: "The text to type into it.")),
            ("replace", schemaField(
                type: "boolean",
                description: "Clear this field before typing. Defaults to true.",
                defaultValue: .bool(true)
            ))
        ], required: ["aloha_id", "text"]),
        minItems: 1,
        maxItems: 20
    )),
    ("replace", schemaField(
        type: "boolean",
        description: "Clear the field's existing value before typing. Defaults to true — pass false to append instead.",
        defaultValue: .bool(true)
    )),
    ("submit", schemaField(
        type: "boolean",
        description: "Press Enter after typing to submit. With \"fields\", pressed once after the last field.",
        defaultValue: .bool(false)
    ))
], required: [])

private let pageSelectDescription =
    "Select an option in a <select> dropdown on the active tab by its aloha-id, matching by visible text or index. "
    + "At least one of text or index is required."

private let pageSelectSchema = objectSchema([
    ("aloha_id", schemaField(type: "string", description: "The aloha-id of the <select> element.")),
    ("text", schemaField(type: "string", description: "The visible option text to match. At least one of text/index is required.")),
    ("index", schemaField(
        type: "integer",
        description: "The zero-based option index to match. At least one of text/index is required.",
        minimum: 0
    ))
], required: ["aloha_id"])

// A CAPABILITY THE MODEL IS NOT TOLD ABOUT IS NOT A CAPABILITY. The executor reads several elements in
// one call; unadvertised, that lever never fires. So the description says so, in the words the caller
// needs: pass several ids at once.
private let getTextDescription =
    "Read the visible text (or input value) of elements on the active tab by aloha-id. "
    + "Pass SEVERAL ids at once as a comma-separated list (\"1f3a9c2b,7b21e40d,3c8f95a1\", up to 20) and each is returned "
    + "labelled with its id — one call instead of one per element."

private let getTextSchema = objectSchema([
    ("aloha_id", schemaField(
        type: "string",
        description: "One aloha-id, or several as a comma-separated list (\"1f3a9c2b,7b21e40d,3c8f95a1\", up to 20 per call). "
                   + "Reading a whole list of rows in one call costs one round instead of one round each.")),
    ("max_chars", schemaField(
        type: "integer",
        description: "Total character budget for the text returned, split evenly across the ids read. A read that hits it "
                   + "is truncated and says so. Raise it deliberately: reading a container element can return an entire page.",
        defaultValue: .number(20_000),
        minimum: 1
    ))
], required: ["aloha_id"])

private let pageNavigateDescription =
    "Navigate the active tab's current page in place: go to a URL, or go back in history. "
    + "Unlike manage_tabs' \"open\" action, this never creates a new tab."

private let pageNavigateSchema = objectSchema([
    ("action", schemaField(
        type: "string",
        description: "\"goto\" navigates to url; \"back\" steps back in history.",
        enumValues: ["goto", "back"]
    )),
    ("url", schemaField(
        type: "string",
        description: "The URL to navigate to. Required when action is \"goto\"; ignored for \"back\". http and https only."))
], required: ["action"])

private let pagePressKeysDescription =
    "Send a keyboard key or chord to whatever currently has focus on the active tab."

private let pagePressKeysSchema = objectSchema([
    ("keys", schemaField(type: "string", description: "The key or chord to send, e.g. \"Enter\", \"Escape\", \"Control+a\"."))
], required: ["keys"])

private let pageWaitForDescription =
    "Poll the active tab until an element matching a CSS selector appears, or a timeout elapses."

private let pageWaitForSchema = objectSchema([
    ("selector", schemaField(type: "string", description: "The CSS selector to wait for.")),
    ("timeout_ms", schemaField(
        type: "integer",
        description: "How long to wait, in milliseconds. Capped at 30000 (30s) — values above the cap are clamped, not rejected.",
        defaultValue: .number(10_000),
        minimum: 0,
        maximum: 30_000
    ))
], required: ["selector"])

private let pageUploadDescription =
    "Attach files to a file input on the active tab by its aloha-id. This is how you upload: a plain "
    + "page_click on a [uploadable] element is refused, because it opens a native OS file dialog that is "
    + "invisible to you and cannot be driven. Paths are read from the machine running this tool, so they "
    + "must be absolute. If the element has no file <input>, the files are dropped on it instead, which is "
    + "what a dropzone expects."

private let pageUploadSchema = objectSchema([
    ("aloha_id", schemaField(type: "string", description: "The aloha-id of the [uploadable] file input, or of the dropzone holding it.")),
    ("paths", schemaField(
        type: "array",
        description: "Absolute paths of the files to attach, in order. They are read from this machine, not from the page.",
        items: schemaField(type: "string"),
        minItems: 1
    ))
], required: ["aloha_id", "paths"])

private let nativeToolSchemaTable: [String: NativeToolSchema] = [
    "manage_tabs": NativeToolSchema(name: "manage_tabs", description: manageTabsDescription, inputSchema: manageTabsSchema),
    "page_click": NativeToolSchema(name: "page_click", description: pageClickDescription, inputSchema: pageClickSchema),
    "page_type": NativeToolSchema(name: "page_type", description: pageTypeDescription, inputSchema: pageTypeSchema),
    "page_select": NativeToolSchema(name: "page_select", description: pageSelectDescription, inputSchema: pageSelectSchema),
    "get_text": NativeToolSchema(name: "get_text", description: getTextDescription, inputSchema: getTextSchema),
    "page_navigate": NativeToolSchema(name: "page_navigate", description: pageNavigateDescription, inputSchema: pageNavigateSchema),
    "page_press_keys": NativeToolSchema(name: "page_press_keys", description: pagePressKeysDescription, inputSchema: pagePressKeysSchema),
    "page_wait_for": NativeToolSchema(name: "page_wait_for", description: pageWaitForDescription, inputSchema: pageWaitForSchema),
    "page_upload": NativeToolSchema(name: "page_upload", description: pageUploadDescription, inputSchema: pageUploadSchema)
]

/// The wire surface a consumer can pin: tool name -> parameter name -> that parameter's enum
/// values, empty when it has none. Derived from the schemas above, so it cannot drift from what
/// is actually advertised.
///
/// NAMES AND ENUM VALUES ONLY, never the prose. `manage_tabs`'s description alone is over 4,000
/// characters, and a snapshot that churns on every wording tweak is a test people switch off —
/// which leaves the wire unpinned, which is worse than not pinning it. The names are what other
/// code hardcodes: a consumer repeats a tool or parameter name as a bare string at every call
/// site, and a host gates the surface with a by-name allow-list. Renaming one here is a silent
/// break on both sides unless this pin fails first.
///
/// Top-level parameters only. A nested item property (`page_type`'s `fields[]`) reuses a name
/// that is already a top-level parameter of the same tool, so a by-name allow-list sees it here.
///
/// The un-advertised legacy synonyms `manage_tabs` still accepts (`tabId`, `focus`, `unfocus` —
/// see ``manageTabsLegacyWireHits``) are absent by construction: they are not in a schema.
public let canonicalToolWireSurface: [String: [String: [String]]] =
    nativeToolSchemaTable.mapValues { schemaWireSurface($0.inputSchema) }

/// The parameter names and enum values of one `objectSchema`. `last(where:)` because `JSValue`
/// object members are an ordered list that permits duplicate keys, with the last one winning.
private func schemaWireSurface(_ schema: JSValue?) -> [String: [String]] {
    guard case let .object(members)? = schema,
          case let .object(properties)? = members.last(where: { $0.0 == "properties" })?.1
    else { return [:] }
    return Dictionary(uniqueKeysWithValues: properties.map { name, field in
        guard case let .object(attributes) = field,
              case let .array(values)? = attributes.last(where: { $0.0 == "enum" })?.1
        else { return (name, []) }
        return (name, values.compactMap { value in
            guard case let .string(text) = value else { return nil }
            return text
        })
    })
}

/// Returns the advertising schema for every browser tool, in the same order as
/// ``nativeAgentToolNames``.
public func getNativeAgentToolSchemas() -> [NativeToolSchema] {
    nativeAgentToolNames.map { name in
        nativeToolSchemaTable[name] ?? NativeToolSchema(name: name)
    }
}

public func getNativeAgentToolSchema(_ name: String) -> NativeToolSchema? {
    nativeToolSchemaTable[name]
}

/// Whether a tool only observes the page, for an MCP host's `readOnlyHint`.
///
/// WRITTEN OUT BY HAND, and it has to be. Nothing in this package derives it: a
/// classifier that enumerated "every mutating tool" would list none of these
/// nine and answer read-only for all of them, which is false for seven.
///
/// `manage_tabs` is annotated **false** even though its `list` and `read`
/// actions are read-only — `readOnlyHint` is per tool, not per call, and the
/// same tool opens and closes tabs.
public let nativeAgentToolReadOnlyHints: [String: Bool] = [
    "manage_tabs": false,
    "page_click": false,
    "page_type": false,
    "page_select": false,
    "get_text": true,
    "page_navigate": false,
    "page_press_keys": false,
    "page_wait_for": true,
    "page_upload": false
]
