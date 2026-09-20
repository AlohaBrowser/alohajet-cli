import Foundation

/// P0.1 — "never enter credentials itself": the refusal a type/fill action
/// returns when its target is classified as a password/credential field.
public let credentialFieldRefusalMessage =
    "refusing to type into a credential field; ask the user to enter it"



/// Master switch for the P0.1 credential guard. DISABLED by default: the agent
/// may type credentials itself, so autonomous logins work with no extra setup.
/// Set `ALOHAJET_CREDENTIAL_GUARD=1` (or true/yes/on) to refuse credential
/// fields and hand entry to the user. Read via `getenv` so a test's `setenv`
/// is observed immediately.
public func credentialGuardEnabled() -> Bool {
    guard let raw = getenv("ALOHAJET_CREDENTIAL_GUARD") else { return false }
    switch String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on": return true
    default: return false
    }
}
