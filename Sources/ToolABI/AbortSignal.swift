import Foundation

// MARK: - AbortSignalError

/// Signals an aborted operation. Its `name` is the DOM-style `"AbortError"` so
/// consumers can detect cancellation by name.
public final class AbortSignalError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let name: String

    public init(_ message: String) {
        self.message = message
        self.name = "AbortError"
    }

    public var description: String { message }
}

// MARK: - Logging shim

/// A minimal logger interface; ``noopLogger`` is its no-op implementation.
public protocol AbortChainLogger: Sendable {
    func info(_ message: String)
    func warn(_ message: String)
    func error(_ message: String)
    func debug(_ message: String)
}

public struct NoopAbortChainLogger: AbortChainLogger {
    public init() {}
    public func info(_ message: String) {}
    public func warn(_ message: String) {}
    public func error(_ message: String) {}
    public func debug(_ message: String) {}
}

public let noopLogger: AbortChainLogger = NoopAbortChainLogger()

// MARK: - Abort signal

/// A cancellation signal carrying an optional reason and one-shot abort
/// listeners, following `AbortSignal`-style semantics used throughout the agent
/// runtime's cancellation plumbing.
public final class AbortSignal {
    private var _aborted: Bool
    private var _reason: String?
    private var listeners: [Int: () -> Void] = [:]
    private var nextToken = 0

    public init(aborted: Bool = false, reason: String? = nil) {
        _aborted = aborted
        _reason = reason
    }

    public var aborted: Bool { return _aborted }
    public var reason: String? { return _reason }

    public func abort(_ reason: String?) {
        let handlers: [() -> Void]? = {
            if _aborted { return nil }
            _aborted = true
            _reason = reason
            let snapshot = Array(listeners.values)
            listeners.removeAll()
            return snapshot
        }()
        guard let handlers else { return }
        for handler in handlers { handler() }
    }

    /// Registers a one-shot abort listener, firing immediately if already
    /// aborted. Returns a token used to remove it.
    @discardableResult
    public func onAbort(_ handler: @escaping () -> Void) -> Int {
        if _aborted {
            handler()
            return -1
        }
        let token = nextToken
        nextToken += 1
        listeners[token] = handler
        return token
    }

    public func removeAbortListener(_ token: Int) {
        listeners.removeValue(forKey: token)
    }

    /// Suspends until the signal aborts (returning immediately if already
    /// aborted). The suspension also resolves when the awaiting task is
    /// cancelled, so a structured race that loses to another branch can unwind
    /// instead of leaking a permanently suspended child task.
    public func waitUntilAborted() async {
        let state = AbortWaitState()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let token = onAbort { state.resolve() }
                state.attach(continuation: continuation, remove: { [weak self] in self?.removeAbortListener(token) })
                if Task.isCancelled { state.resolve() }
            }
        } onCancel: {
            Task { @MainActor in state.resolve() }
        }
    }
}

/// Single-resolution coordinator for ``AbortSignal/waitUntilAborted()``. The
/// continuation is resumed exactly once, regardless of whether the abort
/// listener fires, the awaiting task is cancelled, or those events race the
/// continuation being installed.
private final class AbortWaitState {
    private var continuation: CheckedContinuation<Void, Never>?
    private var remove: (() -> Void)?
    private var attached = false
    private var resolved = false
    private var pendingResolve = false

    /// Records the continuation (and listener disposer). If a resolve already
    /// arrived before attachment, the continuation is resumed immediately.
    func attach(continuation: CheckedContinuation<Void, Never>, remove: @escaping () -> Void) {
        if resolved {
            remove()
            continuation.resume()
            return
        }
        self.continuation = continuation
        self.remove = remove
        attached = true
        if pendingResolve {
            self.continuation = nil
            resolved = true
            let disposer = self.remove
            disposer?()
            continuation.resume()
            return
        }
    }

    /// Resumes the continuation once. If it hasn't been attached yet the resolve
    /// is recorded and applied as soon as ``attach(continuation:remove:)`` runs.
    func resolve() {
        if resolved { return }
        if !attached {
            pendingResolve = true
            return
        }
        resolved = true
        let cont = continuation
        let disposer = remove
        continuation = nil
        disposer?()
        cont?.resume()
    }
}

public final class AbortController {
    public let signal: AbortSignal

    public init() {
        signal = AbortSignal()
    }

    public func abort(_ reason: String? = nil) {
        signal.abort(reason)
    }
}

// MARK: - Abort signal chaining / racing

/// Propagates an abort from `parent` to `child`. If the parent is already
/// aborted the child is aborted immediately; otherwise a one-shot listener is
/// installed. Returns a detach closure.
@discardableResult
public func chainAbortSignal(
    _ parent: AbortController,
    _ child: AbortController,
    _ logger: AbortChainLogger = noopLogger
) -> () -> Void {
    if parent.signal.aborted {
        logger.info("[chainSignal] Parent already aborted at chain time, aborting child immediately")
        child.abort(parent.signal.reason)
        return {}
    }
    let detached = AbortFlag()
    let token = parent.signal.onAbort {
        if detached.value { return }
        logger.info("[chainSignal] Parent signal aborted, propagating to child")
        child.abort(parent.signal.reason)
    }
    return {
        detached.value = true
        parent.signal.removeAbortListener(token)
        logger.info("[chainSignal] Detached child from parent signal")
    }
}

private final class AbortFlag {
    var value = false
}

/// Races `operation` against `controller`'s abort: throws ``AbortSignalError``
/// when the signal aborts (or is already aborted), otherwise returns the result.
public func raceAbort<T: Sendable>(
    _ controller: AbortController,
    _ operation: @escaping @MainActor @Sendable () async throws -> T
) async throws -> T {
    if controller.signal.aborted {
        throw AbortSignalError("Aborted")
    }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await controller.signal.waitUntilAborted()
            throw AbortSignalError("Aborted")
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw AbortSignalError("Aborted")
        }
        return result
    }
}

nonisolated public func isAbortError(_ error: Error) -> Bool {
    error is AbortSignalError
}

/// An error that names itself (DOM-style `name`), so a cancellation raised by
/// in-page JavaScript can be recognised by its `"AbortError"` name.
public protocol NamedError {
    nonisolated var name: String { get }
}
