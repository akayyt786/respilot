import Foundation
import Testing
@testable import ResPilotCore

@Suite struct WinetricksInstallTests {
    private func makeWinetricks(downloader: FakeFileDownloader) -> (Winetricks, URL) {
        let dir = Fixtures.makeTempDirectory("winetricks-install")
        let scriptURL = dir.appendingPathComponent("winetricks")
        return (Winetricks(downloader: downloader, scriptURL: scriptURL), dir)
    }

    @Test func isInstalledFalseBeforeInstallling() {
        let (winetricks, dir) = makeWinetricks(downloader: FakeFileDownloader())
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!winetricks.isInstalled)
    }

    @Test func installDownloadsAndMarksExecutable() async throws {
        let downloader = FakeFileDownloader()
        downloader.data = Data("#!/bin/sh\necho hi\n".utf8)
        let (winetricks, dir) = makeWinetricks(downloader: downloader)
        defer { try? FileManager.default.removeItem(at: dir) }

        try await winetricks.install()

        #expect(winetricks.isInstalled)
        let contents = try String(contentsOf: winetricks.scriptURL, encoding: .utf8)
        #expect(contents.contains("echo hi"))
        let permissions = try FileManager.default.attributesOfItem(atPath: winetricks.scriptURL.path)[.posixPermissions] as? Int
        #expect((permissions ?? 0) & 0o111 != 0) // executable bit set
    }

    @Test func installUsesTheCanonicalGitHubRawURLByDefault() async throws {
        let downloader = FakeFileDownloader()
        let (winetricks, dir) = makeWinetricks(downloader: downloader)
        defer { try? FileManager.default.removeItem(at: dir) }

        try await winetricks.install()

        #expect(downloader.requestedURLs == [URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks")!])
    }

    @Test func installThrowsOnNonSuccessStatus() async {
        let downloader = FakeFileDownloader()
        downloader.statusCode = 404
        let (winetricks, dir) = makeWinetricks(downloader: downloader)
        defer { try? FileManager.default.removeItem(at: dir) }

        await #expect(throws: WinetricksError.downloadFailed) {
            try await winetricks.install()
        }
        #expect(!winetricks.isInstalled)
    }

    @Test func installThrowsOnEmptyBody() async {
        let downloader = FakeFileDownloader()
        downloader.data = Data()
        let (winetricks, dir) = makeWinetricks(downloader: downloader)
        defer { try? FileManager.default.removeItem(at: dir) }

        await #expect(throws: WinetricksError.downloadFailed) {
            try await winetricks.install()
        }
    }
}

@Suite struct WinetricksRunTests {
    private func makeInstalledWinetricks() -> (Winetricks, URL) {
        let dir = Fixtures.makeTempDirectory("winetricks-run")
        let scriptURL = Fixtures.writeFile(dir.appendingPathComponent("winetricks"), executable: true)
        return (Winetricks(scriptURL: scriptURL), dir)
    }

    @Test func throwsWhenNotInstalledYet() {
        let dir = Fixtures.makeTempDirectory("winetricks-not-installed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let winetricks = Winetricks(scriptURL: dir.appendingPathComponent("missing-script"))
        let bottle = Fixtures.bottleTarget()

        #expect(throws: WinetricksError.notInstalled) {
            try winetricks.run(verbs: ["corefonts"], in: bottle)
        }
    }

    @Test func throwsWhenNoVerbsGiven() {
        let (winetricks, dir) = makeInstalledWinetricks()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bottle = Fixtures.bottleTarget()

        #expect(throws: WinetricksError.noVerbs) {
            try winetricks.run(verbs: [], in: bottle)
        }
    }

    @Test func runsUnattendedForCrossOverBottleViaBottleAddressingWrapper() throws {
        let runner = FakeProcessRunner()
        let dir = Fixtures.makeTempDirectory("winetricks-run-invocation")
        let scriptURL = Fixtures.writeFile(dir.appendingPathComponent("winetricks"), executable: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let winetricks = Winetricks(processRunner: runner, scriptURL: scriptURL)
        let bottle = Fixtures.bottleTarget(wineBinaryPath: "/opt/CrossOver/bin/wine", crossOverBottleName: "TestBottle")

        try winetricks.run(verbs: ["corefonts", "vcrun2019"], in: bottle)

        #expect(runner.invocations.count == 1)
        let call = try #require(runner.invocations.first)
        #expect(call.executable == "/bin/sh")
        #expect(call.arguments == [scriptURL.path, "-q", "corefonts", "vcrun2019"])
        #expect(call.environment?["WINEPREFIX"] == bottle.prefixPath)
        #expect(call.environment?["WINESERVER"] == "/opt/CrossOver/bin/wineserver")
        // WINE points at a generated wrapper (env vars can't carry the
        // `--bottle` argv CrossOver's shared wine binary needs), not the
        // raw wine binary path directly.
        let winePath = try #require(call.environment?["WINE"])
        #expect(winePath != "/opt/CrossOver/bin/wine")
        #expect(FileManager.default.isExecutableFile(atPath: winePath))
        let wrapperContents = try String(contentsOfFile: winePath, encoding: .utf8)
        #expect(wrapperContents.contains(#"exec "/opt/CrossOver/bin/wine" --bottle "TestBottle" "$@""#))
        // Neither wineloader nor wineserver exist at this fake path, so
        // the arch-detection fixup env vars are left unset rather than
        // pointing at nonexistent files.
        #expect(call.environment?["WINE_BIN"] == nil)
        #expect(call.environment?["WINESERVER_BIN"] == nil)
        // Bounded by default — see the class doc: a hung verb with no
        // subprocess left and no network activity has no other way back.
        #expect(call.timeout == 1800)
    }

    @Test func customTimeoutOverridesTheDefault() throws {
        let runner = FakeProcessRunner()
        let dir = Fixtures.makeTempDirectory("winetricks-run-custom-timeout")
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptURL = Fixtures.writeFile(dir.appendingPathComponent("winetricks"), executable: true)
        let winetricks = Winetricks(processRunner: runner, scriptURL: scriptURL)
        let bottle = Fixtures.bottleTarget(crossOverBottleName: "TestBottle")

        try winetricks.run(verbs: ["corefonts"], in: bottle, timeout: 42)
        #expect(runner.invocations.first?.timeout == 42)

        try winetricks.run(verbs: ["corefonts"], in: bottle, timeout: nil)
        #expect(runner.invocations.last?.timeout == nil)
    }

    @Test func setsWineBinAndWineServerBinWhenRealBinariesArePresent() throws {
        let runner = FakeProcessRunner()
        let dir = Fixtures.makeTempDirectory("winetricks-run-arch-fixup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptURL = Fixtures.writeFile(dir.appendingPathComponent("winetricks"), executable: true)
        let binDir = dir.appendingPathComponent("bin")
        Fixtures.writeFile(binDir.appendingPathComponent("wine"), executable: true)
        Fixtures.writeFile(binDir.appendingPathComponent("wineloader"), executable: true)
        Fixtures.writeFile(binDir.appendingPathComponent("wineserver"), executable: true)
        let winetricks = Winetricks(processRunner: runner, scriptURL: scriptURL)
        let bottle = Fixtures.bottleTarget(wineBinaryPath: binDir.appendingPathComponent("wine").path, crossOverBottleName: "TestBottle")

        try winetricks.run(verbs: ["corefonts"], in: bottle)

        let call = try #require(runner.invocations.first)
        #expect(call.environment?["WINE_BIN"] == binDir.appendingPathComponent("wineloader").path)
        #expect(call.environment?["WINESERVER_BIN"] == binDir.appendingPathComponent("wineserver").path)
    }

    @Test func throwsWhenCrossOverBottleNameMissing() {
        let (winetricks, dir) = makeInstalledWinetricks()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bottle = Fixtures.bottleTarget(crossOverBottleName: nil)

        #expect(throws: WinetricksError.verbFailed("Bottle is missing its CrossOver bottle name.")) {
            try winetricks.run(verbs: ["corefonts"], in: bottle)
        }
    }

    @Test func wineskinStyleBottleUsesPlainWineWithoutWrapper() throws {
        let runner = FakeProcessRunner()
        let dir = Fixtures.makeTempDirectory("winetricks-run-wineskin")
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptURL = Fixtures.writeFile(dir.appendingPathComponent("winetricks"), executable: true)
        let winetricks = Winetricks(processRunner: runner, scriptURL: scriptURL)
        let bottle = Fixtures.bottleTarget(
            kind: .wineskinStyle,
            wineBinaryPath: "/Applications/Game.app/Contents/SharedSupport/wine",
            crossOverBottleName: nil
        )

        try winetricks.run(verbs: ["corefonts"], in: bottle)

        let call = try #require(runner.invocations.first)
        #expect(call.environment?["WINE"] == "/Applications/Game.app/Contents/SharedSupport/wine")
        #expect(call.environment?["WINEPREFIX"] == bottle.prefixPath)
        #expect(call.environment?["WINESERVER"] == "/Applications/Game.app/Contents/SharedSupport/wineserver")
        #expect(call.environment?["WINE_BIN"] == nil)
    }

    @Test func respilotManagedBottleUsesPlainWineWithoutWrapper() throws {
        let runner = FakeProcessRunner()
        let dir = Fixtures.makeTempDirectory("winetricks-run-respilot")
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptURL = Fixtures.writeFile(dir.appendingPathComponent("winetricks"), executable: true)
        let winetricks = Winetricks(processRunner: runner, scriptURL: scriptURL)
        let bottle = Fixtures.bottleTarget(
            kind: .respilotManaged,
            wineBinaryPath: "/opt/ResPilot/WineEngine/Wine Staging.app/Contents/Resources/wine/bin/wine",
            crossOverBottleName: nil
        )

        try winetricks.run(verbs: ["corefonts"], in: bottle)

        let call = try #require(runner.invocations.first)
        #expect(call.environment?["WINE"] == "/opt/ResPilot/WineEngine/Wine Staging.app/Contents/Resources/wine/bin/wine")
        #expect(call.environment?["WINEPREFIX"] == bottle.prefixPath)
        #expect(call.environment?["WINESERVER"] == "/opt/ResPilot/WineEngine/Wine Staging.app/Contents/Resources/wine/bin/wineserver")
        #expect(call.environment?["WINE_BIN"] == nil)
    }

    @Test func verbFailurePropagatesStderr() {
        let runner = FakeProcessRunner()
        runner.defaultResult = ProcessResult(exitCode: 1, stdout: "", stderr: "download of corefonts failed")
        let dir = Fixtures.makeTempDirectory("winetricks-run-fail")
        let scriptURL = Fixtures.writeFile(dir.appendingPathComponent("winetricks"), executable: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let winetricks = Winetricks(processRunner: runner, scriptURL: scriptURL)
        let bottle = Fixtures.bottleTarget()

        #expect(throws: WinetricksError.verbFailed("download of corefonts failed")) {
            try winetricks.run(verbs: ["corefonts"], in: bottle)
        }
    }
}
