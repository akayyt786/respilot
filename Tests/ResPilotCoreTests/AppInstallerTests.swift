import Foundation
import Testing
@testable import ResPilotCore

/// Exercises `AppInstaller`'s sequencing: create prefix, provision
/// dependencies verb-by-verb, run the installer, and stop immediately —
/// without touching later stages — the moment any step fails.
@Suite struct AppInstallerTests {
    private func makeInstaller(
        processRunner: FakeProcessRunner
    ) -> (installer: AppInstaller, winetricksScript: URL, tempDir: URL) {
        let dir = Fixtures.makeTempDirectory("app-installer")
        let winetricksScript = Fixtures.writeFile(dir.appendingPathComponent("winetricks"), executable: true)
        let installer = AppInstaller(
            provisioner: BottleProvisioner(processRunner: processRunner),
            winetricks: Winetricks(processRunner: processRunner, scriptURL: winetricksScript),
            processRunner: processRunner
        )
        return (installer, winetricksScript, dir)
    }

    private func makeInstallerFile(in dir: URL) -> String {
        Fixtures.writeFile(dir.appendingPathComponent("SteamSetup.exe"), executable: false).path
    }

    @Test func runsCreatePrefixThenEachVerbThenTheInstallerInOrder() async throws {
        let runner = FakeProcessRunner()
        let (installer, _, dir) = makeInstaller(processRunner: runner)
        defer { try? FileManager.default.removeItem(at: dir) }
        let installerPath = makeInstallerFile(in: dir)
        let bottleDir = dir.appendingPathComponent("Bottles")

        let steps = Recorder<InstallStep>()
        let bottle = try await installer.install(
            bottleName: "SteamBottle",
            bottleDirectory: bottleDir,
            wineBinary: "/opt/CrossOver/bin/wine",
            verbs: ["corefonts", "vcrun2019"],
            installerPath: installerPath,
            onStep: { step in steps.record(step) }
        )

        #expect(steps.values == [
            .creatingBottle,
            .installingDependencies(verb: "corefonts"),
            .installingDependencies(verb: "vcrun2019"),
            .runningInstaller,
            .done,
        ])

        #expect(bottle.kind == .crossOver)
        #expect(bottle.crossOverBottleName == "SteamBottle")
        #expect(bottle.prefixPath == bottleDir.appendingPathComponent("SteamBottle").path)
        #expect(bottle.wineBinaryPath == "/opt/CrossOver/bin/wine")

        // 1 cxbottle create + 2 verbs (one winetricks invocation each) + 1 installer run.
        #expect(runner.invocations.count == 4)
        #expect(runner.invocations[0].arguments.contains("--create"))
        #expect(runner.invocations[1].arguments.last == "corefonts")
        #expect(runner.invocations[2].arguments.last == "vcrun2019")
        #expect(runner.invocations[3].arguments.contains(installerPath))
        #expect(runner.invocations[3].timeout == 1800)
    }

    @Test func missingInstallerFileThrowsAfterBottleAndDependenciesButNeverRunsAnything() async throws {
        let runner = FakeProcessRunner()
        let (installer, _, dir) = makeInstaller(processRunner: runner)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bottleDir = dir.appendingPathComponent("Bottles")

        let steps = Recorder<InstallStep>()
        await #expect(throws: AppInstallerError.installerNotFound(dir.appendingPathComponent("nope.exe").path)) {
            try await installer.install(
                bottleName: "GhostBottle",
                bottleDirectory: bottleDir,
                wineBinary: "/opt/CrossOver/bin/wine",
                verbs: ["corefonts"],
                installerPath: dir.appendingPathComponent("nope.exe").path,
                onStep: { step in steps.record(step) }
            )
        }

        #expect(steps.values == [.creatingBottle, .installingDependencies(verb: "corefonts"), .runningInstaller])
        // cxbottle create + 1 verb only — the never-found installer is never invoked.
        #expect(runner.invocations.count == 2)
    }

    @Test func prefixCreationFailureStopsBeforeAnyDependencyOrInstaller() async throws {
        let runner = FakeProcessRunner()
        runner.resultProvider = { invocation in
            invocation.arguments.contains("--create")
                ? ProcessResult(exitCode: 1, stdout: "", stderr: "cxbottle exploded")
                : nil
        }
        let (installer, _, dir) = makeInstaller(processRunner: runner)
        defer { try? FileManager.default.removeItem(at: dir) }
        let installerPath = makeInstallerFile(in: dir)

        let steps = Recorder<InstallStep>()
        await #expect(throws: BottleProvisionerError.prefixInitFailed("cxbottle exploded")) {
            try await installer.install(
                bottleName: "BrokenBottle",
                bottleDirectory: dir.appendingPathComponent("Bottles"),
                wineBinary: "/opt/CrossOver/bin/wine",
                verbs: ["corefonts"],
                installerPath: installerPath,
                onStep: { step in steps.record(step) }
            )
        }

        #expect(steps.values == [.creatingBottle])
        #expect(runner.invocations.count == 1)
    }

    @Test func dependencyFailureStopsBeforeRunningTheInstaller() async throws {
        let runner = FakeProcessRunner()
        runner.resultProvider = { invocation in
            invocation.arguments.last == "vcrun2019"
                ? ProcessResult(exitCode: 1, stdout: "", stderr: "vcrun2019 download failed")
                : nil
        }
        let (installer, _, dir) = makeInstaller(processRunner: runner)
        defer { try? FileManager.default.removeItem(at: dir) }
        let installerPath = makeInstallerFile(in: dir)

        let steps = Recorder<InstallStep>()
        await #expect(throws: WinetricksError.verbFailed("vcrun2019 download failed")) {
            try await installer.install(
                bottleName: "PartialBottle",
                bottleDirectory: dir.appendingPathComponent("Bottles"),
                wineBinary: "/opt/CrossOver/bin/wine",
                verbs: ["corefonts", "vcrun2019"],
                installerPath: installerPath,
                onStep: { step in steps.record(step) }
            )
        }

        #expect(steps.values == [.creatingBottle, .installingDependencies(verb: "corefonts"), .installingDependencies(verb: "vcrun2019")])
        // cxbottle create + corefonts + vcrun2019 (failed) — installer never reached.
        #expect(runner.invocations.count == 3)
    }
}
