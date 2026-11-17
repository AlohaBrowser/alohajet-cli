import Testing
import Foundation
@testable import CDP

/// Gate for the Chrome arguments `ChromeLauncher` derives from the environment.
///
/// Hermetic: `environmentArguments` is a pure function of the environment it is handed, so
/// no Chrome is launched and the process's own environment is never read.
@Suite struct ChromeLauncherEnvironmentArgumentsTests {

    @Test func anEmptyEnvironmentAddsNothing() throws {
        #expect(try ChromeLauncher.environmentArguments([:]) == [])
        #expect(try ChromeLauncher.environmentArguments([
            "ALOHAJET_CHROME_USER_AGENT": "", "ALOHAJET_CHROME_PROXY": "", "ALOHAJET_CHROME_MEDIA": "0",
        ]) == [])
    }

    @Test func theUserAgentIsPassedThrough() throws {
        #expect(try ChromeLauncher.environmentArguments(["ALOHAJET_CHROME_USER_AGENT": "Safari/605"])
            == ["--user-agent=Safari/605"])
    }

    @Test(arguments: ["10.0.0.1:3128", "proxy.example:8080", "http://10.0.0.1:3128", "socks5://10.0.0.1:1080"])
    func aProxyAddressBecomesProxyServer(_ proxy: String) throws {
        #expect(try ChromeLauncher.environmentArguments(["ALOHAJET_CHROME_PROXY": proxy])
            == ["--proxy-server=\(proxy)"])
    }

    @Test(arguments: ["user:pw@10.0.0.1:3128", "http://user:pw@10.0.0.1:3128", "10.0.0.1", "10.0.0.1:3128 --no-sandbox", "ftp://10.0.0.1:21"])
    func aProxyWithCredentialsOrJunkIsRefused(_ proxy: String) {
        #expect(throws: CDPError.self) {
            try ChromeLauncher.environmentArguments(["ALOHAJET_CHROME_PROXY": proxy])
        }
    }

    @Test func mediaModePlaysWithNoGestureAndNoAudioDevice() throws {
        #expect(try ChromeLauncher.environmentArguments(["ALOHAJET_CHROME_MEDIA": "1"])
            == ["--autoplay-policy=no-user-gesture-required", "--disable-audio-output"])
    }

    @Test func allThreeComeOutInAFixedOrder() throws {
        #expect(try ChromeLauncher.environmentArguments([
            "ALOHAJET_CHROME_MEDIA": "1", "ALOHAJET_CHROME_PROXY": "10.0.0.1:3128", "ALOHAJET_CHROME_USER_AGENT": "UA",
        ]) == ["--user-agent=UA", "--proxy-server=10.0.0.1:3128",
               "--autoplay-policy=no-user-gesture-required", "--disable-audio-output"])
    }
}
