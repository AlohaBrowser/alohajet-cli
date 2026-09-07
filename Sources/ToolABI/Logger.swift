import Foundation

// MARK: - Logging shim
//
// The extracted modules were written against a logging façade that no longer
// travels: two globals, `agentLogger` and `rootLogger`, whose `debug` / `info` /
// `warn` / `error` take a variadic argument list, both main-actor isolated. This
// file reproduces that shape and that isolation, so every copied call site —
// including the ones that write `await rootLogger.info(…)` from an off-main
// context — reads exactly as it did, over stderr.
//
// Output is off unless `ALOHAJET_DEBUG` is set to something other than `0`,
// `false` or `no`. Nothing here reaches the network.

public nonisolated struct ShimLogger: Sendable {
    private let scope: String

    public init(scope: String) { self.scope = scope }

    public func debug(_ parts: String...) { emit("DEBUG", parts) }
    public func info(_ parts: String...) { emit("INFO", parts) }
    public func warn(_ parts: String...) { emit("WARN", parts) }
    public func error(_ parts: String...) { emit("ERROR", parts) }

    private func emit(_ level: String, _ parts: [String]) {
        guard ShimLogger.enabled else { return }
        // Not `fputs(…, stderr)` and not `FileHandle.standardError.write` — see
        // `StandardStreams.swift` for why each of those is wrong on Linux.
        writeToStandardError("[\(scope)] \(level) \(parts.joined(separator: " "))\n")
    }

    private static let enabled: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["ALOHAJET_DEBUG"] else { return false }
        return !["", "0", "false", "no"].contains(raw.lowercased())
    }()
}

@MainActor public let agentLogger = ShimLogger(scope: "agent")
@MainActor public let rootLogger = ShimLogger(scope: "alohajet")

/// Copied from the logging module the shim replaces: `CDP.swift` truncates every
/// outbound command payload through it.
public nonisolated func truncateString(_ value: String, limit: Int) -> String {
    if value.count <= limit { return value }
    let head = String(value.prefix(limit))
    return "\(head)… [truncated \(value.count - limit) chars]"
}

public nonisolated enum AgentLogLevel: String, Sendable {
    case debug, info, warn, error
}

/// The free-function form of the shim, for the call sites that were rewritten
/// away from the `rootLogger.warn(…)` façade during extraction.
public nonisolated func agentLog(_ level: AgentLogLevel, _ message: String) {
    ShimLogger(scope: "agent").log(level, message)
}

extension ShimLogger {
    fileprivate nonisolated func log(_ level: AgentLogLevel, _ message: String) {
        switch level {
        case .debug: debug(message)
        case .info: info(message)
        case .warn: warn(message)
        case .error: error(message)
        }
    }
}
