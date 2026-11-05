import Foundation
#if canImport(Glibc)
import Glibc
#endif

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
    /// The suffix of a test process (`~/.alohajet-test`, `Aloha-test`, `alohajet-test-<uid>`).
    public static let testSuffix = "test"

    /// The app's ``dataSuffixKey``, nil for a shipped build; ``testSuffix`` in a test process.
    public static let dataSuffix = dataSuffix(info: appInfo(), isTestProcess: isTestProcess)

    /// XCTest or Swift Testing is loaded: `swift test`'s `xctest` and
    /// `swiftpm-testing-helper`. No shipped binary links either; the environment could be
    /// set on any launch, so it is no signal. Looked up by name: XCTest's `XCTestCase`
    /// class, Swift Testing's C entry point (`swt_abiv0_getEntryPoint`, the one SwiftPM's
    /// runner resolves). On Linux, where corelibs has no `XCTestCase` by that name and
    /// glibc's `RTLD_DEFAULT` is null, the entry point alone: `swift test` links Swift
    /// Testing into the one test executable, so the Linux job's run is `test` too.
    public static let isTestProcess: Bool = {
        #if canImport(Darwin)
        NSClassFromString("XCTestCase") != nil
            || dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swt_abiv0_getEntryPoint") != nil  // RTLD_DEFAULT
        #elseif canImport(Glibc)
        dlsym(nil, "swt_abiv0_getEntryPoint") != nil  // RTLD_DEFAULT
        #else
        false
        #endif
    }()

    /// `base`, or `base-<suffix>` for an app with a data suffix: `.alohajet-e2e`, `Aloha-e2e`.
    public static func name(_ base: String, suffix: String? = dataSuffix) -> String {
        suffix.map { "\(base)-\($0)" } ?? base
    }

    /// The app's loopback port for a shipped build's `base` (automation 8765, CDP 9222): `base`
    /// for a shipped build, `base + 100` for an app with a data suffix (jet-e2e: 8865, 9322),
    /// `base + 200` for a test process (8965, 9422). The desktop applies the same rule to the
    /// same suffix (`IdentityPorts`), so this CLI finds ITS app, and the user's AlohaJet CLI
    /// (`alohajet mcp --endpoint http://127.0.0.1:8765` in Claude Desktop) never meets an e2e
    /// build or a test's listener.
    public static func port(_ base: Int, suffix: String? = dataSuffix) -> Int {
        guard let suffix else { return base }
        return base + (suffix == testSuffix ? 200 : 100)
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

    /// A test process is ``testSuffix`` whatever app it drives; else the app's own.
    static func dataSuffix(info: [String: Any]?, isTestProcess: Bool) -> String? {
        isTestProcess ? testSuffix : dataSuffix(info: info)
    }

    /// The empty string an XcodeGen substitution leaves for a shipped build is no suffix.
    static func dataSuffix(info: [String: Any]?) -> String? {
        let value = (info?[dataSuffixKey] as? String)?.trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }
}
