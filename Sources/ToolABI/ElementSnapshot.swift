import Foundation

// MARK: - Action label / snapshot building

public let defaultLabelMaxLength = 80
let typedTextPreviewMaxLength = 40

/// Field-name fragments that indicate a sensitive (password-like) field.
public let sensitiveFieldNames: Set<String> = [
    "password", "passwd", "pwd", "pass", "new-password", "current-password",
    "newpassword", "currentpassword"
]

/// Query-parameter names that should be redacted from logged URLs.
let sensitiveQueryParamPattern = "(token|auth|sess(ion)?|jwt|bearer|sig|signature|key|secret|password|otp|code|access|refresh|api[_-]?key|nonce)"

/// Collapses whitespace and truncates a label to `maxLength`, appending an
/// ellipsis when truncated.
public func truncateLabel_2(_ value: String, _ maxLength: Int = defaultLabelMaxLength) -> String {
    let collapsed = collapseWhitespace(value).trimmingCharacters(in: .whitespacesAndNewlines)
    if collapsed.count <= maxLength { return collapsed }
    let sliceCount = max(0, maxLength - 1)
    let head = String(collapsed.prefix(sliceCount))
    let trimmedHead = trimTrailingWhitespace(head)
    return trimmedHead + "…"
}

public struct ElementBBox: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ActionPoint: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public func getElementCenterPoint(_ bbox: ElementBBox) -> ActionPoint {
    ActionPoint(x: Int((bbox.x + bbox.width / 2).rounded()), y: Int((bbox.y + bbox.height / 2).rounded()))
}

/// Redacts sensitive query parameters and hash fragments from a URL.
public func redactSensitiveUrlParams(_ url: String) -> String {
    guard var components = URLComponents(string: url) else { return url }
    if let items = components.queryItems {
        let kept = items.filter { !matches($0.name, sensitiveQueryParamPattern, caseInsensitive: true) }
        components.queryItems = kept.isEmpty ? nil : kept
    }
    if let fragment = components.fragment,
       matches(fragment, "(token|auth|jwt|bearer|access|refresh)", caseInsensitive: true) {
        components.fragment = nil
    }
    return components.string ?? url
}

public struct ElementSnapshot: Sendable, Equatable {
    public var label: String
    public var role: String
    public var tagName: String
    public var bbox: ElementBBox
    public var htmlId: String?
    public var name: String?
    public var inViewport: Bool?
    public var ariaLabel: String?
    public var title: String?
    public var innerText: String?
    public var altText: String?
    public var inputType: String?
    public var placeholder: String?
    public var disabled: Bool?
    public var required: Bool?
    public var checked: Bool?
    public var href: String?
    public var pageUrl: String?
    public var pageTitle: String?
    public var frameUrl: String?

    public init(label: String, role: String, tagName: String, bbox: ElementBBox) {
        self.label = label
        self.role = role
        self.tagName = tagName
        self.bbox = bbox
    }
}

public func buildElementSnapshotSummary(_ raw: ElementSnapshot) -> ElementSnapshot {
    var summary = ElementSnapshot(
        label: truncateLabel_2(raw.label),
        role: raw.role,
        tagName: raw.tagName,
        bbox: raw.bbox
    )
    if let v = raw.htmlId { summary.htmlId = truncateLabel_2(v, 60) }
    if let v = raw.name { summary.name = truncateLabel_2(v, 60) }
    if let v = raw.inViewport { summary.inViewport = v }
    if let v = raw.ariaLabel { summary.ariaLabel = truncateLabel_2(v) }
    if let v = raw.title { summary.title = truncateLabel_2(v) }
    if let v = raw.innerText { summary.innerText = truncateLabel_2(v, 120) }
    if let v = raw.altText { summary.altText = truncateLabel_2(v) }
    if let v = raw.inputType { summary.inputType = v.lowercased() }
    if let v = raw.placeholder { summary.placeholder = truncateLabel_2(v) }
    if let v = raw.disabled { summary.disabled = v }
    if let v = raw.required { summary.required = v }
    if let v = raw.checked { summary.checked = v }
    if let v = raw.href { summary.href = redactSensitiveUrlParams(v) }
    if let v = raw.pageUrl { summary.pageUrl = redactSensitiveUrlParams(v) }
    if let v = raw.pageTitle { summary.pageTitle = truncateLabel_2(v, 120) }
    if let v = raw.frameUrl { summary.frameUrl = redactSensitiveUrlParams(v) }
    return summary
}

public func isPasswordField(_ element: ElementSnapshot) -> Bool {
    if element.inputType == "password" { return true }
    let haystack = "\(element.label) \(element.placeholder ?? "") \(element.name ?? "") \(element.htmlId ?? "") \(element.ariaLabel ?? "")".lowercased()
    for fragment in sensitiveFieldNames where haystack.contains(fragment) {
        return true
    }
    return false
}

public enum AgentActionKind: String, Sendable, Equatable {
    case click, type, select, scroll, hover, press_keys, navigate, upload, start_agent, snapshot
}

public enum AgentActionData: Sendable, Equatable {
    case element(ElementSnapshot)
    case type(element: ElementSnapshot, textPreview: String, replace: Bool?, redacted: Bool)
    case select(element: ElementSnapshot, chosenLabel: String)
    case pressKeys(keys: String)
    case navigate(url: String, previousUrl: String?, pageTitle: String?)
    case upload(element: ElementSnapshot, pathCount: Int)
    case startAgent(agentId: String?, prompt: String)
    case snapshot(reason: String?)
}

/// A recorded agent action surfaced in the sub-agent UI timeline.
public struct AgentAction: Sendable, Equatable {
    public var iconName: String
    public var label: String
    public var tabId: String?
    public var xy: ActionPoint?
    public var screenshotPath: String?
    public var startedAt: Double?
    public var completedAt: Double?
    public var isError: Bool?
    public var errorMessage: String?
    public var kind: AgentActionKind
    public var data: AgentActionData
}

public struct ActionBuilderBase: Sendable {
    public var tabId: String?
    public var screenshotPath: String?
    public var startedAt: Double?
    public var completedAt: Double?
    public var isError: Bool?
    public var errorMessage: String?

    public init(
        tabId: String? = nil,
        screenshotPath: String? = nil,
        startedAt: Double? = nil,
        completedAt: Double? = nil,
        isError: Bool? = nil,
        errorMessage: String? = nil
    ) {
        self.tabId = tabId
        self.screenshotPath = screenshotPath
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.isError = isError
        self.errorMessage = errorMessage
    }
}

func buildBaseAction(_ base: ActionBuilderBase, _ icon: String, _ label: String, _ xy: ActionPoint?, kind: AgentActionKind, data: AgentActionData) -> AgentAction {
    AgentAction(
        iconName: icon,
        label: truncateLabel_2(label),
        tabId: base.tabId,
        xy: xy,
        screenshotPath: base.screenshotPath,
        startedAt: base.startedAt,
        completedAt: base.completedAt,
        isError: base.isError,
        errorMessage: base.errorMessage.map { truncateLabel_2($0, 200) },
        kind: kind,
        data: data
    )
}

public func buildClickAction(_ base: ActionBuilderBase, element: ElementSnapshot) -> AgentAction {
    let summary = buildElementSnapshotSummary(element)
    let point = getElementCenterPoint(summary.bbox)
    let label = base.isError == true ? "Failed to click \(summary.label)" : "Clicked \(summary.label)"
    return buildBaseAction(base, "MousePointerClick", label, point, kind: .click, data: .element(summary))
}

public func buildCoordinateClickAction(_ base: ActionBuilderBase, x: Double, y: Double) -> AgentAction {
    let point = ActionPoint(x: Int(x.rounded()), y: Int(y.rounded()))
    let label = base.isError == true ? "Failed to click at (\(point.x), \(point.y))" : "Clicked at (\(point.x), \(point.y))"
    let snapshot = ElementSnapshot(
        label: "(\(point.x), \(point.y))",
        role: "point",
        tagName: "point",
        bbox: ElementBBox(x: Double(point.x), y: Double(point.y), width: 0, height: 0)
    )
    return buildBaseAction(base, "MousePointerClick", label, point, kind: .click, data: .element(snapshot))
}

/// Builds a "type text" action, masking password fields.
public func buildTypeAction(_ base: ActionBuilderBase, element: ElementSnapshot, text: String, replace: Bool?) -> AgentAction {
    let summary = buildElementSnapshotSummary(element)
    let point = getElementCenterPoint(summary.bbox)
    let redacted = isPasswordField(summary)
    let preview = redacted ? "•••" : truncateLabel_2(text, typedTextPreviewMaxLength)
    let verb = replace == true ? "Replaced" : "Typed"
    let label: String
    if base.isError == true {
        label = "Failed to type into \(summary.label)"
    } else if redacted {
        label = "\(verb) password into \(summary.label)"
    } else {
        label = "\(verb) \"\(preview)\" into \(summary.label)"
    }
    return buildBaseAction(base, "Keyboard", label, point, kind: .type, data: .type(element: summary, textPreview: preview, replace: replace, redacted: redacted))
}

public func buildSelectAction(_ base: ActionBuilderBase, element: ElementSnapshot, chosenLabel: String) -> AgentAction {
    let summary = buildElementSnapshotSummary(element)
    let point = getElementCenterPoint(summary.bbox)
    let chosen = truncateLabel_2(chosenLabel, 40)
    let label = base.isError == true ? "Failed to select \"\(chosen)\" in \(summary.label)" : "Selected \"\(chosen)\" in \(summary.label)"
    return buildBaseAction(base, "List", label, point, kind: .select, data: .select(element: summary, chosenLabel: chosen))
}

public func buildScrollAction(_ base: ActionBuilderBase, element: ElementSnapshot) -> AgentAction {
    let summary = buildElementSnapshotSummary(element)
    let point = getElementCenterPoint(summary.bbox)
    let label = base.isError == true ? "Failed to scroll to \(summary.label)" : "Scrolled to \(summary.label)"
    return buildBaseAction(base, "ArrowDown", label, point, kind: .scroll, data: .element(summary))
}

public func buildHoverAction(_ base: ActionBuilderBase, element: ElementSnapshot) -> AgentAction {
    let summary = buildElementSnapshotSummary(element)
    let point = getElementCenterPoint(summary.bbox)
    let label = base.isError == true ? "Failed to hover \(summary.label)" : "Hovered \(summary.label)"
    return buildBaseAction(base, "MousePointer", label, point, kind: .hover, data: .element(summary))
}

public func buildPressKeysAction(_ base: ActionBuilderBase, keys: String) -> AgentAction {
    let summary = truncateLabel_2(keys, 40)
    let label = base.isError == true ? "Failed to send keys \"\(summary)\"" : "Pressed \(summary)"
    return buildBaseAction(base, "Keyboard", label, nil, kind: .press_keys, data: .pressKeys(keys: summary))
}

/// Builds a "navigate" action, redacting sensitive URL parts.
public func buildNavigateAction(_ base: ActionBuilderBase, url: String, previousUrl: String?, pageTitle: String?) -> AgentAction {
    let redactedUrl = redactSensitiveUrlParams(url)
    let redactedPrevious = previousUrl.map { redactSensitiveUrlParams($0) }
    var host = redactedUrl
    if let components = URLComponents(string: redactedUrl), let h = components.host {
        host = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
    let label = base.isError == true ? "Failed to navigate to \(host)" : "Navigated to \(host)"
    return buildBaseAction(base, "Globe", label, nil, kind: .navigate, data: .navigate(url: redactedUrl, previousUrl: redactedPrevious, pageTitle: pageTitle.map { truncateLabel_2($0) }))
}

public func buildUploadAction(_ base: ActionBuilderBase, element: ElementSnapshot, pathCount: Int) -> AgentAction {
    let summary = buildElementSnapshotSummary(element)
    let point = getElementCenterPoint(summary.bbox)
    let plural = pathCount == 1 ? "" : "s"
    let label = base.isError == true ? "Failed to upload \(pathCount) file\(plural) to \(summary.label)" : "Uploaded \(pathCount) file\(plural) to \(summary.label)"
    return buildBaseAction(base, "Upload", label, point, kind: .upload, data: .upload(element: summary, pathCount: pathCount))
}

public func buildStartAgentAction(_ base: ActionBuilderBase, agentId: String?, prompt: String) -> AgentAction {
    let preview = truncateLabel_2(prompt, 100)
    let label = base.isError == true ? "Failed to spawn sub-agent: \(preview)" : "Spawned sub-agent: \(preview)"
    return buildBaseAction(base, "Brain", label, nil, kind: .start_agent, data: .startAgent(agentId: agentId, prompt: preview))
}

public func buildSnapshotAction(_ base: ActionBuilderBase, reason: String?) -> AgentAction {
    buildBaseAction(base, "Eye", "Captured tab snapshot", nil, kind: .snapshot, data: .snapshot(reason: reason))
}

/// Serializes a recorded ``AgentAction`` into the JSON object the action
/// collector carries: the base fields, the `kind` discriminator, and the
/// per-kind `data` payload. Optional fields are omitted when absent.
public func agentActionJSValue(_ action: AgentAction) -> JSValue {
    var fields: [(String, JSValue)] = [
        ("iconName", .string(action.iconName)),
        ("label", .string(action.label)),
        ("kind", .string(action.kind.rawValue)),
    ]
    if let tabId = action.tabId { fields.append(("tabId", .string(tabId))) }
    if let xy = action.xy {
        fields.append(("xy", .object([("x", .number(xy.x)), ("y", .number(xy.y))])))
    }
    if let path = action.screenshotPath { fields.append(("screenshotPath", .string(path))) }
    if let startedAt = action.startedAt { fields.append(("startedAt", .number(startedAt))) }
    if let completedAt = action.completedAt { fields.append(("completedAt", .number(completedAt))) }
    if let isError = action.isError { fields.append(("isError", .bool(isError))) }
    if let errorMessage = action.errorMessage { fields.append(("errorMessage", .string(errorMessage))) }
    fields.append(("data", agentActionDataJSValue(action.data)))
    return .object(fields)
}

private func agentActionDataJSValue(_ data: AgentActionData) -> JSValue {
    switch data {
    case let .element(element):
        return .object([("element", elementSnapshotJSValue(element))])
    case let .type(element, textPreview, replace, redacted):
        var fields: [(String, JSValue)] = [
            ("element", elementSnapshotJSValue(element)),
            ("textPreview", .string(textPreview)),
            ("redacted", .bool(redacted)),
        ]
        if let replace { fields.append(("replace", .bool(replace))) }
        return .object(fields)
    case let .select(element, chosenLabel):
        return .object([
            ("element", elementSnapshotJSValue(element)),
            ("chosenLabel", .string(chosenLabel)),
        ])
    case let .pressKeys(keys):
        return .object([("keys", .string(keys))])
    case let .navigate(url, previousUrl, pageTitle):
        var fields: [(String, JSValue)] = [("url", .string(url))]
        if let previousUrl { fields.append(("previousUrl", .string(previousUrl))) }
        if let pageTitle { fields.append(("pageTitle", .string(pageTitle))) }
        return .object(fields)
    case let .upload(element, pathCount):
        return .object([
            ("element", elementSnapshotJSValue(element)),
            ("pathCount", .number(pathCount)),
        ])
    case let .startAgent(agentId, prompt):
        var fields: [(String, JSValue)] = [("prompt", .string(prompt))]
        if let agentId { fields.append(("agentId", .string(agentId))) }
        return .object(fields)
    case let .snapshot(reason):
        return .object(reason.map { [("reason", JSValue.string($0))] } ?? [])
    }
}

private func elementSnapshotJSValue(_ element: ElementSnapshot) -> JSValue {
    var fields: [(String, JSValue)] = [
        ("label", .string(element.label)),
        ("role", .string(element.role)),
        ("tagName", .string(element.tagName)),
        ("bbox", .object([
            ("x", .number(element.bbox.x)),
            ("y", .number(element.bbox.y)),
            ("width", .number(element.bbox.width)),
            ("height", .number(element.bbox.height)),
        ])),
    ]
    if let v = element.htmlId { fields.append(("htmlId", .string(v))) }
    if let v = element.name { fields.append(("name", .string(v))) }
    if let v = element.inViewport { fields.append(("inViewport", .bool(v))) }
    if let v = element.ariaLabel { fields.append(("ariaLabel", .string(v))) }
    if let v = element.title { fields.append(("title", .string(v))) }
    if let v = element.innerText { fields.append(("innerText", .string(v))) }
    if let v = element.altText { fields.append(("altText", .string(v))) }
    if let v = element.inputType { fields.append(("inputType", .string(v))) }
    if let v = element.placeholder { fields.append(("placeholder", .string(v))) }
    if let v = element.disabled { fields.append(("disabled", .bool(v))) }
    if let v = element.required { fields.append(("required", .bool(v))) }
    if let v = element.checked { fields.append(("checked", .bool(v))) }
    if let v = element.href { fields.append(("href", .string(v))) }
    if let v = element.pageUrl { fields.append(("pageUrl", .string(v))) }
    if let v = element.pageTitle { fields.append(("pageTitle", .string(v))) }
    if let v = element.frameUrl { fields.append(("frameUrl", .string(v))) }
    return .object(fields)
}

/// Generates a random hex action id.
public func generateActionId() -> String {
    var bytes = [UInt8](repeating: 0, count: 6)
    for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Small string helpers

func collapseWhitespace(_ text: String) -> String {
    let parts = text.split(whereSeparator: { $0.isWhitespace })
    return parts.joined(separator: " ")
}

func trimTrailingWhitespace(_ text: String) -> String {
    var end = text.endIndex
    while end > text.startIndex {
        let prev = text.index(before: end)
        if text[prev].isWhitespace { end = prev } else { break }
    }
    return String(text[text.startIndex..<end])
}

func matches(_ text: String, _ pattern: String, caseInsensitive: Bool = false) -> Bool {
    let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.firstMatch(in: text, options: [], range: range) != nil
}
