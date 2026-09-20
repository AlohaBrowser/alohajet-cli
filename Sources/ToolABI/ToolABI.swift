import Foundation

// MARK: - Tool result / session abstractions

public enum ToolResultStatus: String, Sendable, Equatable {
    case running
    case complete
    case error
    case stopped
}

/// A finished tool execution result surfaced to the chat loop.
public struct ExecutedToolResult: Sendable, Equatable {
    public var toolCallId: String
    public var output: String
    public var isError: Bool?
    public var status: ToolResultStatus
    public var metadata: [String: WorkflowValue]?

    public init(toolCallId: String, output: String, isError: Bool? = nil, status: ToolResultStatus, metadata: [String: WorkflowValue]? = nil) {
        self.toolCallId = toolCallId
        self.output = output
        self.isError = isError
        self.status = status
        self.metadata = metadata
    }
}

public struct ToolCall: Sendable, Equatable {
    public var toolName: String
    public var toolCallId: String
    public var input: WorkflowValue?

    public init(toolName: String, toolCallId: String, input: WorkflowValue? = nil) {
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.input = input
    }
}

/// The snapshot-bearing tool metadata persisted alongside a tool result. Only
/// the workflow snapshot slot is modeled directly; other keys round-trip as raw
/// values.
public typealias ToolMetadata = [String: WorkflowValue]

// MARK: - Tool execution context & protocols

public enum ToolMode: String, Sendable, Equatable {
    case foreground
    case background
}

/// The result a tool's `execute` returns before formatting.
public struct RawToolResult: Sendable {
    public var output: String
    public var isError: Bool?
    public var status: ToolResultStatus?
    public var metadata: ToolMetadata?
    public var llmAttrs: [String]?
    public var format: String?
    public var outputSchema: String?
    /// Image blocks the tool produced alongside its text — a `manage_tabs`
    /// viewport screenshot is the only producer today. A host that can carry
    /// pixels renders them (MCP: one `{type:"image",data,mimeType}` block per
    /// entry); a text-only front end ignores the array. Empty unless the call
    /// asked for a screenshot, so the common path allocates nothing.
    public var images: [ParsedDataUrlImage]

    public init(output: String, isError: Bool? = nil, status: ToolResultStatus? = nil, metadata: ToolMetadata? = nil, llmAttrs: [String]? = nil, format: String? = nil, outputSchema: String? = nil, images: [ParsedDataUrlImage] = []) {
        self.output = output
        self.isError = isError
        self.status = status
        self.metadata = metadata
        self.llmAttrs = llmAttrs
        self.format = format
        self.outputSchema = outputSchema
        self.images = images
    }
}

public struct ToolResultFormatContext: Sendable {
    public var sessionId: String
    /// The session's storage key — the path the session persists under, and the key a
    /// host's feedback bus routes a suspended tool's answer back through. It equals
    /// `sessionId` for a top-level session; a sub-agent's is `<parent key>/agents/<id>`,
    /// and stripping that suffix is what finds the owning chat loop. Empty by default:
    /// nothing in this package routes feedback, so the field is carried, not read.
    public var sessionKey: String
    /// The chat session this call belongs to, when there is one — the same id a tab is
    /// stamped with (``AgentControllableTab/chatSessionId``). `nil` off a chat.
    public var chatSessionId: String?
    public var toolCallId: String
    public init(sessionId: String, sessionKey: String = "", chatSessionId: String? = nil, toolCallId: String) {
        self.sessionId = sessionId
        self.sessionKey = sessionKey
        self.chatSessionId = chatSessionId
        self.toolCallId = toolCallId
    }
}

/// An executable tool. `executeGroup` opts the tool into grouped/batched
/// execution; `formatResult` lets the tool render its own output.
public protocol ExecutorTool: AnyObject, Sendable {
    var name: String { get }
    var initialResultMetadata: ToolMetadata? { get }
    var supportsGroupExecution: Bool { get }

    func execute(_ input: WorkflowValue?, _ context: ToolExecutionContext) async throws -> RawToolResult
    func executeGroup(_ calls: [ToolCall], _ context: ToolExecutionContext) async throws
    func formatResult(_ output: String, _ metadata: ToolMetadata?, _ context: ToolResultFormatContext) -> String?
}

public extension ExecutorTool {
    var initialResultMetadata: ToolMetadata? { nil }
    var supportsGroupExecution: Bool { false }
    func executeGroup(_ calls: [ToolCall], _ context: ToolExecutionContext) async throws {}
    func formatResult(_ output: String, _ metadata: ToolMetadata?, _ context: ToolResultFormatContext) -> String? { nil }
}

public nonisolated struct ToolResultBlockView: Sendable {
    public var output: String
    public var status: ToolResultStatus?
    public var metadata: ToolMetadata?
    public init(output: String, status: ToolResultStatus?, metadata: ToolMetadata?) {
        self.output = output
        self.status = status
        self.metadata = metadata
    }
}

public nonisolated struct ToolResultUpdate: Sendable {
    public var output: String?
    public var status: ToolResultStatus?
    public var metadata: ToolMetadata?
    public init(output: String? = nil, status: ToolResultStatus? = nil, metadata: ToolMetadata? = nil) {
        self.output = output
        self.status = status
        self.metadata = metadata
    }
}

public struct AgentRecord: Sendable {
    public var parentToolCallId: String?
    public var status: String
    public init(parentToolCallId: String?, status: String) {
        self.parentToolCallId = parentToolCallId
        self.status = status
    }
}

/// The chat-session surface the executor mutates.
public protocol ExecutorSession: AnyObject, Sendable {
    func findToolResult(_ toolCallId: String) -> ToolResultBlockView?
    func updateToolCallResult(_ toolCallId: String, _ update: ToolResultUpdate)
    func emitMessagesUpdated(_ messageId: String?)
    func createToolMessageGroup(_ call: ToolCall, output: String, status: ToolResultStatus, metadata: ToolMetadata?, toolType: String) async -> String
    var agents: [String: AgentRecord] { get }
    func detachAgent(_ agentId: String)
    func save()
}

public extension ExecutorSession {
    func emitMessagesUpdated() { emitMessagesUpdated(nil) }
}

/// A sandbox the executor writes full tool outputs to.
public protocol ToolSandbox: AnyObject, Sendable {
    func writeFile(_ path: String, _ contents: String) async throws
}

/// The context handed to a tool's `execute`.
public final class ToolExecutionContext {
    public let sessionId: String
    /// See ``ToolResultFormatContext/sessionKey``.
    public let sessionKey: String
    /// See ``ToolResultFormatContext/chatSessionId``.
    public let chatSessionId: String?
    public let toolCallId: String
    public let signal: AbortSignal
    public let mode: ToolMode
    public let turnId: String?
    public let session: ExecutorSession
    public let isBackground: @MainActor @Sendable () -> Bool
    private let getSandbox: @MainActor @Sendable () -> ToolSandbox?
    public let env: [String: String]
    public let services: NativeToolServices?
    private let suspendHandler: @MainActor @Sendable (WorkflowValue?) async throws -> WorkflowValue?
    /// Mid-execution status sink: invoked on every ``updateToolResult`` (BEFORE the tool's
    /// final result), carrying the tool-call id and the update. Lets a host observe a tool
    /// that has entered `waiting_feedback` / `needs_permission` mid-run — the only signal
    /// for a permission prompt, since the final-result sink (`onToolResult`) fires only
    /// after the tool returns and a suspended tool has not returned. Optional; default nil.
    private let onStatusUpdate: (@MainActor @Sendable (String, ToolResultUpdate) -> Void)?

    public var sandbox: ToolSandbox? { getSandbox() }

    public init(
        sessionId: String,
        sessionKey: String = "",
        chatSessionId: String? = nil,
        toolCallId: String,
        signal: AbortSignal,
        mode: ToolMode,
        turnId: String?,
        session: ExecutorSession,
        isBackground: @escaping @MainActor @Sendable () -> Bool,
        getSandbox: @escaping @MainActor @Sendable () -> ToolSandbox?,
        env: [String: String],
        services: NativeToolServices? = nil,
        suspend: @escaping @MainActor @Sendable (WorkflowValue?) async throws -> WorkflowValue?,
        onStatusUpdate: (@MainActor @Sendable (String, ToolResultUpdate) -> Void)? = nil
    ) {
        self.sessionId = sessionId
        self.sessionKey = sessionKey
        self.chatSessionId = chatSessionId
        self.toolCallId = toolCallId
        self.signal = signal
        self.mode = mode
        self.turnId = turnId
        self.session = session
        self.isBackground = isBackground
        self.getSandbox = getSandbox
        self.env = env
        self.services = services
        self.suspendHandler = suspend
        self.onStatusUpdate = onStatusUpdate
    }

    public func suspend(_ state: WorkflowValue?) async throws -> WorkflowValue? {
        try await suspendHandler(state)
    }

    public func updateToolResult(output: String?, status: ToolResultStatus?, metadata: ToolMetadata?) {
        let existing = session.findToolResult(toolCallId)?.metadata
        let merged = metadata.map { (existing ?? [:]).merging($0) { _, incoming in incoming } } ?? existing
        let update = ToolResultUpdate(output: output, status: status, metadata: merged)
        session.updateToolCallResult(toolCallId, update)
        // Surface the mid-execution update to any observer BEFORE persistence/notify, so a
        // host can react to a `needs_permission` status the instant the tool raises it.
        onStatusUpdate?(toolCallId, update)
        session.save()
        session.emitMessagesUpdated()
    }
}

/// Parameters needed to construct a tool execution context, mirroring the loose
/// option bag the runtime passes through.
public struct ToolContextParams {
    public var sessionId: String
    public var toolCallId: String
    public var signal: AbortSignal
    public var mode: ToolMode
    public var turnId: String?
    public var session: ExecutorSession
    public var isBackground: (@MainActor @Sendable () -> Bool)?
    public var getSandbox: @MainActor @Sendable () -> ToolSandbox?
    public var env: [String: String]
    public var services: NativeToolServices?
    public var suspend: @MainActor @Sendable (WorkflowValue?) async throws -> WorkflowValue?
    public var onStatusUpdate: (@MainActor @Sendable (String, ToolResultUpdate) -> Void)?

    public init(
        sessionId: String,
        toolCallId: String,
        signal: AbortSignal,
        mode: ToolMode,
        turnId: String?,
        session: ExecutorSession,
        isBackground: (@MainActor @Sendable () -> Bool)? = nil,
        getSandbox: @escaping @MainActor @Sendable () -> ToolSandbox?,
        env: [String: String],
        services: NativeToolServices? = nil,
        suspend: @escaping @MainActor @Sendable (WorkflowValue?) async throws -> WorkflowValue?,
        onStatusUpdate: (@MainActor @Sendable (String, ToolResultUpdate) -> Void)? = nil
    ) {
        self.sessionId = sessionId
        self.toolCallId = toolCallId
        self.signal = signal
        self.mode = mode
        self.turnId = turnId
        self.session = session
        self.isBackground = isBackground
        self.getSandbox = getSandbox
        self.env = env
        self.services = services
        self.suspend = suspend
        self.onStatusUpdate = onStatusUpdate
    }
}

public func createToolContext(_ params: ToolContextParams) -> ToolExecutionContext {
    let mode = params.mode
    let isBackground: @MainActor @Sendable () -> Bool = params.isBackground ?? { mode == .background }
    return ToolExecutionContext(
        sessionId: params.sessionId,
        toolCallId: params.toolCallId,
        signal: params.signal,
        mode: params.mode,
        turnId: params.turnId,
        session: params.session,
        isBackground: isBackground,
        getSandbox: params.getSandbox,
        env: params.env,
        services: params.services,
        suspend: params.suspend,
        onStatusUpdate: params.onStatusUpdate
    )
}

