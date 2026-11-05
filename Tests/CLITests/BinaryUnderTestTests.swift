import Foundation
import Testing

/// The binary every CLI case runs is the one THIS build linked beside its test bundle,
/// wherever `--scratch-path` put the build, and a missing or stale one is a failure.
@Suite struct BinaryUnderTestTests {
    /// Without `ALOHAJET_BIN`, the binary under test sits in this test bundle's products
    /// directory, not in `<package>/.build/debug`.
    @Test func thisRunsBinaryIsItsOwnBuilds() throws {
        let binary = try alohajetBinary.get()
        guard ProcessInfo.processInfo.environment["ALOHAJET_BIN"]?.isEmpty ?? true else { return }
        let image = URL(fileURLWithPath: try #require(testImagePath())).resolvingSymlinksInPath().path
        let products = URL(fileURLWithPath: binary).deletingLastPathComponent().path + "/"
        #expect(image.hasPrefix(products), "\(binary) is not beside the test image \(image)")
    }

    /// macOS: the bundle's executable; Linux: the `.xctest` executable itself.
    @Test(arguments: ["alohajetPackageTests.xctest/Contents/MacOS/alohajetPackageTests",
                      "alohajetPackageTests.xctest"])
    func theBuildsOwnFreshBinaryOrAFailure(_ imageInProducts: String) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("alohajet-bin-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let products = root.appendingPathComponent("scratch/arm64-apple-macosx/debug")
        let sources = root.appendingPathComponent("Sources")
        let source = sources.appendingPathComponent("alohajet/main.swift")
        let binary = products.appendingPathComponent("alohajet")
        try fm.createDirectory(at: products, withIntermediateDirectories: true)
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: source)
        func resolve(_ override: String? = nil) throws -> String {
            let resolved = try resolveAlohajetBinary(
                override: override, testImage: products.appendingPathComponent(imageInProducts).path,
                sources: sources)
            return URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path  // `/private/var` is `/var`
        }

        #expect(throws: BinaryUnderTestError.self, "no binary") { try resolve() }

        #expect(fm.createFile(atPath: binary.path, contents: Data(), attributes: [.posixPermissions: 0o755]))
        let built = binary.resolvingSymlinksInPath().path
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: source.path)
        #expect(try resolve() == built)

        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: source.path)
        #expect(throws: BinaryUnderTestError.self, "a source saved after the link, never compiled") { try resolve() }

        // Compiled since (its `<name>.d` is newer) but not relinked: saved without a change.
        let dependencies = products.appendingPathComponent("alohajet_cli.build/main.d")
        try fm.createDirectory(at: dependencies.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(fm.createFile(atPath: dependencies.path, contents: Data()))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: dependencies.path)
        #expect(try resolve() == built)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 180)], ofItemAtPath: source.path)
        #expect(throws: BinaryUnderTestError.self, "saved again after that compile") { try resolve() }

        // `ALOHAJET_BIN` is taken as named — a packaged binary need not be newer — but must exist.
        #expect(try resolve(binary.path) == built)
        #expect(throws: BinaryUnderTestError.self) { try resolve(root.appendingPathComponent("none").path) }
    }
}
