import Foundation

/// The seam behind `alohajet -p <prompt>`: one logical command that runs
/// identically over every backend. Every backend returns the SAME `CLIRunResult`,
/// so the executable's `encodedJSON()` / exit-code contract is identical whichever
/// one ran.
///
/// This package ships exactly ONE implementation, `RemoteAutomationDriver`: the
/// agent loop is reached over HTTP, never linked. A host that owns an in-process
/// loop conforms its own driver to this protocol and gets the same contract for
/// free — that is the whole point of the seam, and why it is a protocol here
/// rather than a concrete type.
///
/// `runTask` is the ONLY verb. There is deliberately no prompt-independent state
/// on it and no second verb: a verb without a reachable endpoint is a stub, and
/// stubs are what this seam exists to avoid.
public protocol AlohaJetDriver: Sendable {
    /// Run ONE task to a terminal `CLIRunResult`.
    func runTask(prompt: String) async throws -> CLIRunResult
}
