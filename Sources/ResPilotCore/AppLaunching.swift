import AppKit
import Foundation

/// Opaque reference to a launched process (or process group), enough for
/// `awaitCompletion` to know how to wait on it later.
public enum LaunchHandle: Sendable, Equatable {
    case runningApplication(pid: Int32)
    case wineServerWait(wineServerPath: String, environment: [String: String])
}

/// Abstraction over "start this thing, tell me when it's done" so
/// `LaunchOrchestrator`'s sequencing logic is testable without spawning
/// real processes or opening real apps.
public protocol AppLaunching: Sendable {
    func launchApp(at path: String, environment: [String: String]?) async throws -> LaunchHandle
    func launchWindowsExecutable(path: String, in bottle: WineBottleTarget, compatibility: WineCompatibilitySettings) async throws -> LaunchHandle
    func awaitCompletion(_ handle: LaunchHandle) async
}

/// Real implementation. `.app` bundles go through `NSWorkspace` and are
/// tracked via `NSRunningApplication`; raw `.exe` targets go through
/// `wine start /unix` and completion is detected with `wineserver -w`
/// (documented Wine tool: "wait until the server is no longer running") —
/// the only generic, reliable "is this bottle still doing anything" signal
/// since a detached `start` gives no direct child PID to wait on.
public final class SystemAppLauncher: AppLaunching {
    private let processRunner: ProcessRunning
    private let pollInterval: UInt64

    public init(processRunner: ProcessRunning = FoundationProcessRunner(), pollIntervalNanoseconds: UInt64 = 1_000_000_000) {
        self.processRunner = processRunner
        self.pollInterval = pollIntervalNanoseconds
    }

    /// `environment`, when non-nil, replaces the launched process's
    /// environment entirely (`NSWorkspace.OpenConfiguration.environment`
    /// semantics) — callers must merge onto `ProcessInfo.processInfo.environment`
    /// themselves rather than pass a sparse override dict. `nil` leaves
    /// LaunchServices' own default inheritance untouched.
    public func launchApp(at path: String, environment: [String: String]?) async throws -> LaunchHandle {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let environment {
            config.environment = environment
        }
        let app = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config)
        return .runningApplication(pid: app.processIdentifier)
    }

    public func launchWindowsExecutable(
        path: String,
        in bottle: WineBottleTarget,
        compatibility: WineCompatibilitySettings
    ) async throws -> LaunchHandle {
        let registry = WineRegistry(processRunner: processRunner)
        let startInvocation = try registry.invocation(for: bottle, subcommand: ["start", "/unix", path], compatibility: compatibility)
        let result = try processRunner.run(
            executable: startInvocation.executable,
            arguments: startInvocation.arguments,
            environment: startInvocation.environment
        )
        guard result.succeeded else {
            throw ProcessRunError.launchFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        let wineServerPath = URL(fileURLWithPath: bottle.wineBinaryPath)
            .deletingLastPathComponent()
            .appendingPathComponent("wineserver")
            .path
        let envOnly = try registry.invocation(for: bottle, subcommand: [])
        return .wineServerWait(wineServerPath: wineServerPath, environment: envOnly.environment)
    }

    public func awaitCompletion(_ handle: LaunchHandle) async {
        switch handle {
        case .runningApplication(let pid):
            while let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
                try? await Task.sleep(nanoseconds: pollInterval)
            }
        case .wineServerWait(let wineServerPath, let environment):
            _ = try? processRunner.run(executable: wineServerPath, arguments: ["-w"], environment: environment)
        }
    }
}
