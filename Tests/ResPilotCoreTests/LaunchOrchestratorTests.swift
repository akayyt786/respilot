import Foundation
import Testing
@testable import ResPilotCore

/// Exercises the safety invariants `LaunchOrchestrator`'s doc comment
/// promises: registry-before-display, display-before-launch, immediate
/// restore on a post-switch launch failure, and `restoreNow()` being safe
/// (and idempotent) to call from anywhere at any time.
@Suite struct LaunchOrchestratorTests {
    private func makeOrchestrator(
        display: FakeDisplayModeProvider,
        appLauncher: FakeAppLauncher,
        processRunner: FakeProcessRunner
    ) -> (orchestrator: LaunchOrchestrator, breadcrumb: DisplayRestoreBreadcrumbStore, tempDir: URL) {
        let dir = Fixtures.makeTempDirectory("orchestrator")
        let breadcrumb = DisplayRestoreBreadcrumbStore(fileURL: dir.appendingPathComponent("pending-restore.json"))
        let orchestrator = LaunchOrchestrator(
            displayProvider: display,
            wineRegistry: WineRegistry(processRunner: processRunner),
            appLauncher: appLauncher,
            breadcrumbStore: breadcrumb
        )
        return (orchestrator, breadcrumb, dir)
    }

    @Test func leavesDisplayAloneWhenProfileDoesNotAskForAChange() async throws {
        let modeA = Fixtures.mode(w: 1440, h: 900, hiDPI: false)
        let display = FakeDisplayModeProvider(current: modeA, available: [modeA])
        let appLauncher = FakeAppLauncher()
        let processRunner = FakeProcessRunner()
        let (orchestrator, _, dir) = makeOrchestrator(display: display, appLauncher: appLauncher, processRunner: processRunner)
        defer { try? FileManager.default.removeItem(at: dir) }

        let profile = Fixtures.profile(display: .leaveUnchanged)
        _ = try await orchestrator.launch(profile)

        #expect(display.setModeCalls.isEmpty)
        #expect(appLauncher.launchedAppInvocations.map(\.path) == [profile.launchTarget.path])
        #expect(processRunner.invocations.count == 1) // just the RetinaMode write
        #expect(await orchestrator.hasPendingRestore == false)
        await orchestrator.awaitActiveSession() // must not hang: no watch task was started
    }

    @Test func switchesDisplayAndAutoRestoresOnceTheGameExits() async throws {
        let before = Fixtures.mode(w: 1440, h: 900, hiDPI: false)
        let target = Fixtures.mode(w: 1920, h: 1080, hiDPI: true)
        let display = FakeDisplayModeProvider(current: before, available: [before, target])
        let appLauncher = FakeAppLauncher()
        appLauncher.completesImmediately = false
        let processRunner = FakeProcessRunner()
        let (orchestrator, breadcrumb, dir) = makeOrchestrator(display: display, appLauncher: appLauncher, processRunner: processRunner)
        defer { try? FileManager.default.removeItem(at: dir) }

        let profile = Fixtures.profile(
            display: DisplayTarget(pointWidth: 1920, pointHeight: 1080, hiDPI: true),
            autoRevertOnQuit: true
        )
        _ = try await orchestrator.launch(profile)

        #expect(display.setModeCalls == [target])
        #expect(await orchestrator.hasPendingRestore == true)
        #expect(breadcrumb.read() == before)

        // Game "exits"; the watch task should restore automatically. (Task
        // scheduling isn't synchronous with `launch()` returning, so the
        // assertion that the watcher actually ran lives after
        // `awaitActiveSession()` below, which is the one thing that does
        // guarantee it has.)
        appLauncher.signalCompletion()
        await orchestrator.awaitActiveSession()

        #expect(appLauncher.completionsAwaited.count == 1)
        #expect(display.setModeCalls == [target, before])
        #expect(display.current == before)
        #expect(await orchestrator.hasPendingRestore == false)
        #expect(breadcrumb.read() == nil)
    }

    @Test func withoutAutoRevertTheDisplayStaysChangedUntilManuallyRestored() async throws {
        let before = Fixtures.mode(w: 1440, h: 900, hiDPI: false)
        let target = Fixtures.mode(w: 1920, h: 1080, hiDPI: true)
        let display = FakeDisplayModeProvider(current: before, available: [before, target])
        let appLauncher = FakeAppLauncher()
        let processRunner = FakeProcessRunner()
        let (orchestrator, _, dir) = makeOrchestrator(display: display, appLauncher: appLauncher, processRunner: processRunner)
        defer { try? FileManager.default.removeItem(at: dir) }

        let profile = Fixtures.profile(
            display: DisplayTarget(pointWidth: 1920, pointHeight: 1080, hiDPI: true),
            autoRevertOnQuit: false
        )
        _ = try await orchestrator.launch(profile)

        #expect(appLauncher.completionsAwaited.isEmpty) // no watcher started
        #expect(await orchestrator.hasPendingRestore == true)

        let restored = try await orchestrator.restoreNow()
        #expect(restored == true)
        #expect(display.setModeCalls == [target, before])
        #expect(await orchestrator.hasPendingRestore == false)
    }

    @Test func noMatchingDisplayModeThrowsBeforeTouchingTheScreen() async throws {
        let before = Fixtures.mode(w: 1440, h: 900, hiDPI: false)
        let display = FakeDisplayModeProvider(current: before, available: [before])
        let appLauncher = FakeAppLauncher()
        let processRunner = FakeProcessRunner()
        let (orchestrator, _, dir) = makeOrchestrator(display: display, appLauncher: appLauncher, processRunner: processRunner)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wantedTarget = DisplayTarget(pointWidth: 3840, pointHeight: 2160, hiDPI: true)
        let profile = Fixtures.profile(display: wantedTarget)

        await #expect(throws: DisplayModeError.noMatchingMode(wantedTarget, available: [before])) {
            _ = try await orchestrator.launch(profile)
        }
        #expect(display.setModeCalls.isEmpty)
        #expect(processRunner.invocations.count == 1) // registry write still happened first
        #expect(appLauncher.launchedAppInvocations.isEmpty)
    }

    @Test func aFailedRegistryWriteNeverTouchesTheDisplayOrLaunchesAnything() async throws {
        let before = Fixtures.mode(w: 1440, h: 900, hiDPI: false)
        let target = Fixtures.mode(w: 1920, h: 1080, hiDPI: true)
        let display = FakeDisplayModeProvider(current: before, available: [before, target])
        let appLauncher = FakeAppLauncher()
        let processRunner = FakeProcessRunner()
        processRunner.defaultResult = ProcessResult(exitCode: 1, stdout: "", stderr: "registry busy")
        let (orchestrator, _, dir) = makeOrchestrator(display: display, appLauncher: appLauncher, processRunner: processRunner)
        defer { try? FileManager.default.removeItem(at: dir) }

        let profile = Fixtures.profile(display: DisplayTarget(pointWidth: 1920, pointHeight: 1080, hiDPI: true))

        await #expect(throws: WineRegistryError.wineCommandFailed("registry busy")) {
            _ = try await orchestrator.launch(profile)
        }
        #expect(display.setModeCalls.isEmpty)
        #expect(appLauncher.launchedAppInvocations.isEmpty)
    }

    @Test func aLaunchFailureAfterTheDisplayAlreadyChangedRestoresImmediately() async throws {
        let before = Fixtures.mode(w: 1440, h: 900, hiDPI: false)
        let target = Fixtures.mode(w: 1920, h: 1080, hiDPI: true)
        let display = FakeDisplayModeProvider(current: before, available: [before, target])
        let appLauncher = FakeAppLauncher()
        appLauncher.launchAppError = FakeError(message: "app refused to open")
        let processRunner = FakeProcessRunner()
        let (orchestrator, breadcrumb, dir) = makeOrchestrator(display: display, appLauncher: appLauncher, processRunner: processRunner)
        defer { try? FileManager.default.removeItem(at: dir) }

        let profile = Fixtures.profile(display: DisplayTarget(pointWidth: 1920, pointHeight: 1080, hiDPI: true))

        await #expect(throws: FakeError(message: "app refused to open")) {
            _ = try await orchestrator.launch(profile)
        }

        #expect(display.setModeCalls == [target, before])
        #expect(display.current == before)
        #expect(await orchestrator.hasPendingRestore == false)
        #expect(breadcrumb.read() == nil)
    }

    @Test func restoreNowIsANoOpWhenNothingIsPending() async throws {
        let mode = Fixtures.mode(w: 1440, h: 900, hiDPI: false)
        let display = FakeDisplayModeProvider(current: mode, available: [mode])
        let (orchestrator, _, dir) = makeOrchestrator(display: display, appLauncher: FakeAppLauncher(), processRunner: FakeProcessRunner())
        defer { try? FileManager.default.removeItem(at: dir) }

        let restored = try await orchestrator.restoreNow()
        #expect(restored == false)
        #expect(display.setModeCalls.isEmpty)
    }

    @Test func manualRestoreCancelsThePendingWatcherSoItDoesNotRestoreASecondTime() async throws {
        let before = Fixtures.mode(w: 1440, h: 900, hiDPI: false)
        let target = Fixtures.mode(w: 1920, h: 1080, hiDPI: true)
        let display = FakeDisplayModeProvider(current: before, available: [before, target])
        let appLauncher = FakeAppLauncher()
        appLauncher.completesImmediately = false
        let processRunner = FakeProcessRunner()
        let (orchestrator, breadcrumb, dir) = makeOrchestrator(display: display, appLauncher: appLauncher, processRunner: processRunner)
        defer { try? FileManager.default.removeItem(at: dir) }

        let profile = Fixtures.profile(
            display: DisplayTarget(pointWidth: 1920, pointHeight: 1080, hiDPI: true),
            autoRevertOnQuit: true
        )
        _ = try await orchestrator.launch(profile)

        // User hits "Restore Display Now" while the game is still running.
        let restored = try await orchestrator.restoreNow()
        #expect(restored == true)
        #expect(display.setModeCalls == [target, before])
        #expect(await orchestrator.hasPendingRestore == false)
        #expect(breadcrumb.read() == nil)

        // The game exits afterwards; the cancelled watcher must not fire a second restore.
        appLauncher.signalCompletion()
        await orchestrator.awaitActiveSession()

        #expect(display.setModeCalls == [target, before])
    }

    @Test func windowsExecutableTargetsGoThroughWineStartInsteadOfNSWorkspace() async throws {
        let mode = Fixtures.mode(w: 1440, h: 900, hiDPI: false)
        let display = FakeDisplayModeProvider(current: mode, available: [mode])
        let appLauncher = FakeAppLauncher()
        let processRunner = FakeProcessRunner()
        let (orchestrator, _, dir) = makeOrchestrator(display: display, appLauncher: appLauncher, processRunner: processRunner)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bottle = Fixtures.bottleTarget(crossOverBottleName: "MyBottle")
        let profile = Fixtures.profile(bottle: bottle, launchTarget: .windowsExecutable(path: "C:\\game.exe"), display: .leaveUnchanged)

        _ = try await orchestrator.launch(profile)

        #expect(appLauncher.launchedAppInvocations.isEmpty)
        #expect(appLauncher.launchedExeInvocations.map(\.path) == ["C:\\game.exe"])
        #expect(appLauncher.launchedExeInvocations.first?.bottle == bottle)
    }

    @Test func compatibilitySettingsAreAppliedAsARegistryWriteBeforeAnyDisplayChange() async throws {
        let mode = Fixtures.mode(w: 1440, h: 900, hiDPI: false)
        let display = FakeDisplayModeProvider(current: mode, available: [mode])
        let appLauncher = FakeAppLauncher()
        let processRunner = FakeProcessRunner()
        let (orchestrator, _, dir) = makeOrchestrator(display: display, appLauncher: appLauncher, processRunner: processRunner)
        defer { try? FileManager.default.removeItem(at: dir) }

        let profile = Fixtures.profile(
            display: .leaveUnchanged,
            compatibility: WineCompatibilitySettings(renderer: .vulkan)
        )
        _ = try await orchestrator.launch(profile)

        // RetinaMode write, then the renderer write — both registry calls,
        // both before the (never-touched, since display is unchanged) screen.
        #expect(processRunner.invocations.count == 2)
        #expect(processRunner.invocations[1].arguments.contains("renderer"))
        #expect(processRunner.invocations[1].arguments.contains("vulkan"))
    }

    @Test func aFailedCompatibilityWriteNeverTouchesTheDisplayOrLaunchesAnything() async throws {
        let before = Fixtures.mode(w: 1440, h: 900, hiDPI: false)
        let target = Fixtures.mode(w: 1920, h: 1080, hiDPI: true)
        let display = FakeDisplayModeProvider(current: before, available: [before, target])
        let appLauncher = FakeAppLauncher()
        let processRunner = FakeProcessRunner()
        processRunner.resultProvider = { invocation in
            invocation.arguments.contains("renderer")
                ? ProcessResult(exitCode: 1, stdout: "", stderr: "renderer busy")
                : nil
        }
        let (orchestrator, _, dir) = makeOrchestrator(display: display, appLauncher: appLauncher, processRunner: processRunner)
        defer { try? FileManager.default.removeItem(at: dir) }

        let profile = Fixtures.profile(
            display: DisplayTarget(pointWidth: 1920, pointHeight: 1080, hiDPI: true),
            compatibility: WineCompatibilitySettings(renderer: .gdi)
        )

        await #expect(throws: WineRegistryError.wineCommandFailed("renderer busy")) {
            _ = try await orchestrator.launch(profile)
        }
        #expect(display.setModeCalls.isEmpty)
        #expect(appLauncher.launchedAppInvocations.isEmpty)
    }

    @Test func esyncAndMsyncReachTheActualWindowsExecutableLaunch() async throws {
        let mode = Fixtures.mode(w: 1440, h: 900, hiDPI: false)
        let display = FakeDisplayModeProvider(current: mode, available: [mode])
        let appLauncher = FakeAppLauncher()
        let processRunner = FakeProcessRunner()
        let (orchestrator, _, dir) = makeOrchestrator(display: display, appLauncher: appLauncher, processRunner: processRunner)
        defer { try? FileManager.default.removeItem(at: dir) }

        let compatibility = WineCompatibilitySettings(esync: true, msync: true)
        let profile = Fixtures.profile(
            launchTarget: .windowsExecutable(path: "C:\\game.exe"),
            display: .leaveUnchanged,
            compatibility: compatibility
        )
        _ = try await orchestrator.launch(profile)

        #expect(appLauncher.launchedExeInvocations.first?.compatibility == compatibility)
    }

    @Test func esyncAndMsyncReachAnAppBundleLaunchOnlyWhenRequested() async throws {
        let mode = Fixtures.mode(w: 1440, h: 900, hiDPI: false)
        let display = FakeDisplayModeProvider(current: mode, available: [mode])
        let appLauncher = FakeAppLauncher()
        let processRunner = FakeProcessRunner()
        let (orchestrator, _, dir) = makeOrchestrator(display: display, appLauncher: appLauncher, processRunner: processRunner)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Default compatibility: no environment override at all — proves
        // LaunchServices' own default inheritance is left untouched for
        // the common case.
        let plainProfile = Fixtures.profile(display: .leaveUnchanged)
        _ = try await orchestrator.launch(plainProfile)
        #expect(appLauncher.launchedAppInvocations.first?.environment == nil)

        let syncedProfile = Fixtures.profile(
            display: .leaveUnchanged,
            compatibility: WineCompatibilitySettings(esync: true)
        )
        _ = try await orchestrator.launch(syncedProfile)
        #expect(appLauncher.launchedAppInvocations.last?.environment?["WINEESYNC"] == "1")
        #expect(appLauncher.launchedAppInvocations.last?.environment?["WINEMSYNC"] == nil)
    }
}
