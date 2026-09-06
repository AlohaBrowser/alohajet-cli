import Foundation

/// P0.1 — "never enter credentials itself": the refusal a type/fill action
/// returns when its target is classified as a password/credential field. The
/// agent hands credential entry back to the human rather than typing it.
let credentialFieldRefusalMessage =
    "refusing to type into a credential field; ask the user to enter it"



/// Master switch for the P0.1 credential guard — BOTH the refusal to type into a
/// password/credential field AND the human hand-off that refusal drives (the
/// "ask the user to enter it" message the model acts on). DISABLED by default:
/// the agent may type credentials itself, so autonomous logins work with no extra
/// setup. Set `ALOHAJET_CREDENTIAL_GUARD=1` (or true/yes/on) to turn the guard
/// back ON — refuse password/credential fields outright and hand entry to the
/// user. Read via `getenv` so a test's `setenv` is observed immediately.
func credentialGuardEnabled() -> Bool {
    guard let raw = getenv("ALOHAJET_CREDENTIAL_GUARD") else { return false }
    switch String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on": return true
    default: return false
    }
}
