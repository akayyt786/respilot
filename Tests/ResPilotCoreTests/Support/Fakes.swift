import CoreGraphics
import Foundation
import ResPilotCore

/// Records every `wine`/`wine reg` invocation instead of spawning anything,
/// so tests assert exact argv/env shape and can fail an arbitrary call by
/// inspecting its arguments (e.g. "the LogPixels write, not the RetinaMode
/// one"). Locked because `LaunchOrchestrator` (an actor) can call into it
/// from a different isolation domain than the test's assertions.
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]?
        let timeout: TimeInterval?
    }

    private let lock = NSLock()
    private var _invocations: [Invocation] = []
    var invocations: [Invocation] {
        lock.lock(); defer { lock.unlock() }
        return _invocations
    }

    /// Return `nil` to fall back to `defaultResult`; return a `ProcessResult`
    /// to fail (or otherwise customize) one specific invocation.
    var resultProvider: (@Sendable (Invocation) -> ProcessResult?)?
    var defaultResult = ProcessResult(exitCode: 0, stdout: "", stderr: "")

    /// Lines the streaming `run` overload emits through `onOutputLine`
    /// before returning, in order — lets tests assert progress forwarding
    /// (e.g. `LegendaryClient.installGame`) without a real process.
    var streamLines: [String] = []

    func run(executable: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval?) throws -> ProcessResult {
        try run(executable: executable, arguments: arguments, environment: environment, timeout: timeout, onOutputLine: nil)
    }

    func run(executable: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval?, onOutputLine: (@Sendable (String) -> Void)?) throws -> ProcessResult {
        let invocation = Invocation(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        lock.lock()
        _invocations.append(invocation)
        lock.unlock()
        for line in streamLines { onOutputLine?(line) }
        return resultProvider?(invocation) ?? defaultResult
    }
}

/// In-memory stand-in for CoreGraphics so display-mode selection and the
/// orchestrator's sequencing can be exercised without touching a real
/// screen. `setModeCalls` is the audit trail tests assert ordering against.
final class FakeDisplayModeProvider: DisplayModeProviding, @unchecked Sendable {
    let mainDisplayID: CGDirectDisplayID = 1

    private let lock = NSLock()
    private var _current: DisplayModeInfo
    private var _setModeCalls: [DisplayModeInfo] = []

    var available: [DisplayModeInfo]
    var setModeError: Error?

    init(current: DisplayModeInfo, available: [DisplayModeInfo]) {
        self._current = current
        self.available = available
    }

    var current: DisplayModeInfo {
        lock.lock(); defer { lock.unlock() }
        return _current
    }

    var setModeCalls: [DisplayModeInfo] {
        lock.lock(); defer { lock.unlock() }
        return _setModeCalls
    }

    func currentMode(display: CGDirectDisplayID) throws -> DisplayModeInfo { current }
    func availableModes(display: CGDirectDisplayID) throws -> [DisplayModeInfo] { available }

    func setMode(_ mode: DisplayModeInfo, display: CGDirectDisplayID) throws {
        if let setModeError { throw setModeError }
        lock.lock()
        _setModeCalls.append(mode)
        _current = mode
        lock.unlock()
    }
}

/// Fake `AppLaunching`. `completesImmediately = false` lets a test hold
/// `awaitCompletion` open (as if the game were still running) and release
/// it deterministically with `signalCompletion()`, instead of racing real
/// sleeps against the orchestrator's background watch task.
final class FakeAppLauncher: AppLaunching, @unchecked Sendable {
    var launchAppError: Error?
    var launchExeError: Error?
    var handleToReturn: LaunchHandle = .runningApplication(pid: 4242)
    var completesImmediately = true

    private let lock = NSLock()
    private var _launchedAppInvocations: [(path: String, environment: [String: String]?)] = []
    private var _launchedExeInvocations: [(path: String, bottle: WineBottleTarget, compatibility: WineCompatibilitySettings)] = []
    private var _completionsAwaited: [LaunchHandle] = []
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []
    /// True once `signalCompletion()` has fired. Guards the same lock as
    /// `pendingContinuations`, so there is no window where a continuation
    /// registered *after* `signalCompletion()` ran could be left parked
    /// forever (a real TOCTOU race under heavy parallel test scheduling:
    /// `awaitCompletion`'s `Task` isn't guaranteed to have reached
    /// `withCheckedContinuation` yet by the time a test calls
    /// `signalCompletion()`).
    private var signaled = false

    var launchedAppInvocations: [(path: String, environment: [String: String]?)] {
        lock.lock(); defer { lock.unlock() }
        return _launchedAppInvocations
    }
    var launchedExeInvocations: [(path: String, bottle: WineBottleTarget, compatibility: WineCompatibilitySettings)] {
        lock.lock(); defer { lock.unlock() }
        return _launchedExeInvocations
    }
    var completionsAwaited: [LaunchHandle] { lock.lock(); defer { lock.unlock() }; return _completionsAwaited }

    func launchApp(at path: String, environment: [String: String]?) async throws -> LaunchHandle {
        if let launchAppError { throw launchAppError }
        recordAppLaunch(path: path, environment: environment)
        return handleToReturn
    }

    func launchWindowsExecutable(path: String, in bottle: WineBottleTarget, compatibility: WineCompatibilitySettings) async throws -> LaunchHandle {
        if let launchExeError { throw launchExeError }
        recordExeLaunch(path: path, bottle: bottle, compatibility: compatibility)
        return handleToReturn
    }

    func awaitCompletion(_ handle: LaunchHandle) async {
        if beginAwaitingCompletion(handle) {
            return
        }
        await withCheckedContinuation { continuation in
            registerOrResumeImmediately(continuation)
        }
    }

    /// Simulates "the game exited" — resumes any `awaitCompletion` caller
    /// already parked waiting for it, and makes any future one (even one
    /// registered a moment from now) resume immediately too.
    func signalCompletion() {
        let continuations = takeSignaled()
        for continuation in continuations { continuation.resume() }
    }

    // MARK: - Lock-guarded mutations (kept synchronous so no lock/unlock
    // pair straddles an `await`, which the Swift 6 concurrency checker
    // otherwise flags even when — as here — the pair never actually does).

    private func recordAppLaunch(path: String, environment: [String: String]?) {
        lock.lock(); defer { lock.unlock() }
        _launchedAppInvocations.append((path, environment))
    }

    private func recordExeLaunch(path: String, bottle: WineBottleTarget, compatibility: WineCompatibilitySettings) {
        lock.lock(); defer { lock.unlock() }
        _launchedExeInvocations.append((path, bottle, compatibility))
    }

    /// Records the call and returns `true` if it should complete
    /// immediately (i.e. no continuation should be created at all).
    private func beginAwaitingCompletion(_ handle: LaunchHandle) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _completionsAwaited.append(handle)
        return completesImmediately
    }

    private func registerOrResumeImmediately(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if signaled {
            lock.unlock()
            continuation.resume()
        } else {
            pendingContinuations.append(continuation)
            lock.unlock()
        }
    }

    private func takeSignaled() -> [CheckedContinuation<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        signaled = true
        let continuations = pendingContinuations
        pendingContinuations.removeAll()
        return continuations
    }
}

/// Fake `FileDownloading` — returns configured bytes/status instead of
/// making a real network call. Shared by `Winetricks` and
/// `InstallerDownloader` tests.
final class FakeFileDownloader: FileDownloading, @unchecked Sendable {
    var data = Data("#!/bin/sh\necho fake-winetricks\n".utf8)
    var statusCode = 200
    var throwError: Error?

    private let lock = NSLock()
    private var _requestedURLs: [URL] = []
    var requestedURLs: [URL] { lock.lock(); defer { lock.unlock() }; return _requestedURLs }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        recordRequest(url)
        if let throwError { throw throwError }
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }

    private func recordRequest(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        _requestedURLs.append(url)
    }
}
