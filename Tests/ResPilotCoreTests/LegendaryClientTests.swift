import CryptoKit
import Foundation
import Testing
@testable import ResPilotCore

@Suite struct LegendaryClientTests {
    private func makeInstalledClient() -> (client: LegendaryClient, dir: URL, runner: FakeProcessRunner) {
        let dir = Fixtures.makeTempDirectory("legendary-run")
        let binaryURL = Fixtures.writeFile(dir.appendingPathComponent("legendary"), executable: true)
        let runner = FakeProcessRunner()
        let client = LegendaryClient(processRunner: runner, binaryURL: binaryURL)
        return (client, dir, runner)
    }

    @Test func installDownloadsVerifiesExtractsAndMarksExecutable() async throws {
        let dir = Fixtures.makeTempDirectory("legendary-install")
        defer { try? FileManager.default.removeItem(at: dir) }
        let binaryURL = dir.appendingPathComponent("legendary")
        let downloader = FakeFileDownloader()
        downloader.data = Data("fake-legendary-zip-bytes".utf8)
        let expectedSHA = SHA256.hash(data: downloader.data).map { String(format: "%02x", $0) }.joined()

        let runner = FakeProcessRunner()
        runner.resultProvider = { invocation in
            if invocation.executable == "/usr/bin/ditto" {
                // Simulate a real extraction landing the expected binary —
                // the fake never actually runs `ditto`.
                let extractDir = URL(fileURLWithPath: invocation.arguments.last!, isDirectory: true)
                Fixtures.writeFile(extractDir.appendingPathComponent("legendary"), executable: false)
            }
            return nil // fall back to defaultResult (exit 0)
        }
        let client = LegendaryClient(processRunner: runner, downloader: downloader, binaryURL: binaryURL)

        let path = try await client.install(sha256: expectedSHA)

        #expect(path == binaryURL.path)
        #expect(client.isInstalled)
        #expect(downloader.requestedURLs == [LegendaryClient.defaultDownloadURL])
        #expect(runner.invocations.count == 2) // ditto extract + xattr clear
        #expect(runner.invocations[0].executable == "/usr/bin/ditto")
        #expect(runner.invocations[0].arguments.first == "-x")
        #expect(runner.invocations[0].arguments[1] == "-k")
        #expect(runner.invocations[0].timeout == 60)
        #expect(runner.invocations[1].executable == "/usr/bin/xattr")
        #expect(runner.invocations[1].arguments == ["-cr", binaryURL.path])
        let permissions = try FileManager.default.attributesOfItem(atPath: binaryURL.path)[.posixPermissions] as? Int
        #expect((permissions ?? 0) & 0o111 != 0) // executable bit set — the zip itself doesn't carry it
    }

    @Test func installIsANoOpWhenAlreadyInstalled() async throws {
        let dir = Fixtures.makeTempDirectory("legendary-already")
        defer { try? FileManager.default.removeItem(at: dir) }
        let binaryURL = Fixtures.writeFile(dir.appendingPathComponent("legendary"), executable: true)
        let downloader = FakeFileDownloader()
        let runner = FakeProcessRunner()
        let client = LegendaryClient(processRunner: runner, downloader: downloader, binaryURL: binaryURL)

        let path = try await client.install()

        #expect(path == binaryURL.path)
        #expect(downloader.requestedURLs.isEmpty) // never touches the network once already installed
        #expect(runner.invocations.isEmpty)
    }

    @Test func installThrowsOnChecksumMismatch() async {
        let dir = Fixtures.makeTempDirectory("legendary-checksum")
        defer { try? FileManager.default.removeItem(at: dir) }
        let binaryURL = dir.appendingPathComponent("legendary")
        let downloader = FakeFileDownloader()
        downloader.data = Data("not-the-real-zip".utf8)
        let runner = FakeProcessRunner()
        let client = LegendaryClient(processRunner: runner, downloader: downloader, binaryURL: binaryURL)
        let bogusSHA = String(repeating: "0", count: 64)

        await #expect(throws: LegendaryClientError.self) {
            try await client.install(sha256: bogusSHA)
        }
        #expect(runner.invocations.isEmpty)
        #expect(!client.isInstalled)
    }

    @Test func loginPassesCodeAndDisablesWebview() throws {
        let (client, dir, runner) = makeInstalledClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        try client.login(code: "ABC123")

        #expect(runner.invocations.count == 1)
        let call = try #require(runner.invocations.first)
        #expect(call.arguments == ["auth", "--code", "ABC123", "--disable-webview"])
        #expect(call.timeout == 120)
    }

    @Test func accountNameParsesLoggedInAndLoggedOut() throws {
        let (client, dir, runner) = makeInstalledClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        runner.defaultResult = ProcessResult(exitCode: 0, stdout: #"{"account": "TestUser", "epic_id": "abc123"}"#, stderr: "")
        #expect(try client.accountName() == "TestUser")

        runner.defaultResult = ProcessResult(exitCode: 0, stdout: #"{"account": "<not logged in>"}"#, stderr: "")
        #expect(try client.accountName() == nil)
    }

    @Test func listGamesMergesOwnedAndInstalled() throws {
        let (client, dir, runner) = makeInstalledClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ownedJSON = #"""
        [
          {"app_name": "app1", "app_title": "Zeta Game"},
          {"app_name": "app2", "app_title": "Alpha Game"}
        ]
        """#
        let installedJSON = #"""
        [
          {"app_name": "app2", "title": "Alpha Game", "install_path": "/Games/Epic/AlphaGame"}
        ]
        """#
        runner.resultProvider = { invocation in
            if invocation.arguments.first == "list" {
                return ProcessResult(exitCode: 0, stdout: ownedJSON, stderr: "")
            }
            if invocation.arguments.first == "list-installed" {
                return ProcessResult(exitCode: 0, stdout: installedJSON, stderr: "")
            }
            return nil
        }

        let games = try client.listGames()

        // Sorted by title: "Alpha Game" before "Zeta Game".
        #expect(games.map(\.appName) == ["app2", "app1"])
        #expect(games.first(where: { $0.appName == "app2" })?.installPath == "/Games/Epic/AlphaGame")
        #expect(games.first(where: { $0.appName == "app1" })?.installPath == nil)

        #expect(runner.invocations.count == 2)
        let ownedCall = try #require(runner.invocations.first { $0.arguments.first == "list" })
        #expect(ownedCall.arguments == ["list", "--platform", "Windows", "--json"])
        #expect(ownedCall.timeout == 300)
        let installedCall = try #require(runner.invocations.first { $0.arguments.first == "list-installed" })
        #expect(installedCall.arguments == ["list-installed", "--json", "--show-dirs"])
        #expect(installedCall.timeout == 120)
    }

    @Test func listGamesTreatsFailedListInstalledAsEmpty() throws {
        let (client, dir, runner) = makeInstalledClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ownedJSON = #"""
        [{"app_name": "app1", "app_title": "Solo Game"}]
        """#
        runner.resultProvider = { invocation in
            if invocation.arguments.first == "list" {
                return ProcessResult(exitCode: 0, stdout: ownedJSON, stderr: "")
            }
            if invocation.arguments.first == "list-installed" {
                return ProcessResult(exitCode: 1, stdout: "", stderr: "no installed games")
            }
            return nil
        }

        let games = try client.listGames()

        #expect(games.count == 1)
        #expect(games.first?.appName == "app1")
        #expect(games.first?.installPath == nil)
    }

    @Test func installGameArgvAndProgressStreaming() throws {
        let (client, dir, runner) = makeInstalledClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        runner.streamLines = ["Progress: 10%", "Progress: 50%"]
        let basePath = dir.appendingPathComponent("games").path
        let recorder = Recorder<String>()

        try client.installGame(appName: "app1", basePath: basePath, onProgress: { recorder.record($0) })

        #expect(recorder.values == ["Progress: 10%", "Progress: 50%"])
        #expect(runner.invocations.count == 1)
        let call = try #require(runner.invocations.first)
        #expect(call.arguments == ["-y", "install", "app1", "--base-path", basePath, "--platform", "Windows", "--skip-dlcs", "--skip-sdl"])
        #expect(call.timeout == 21_600)
        #expect(FileManager.default.fileExists(atPath: basePath))
    }

    @Test func launchArgvEnvAndNilTimeout() throws {
        let (client, dir, runner) = makeInstalledClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        try client.launch(appName: "app1", wineBinary: "/x/wine", winePrefix: "/y/pfx")

        #expect(runner.invocations.count == 1)
        let call = try #require(runner.invocations.first)
        #expect(call.arguments == ["launch", "app1", "--wine", "/x/wine", "--wine-prefix", "/y/pfx"])
        #expect(call.environment?["WINEDEBUG"] == "-all")
        #expect(call.timeout == nil)
    }

    @Test func commandFailurePropagatesStderr() {
        let (client, dir, runner) = makeInstalledClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        runner.defaultResult = ProcessResult(exitCode: 1, stdout: "", stderr: "boom")

        #expect(throws: LegendaryClientError.commandFailed("boom")) {
            try client.login(code: "X")
        }
    }

    @Test func commandsThrowNotInstalledWithoutBinary() {
        let dir = Fixtures.makeTempDirectory("legendary-not-installed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = LegendaryClient(binaryURL: dir.appendingPathComponent("missing-legendary"))

        #expect(throws: LegendaryClientError.notInstalled) {
            try client.login(code: "X")
        }
        #expect(throws: LegendaryClientError.notInstalled) {
            try client.logout()
        }
        #expect(throws: LegendaryClientError.notInstalled) {
            _ = try client.accountName()
        }
        #expect(throws: LegendaryClientError.notInstalled) {
            _ = try client.listGames()
        }
        #expect(throws: LegendaryClientError.notInstalled) {
            try client.installGame(appName: "app1")
        }
        #expect(throws: LegendaryClientError.notInstalled) {
            try client.launch(appName: "app1", wineBinary: "/x/wine", winePrefix: "/y/pfx")
        }
        #expect(throws: LegendaryClientError.notInstalled) {
            try client.uninstallGame(appName: "app1")
        }
    }
}
