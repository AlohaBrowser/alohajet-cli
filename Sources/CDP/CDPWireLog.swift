import ToolABI

// MARK: - The outbound wire log's copy of a command

extension CDPClient {
    static let textEntryMethods: Set<String> = [
        "Input.dispatchKeyEvent",
        "Input.insertText",
        "Input.imeSetComposition",
    ]

    /// A text-entry command spells the typed character in far more than `text`:
    /// `key`, `unmodifiedText`, `code` (`KeyQ`), `keyIdentifier` (`U+0051`) and both
    /// virtual key codes each name it too. So its params are kept by ALLOWLIST, not by
    /// stripping known text fields — a field this list does not name is withheld.
    static let inertTextEntryParams: Set<String> = [
        "type", "modifiers", "timestamp", "autoRepeat", "isKeypad", "isSystemKey",
        "location", "commands",
    ]

    /// The copy of an outbound payload the wire log records. A text-entry command
    /// keeps its method, id, session and inert params, and every other param is
    /// replaced — a string by its length. Any other command is logged as before,
    /// truncated.
    static func payloadForWireLog(method: String, payload: String) -> String {
        guard textEntryMethods.contains(method) else {
            return truncateString(payload, limit: 800)
        }
        guard case .object(let members)? = JSValue.parse(payload) else {
            return "[payload redacted]"
        }
        let redacted = JSValue.object(members.map { name, value in
            (name, name == "params" ? redactingTextEntry(value) : value)
        })
        return truncateString(redacted.stringify(), limit: 800)
    }

    private static func redactingTextEntry(_ params: JSValue) -> JSValue {
        guard case .object(let members) = params else { return .string("[redacted]") }
        return .object(members.map { name, value in
            if inertTextEntryParams.contains(name) { return (name, value) }
            if case .string(let text) = value { return (name, .string("[redacted \(text.count) chars]")) }
            return (name, .string("[redacted]"))
        })
    }
}
