import Foundation
import Testing

@Suite("the binary under test")
struct BinaryUnderTestTests {

    // A build with `--scratch-path` used to find no binary at all, failing every CLI case;
    // one that also had a stale `<package>/.build` tested THAT binary instead of this build's.
    @Test("the CLI under test is the one built beside this test product")
    func binaryIsThisBuildsProduct() throws {
        guard (ProcessInfo.processInfo.environment["ALOHAJET_BIN"] ?? "").isEmpty else { return }
        let binary = try #require(alohajetBinary, "no alohajet binary beside the test product")
        let products = try #require(testProductsDirectory)
        #expect(URL(fileURLWithPath: binary).deletingLastPathComponent().standardizedFileURL
                == products.standardizedFileURL)
    }
}
