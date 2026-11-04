import Foundation

// MARK: - Which identity the app this CLI drives has
//
// The desktop builds one product under more than one identity: AlohaJet
// (`com.alohabrowser.alohajet`, `alohajet://`) and a copy of it for e2e runs
// (`ALOHA_VARIANT=jet-e2e`: `com.alohabrowser.alohajet.e2e`, `alohajet-e2e://`, its own
// `~/.alohajet-e2e` and `Application Support/Aloha-e2e`). The CLI it bundles must attach
// through ITS app's scheme and read ITS app's token, never the user's AlohaJet's — so both
// are read from the Info.plist of the bundle ``AlohaAppLauncher/appBundlePath(environment:)``
// names, with the shipped values when there is none (a `swift build` product).

public nonisolated enum HostAppIdentity {
    /// The scheme a shipped app claims `attach` under.
    public static let defaultCLIScheme = "alohajet"
    /// `CFBundleURLName` of the app's URL type for this CLI (`project.yml`).
    static let cliURLTypeName = "com.alohabrowser.cli"
    /// The app's Info.plist key naming its own data locations (alohajet's `DataSuffix`).
    static let dataSuffixKey = "AlohaDataSuffix"

    /// The scheme of the app's ``cliURLTypeName`` URL type.
    public static let cliScheme = cliScheme(info: appInfo())
    /// The app's ``dataSuffixKey``, nil for a shipped build.
    public static let dataSuffix = dataSuffix(info: appInfo())

    /// `base`, or `base-<suffix>` for an app with a data suffix: `.alohajet-e2e`, `Aloha-e2e`.
    public static func name(_ base: String, suffix: String? = dataSuffix) -> String {
        suffix.map { "\(base)-\($0)" } ?? base
    }

    static func appInfo(app: String? = AlohaAppLauncher.appBundlePath()) -> [String: Any]? {
        guard let app,
              let data = FileManager.default.contents(atPath: app + "/Contents/Info.plist")
        else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func cliScheme(info: [String: Any]?) -> String {
        let types = info?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = types.first { $0["CFBundleURLName"] as? String == cliURLTypeName }?["CFBundleURLSchemes"]
        return (schemes as? [String])?.first.flatMap { $0.isEmpty ? nil : $0 } ?? defaultCLIScheme
    }

    /// The empty string an XcodeGen substitution leaves for a shipped build is no suffix.
    static func dataSuffix(info: [String: Any]?) -> String? {
        let value = (info?[dataSuffixKey] as? String)?.trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }
}
