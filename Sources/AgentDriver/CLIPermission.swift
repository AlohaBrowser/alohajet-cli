import Foundation

// MARK: - Permissions

/// What a run lets the page use. The `allCases` order IS the wire order, so the
/// body a run sends never depends on the order the caller supplied.
///
/// Empty is the default and means "grant nothing". The set is written on EVERY
/// run, including the empty one, so a turn never silently inherits the grants of
/// the turn before it.
public enum CLIPermission: String, Sendable, CaseIterable {
    case camera
    case microphone
    case geolocation
    case storageAccess = "storage_access"
    case externalScheme = "external_scheme"
}
