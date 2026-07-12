import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// Thin process-execution seam. Production code goes through
/// `FoundationProcessRunner`; tests inject a recording fake so argv/env
/// construction is asserted without spawning anything.
public protocol ProcessRunning: Sendable {
    /// `timeout` bounds total wall-clock time (launch through exit). `nil`
    /// waits indefinitely — reserved for calls already known to be fast
    /// and local (a single `wine reg add`, `cxbottle --create`), or a
    /// user-controlled game session (`LegendaryClient.launch`, which ends
    /// only when the player quits the game). Anything that can touch the
    /// network or run a vendor's own installer/verb script (Winetricks,
    /// the final installer run) MUST pass a finite value: verified
    /// against a real hang (a Winetricks verb that silently stalled
    /// mid-run, no subprocess, no network activity, still "installing"
    /// 30+ minutes later) that a bare `Process` + `waitUntilExit()` has
    /// no way to recover from on its own.
    @discardableResult
    func run(executable: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval?) throws -> ProcessResult

    /// Same as the 4-arg `run`, plus `onOutputLine` — invoked once per
    /// complete line of combined stdout/stderr as the process runs,
    /// instead of only after it exits. Needed for GB-scale, hours-long
    /// downloads (`LegendaryClient.installGame`) where a caller wants to
    /// show progress rather than block silently until completion. A
    /// protocol requirement (not just an extension method) so dynamic
    /// dispatch actually reaches `FoundationProcessRunner`'s real
    /// implementation rather than always resolving to the ignoring
    /// default below.
    @discardableResult
    func run(executable: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval?, onOutputLine: (@Sendable (String) -> Void)?) throws -> ProcessResult
}

extension ProcessRunning {
    /// Convenience for the (still common) no-timeout case — every existing
    /// call site compiles unchanged against this.
    @discardableResult
    public func run(executable: String, arguments: [String], environment: [String: String]?) throws -> ProcessResult {
        try run(executable: executable, arguments: arguments, environment: environment, timeout: nil)
    }

    /// Default: forwards to the 4-arg `run`, ignoring `onOutputLine` — so
    /// `FakeProcessRunner` and any other existing conformer compile
    /// unchanged without adopting streaming.
    @discardableResult
    public func run(executable: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval?, onOutputLine: (@Sendable (String) -> Void)?) throws -> ProcessResult {
        try run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
    }
}

public enum ProcessRunError: Error, LocalizedError {
    case launchFailed(String)
    /// Thrown when `timeout` elapses. The process tree rooted at the
    /// spawned child is killed first (not just that one PID) — shell-script
    /// dependencies like Winetricks fork nested subshells, and a bare
    /// `terminate()` on the top PID orphans those instead of ending them.
    case timedOut(seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason): return "Failed to launch process: \(reason)"
        case .timedOut(let seconds): return "Timed out after \(Int(seconds))s with no response — the process (and everything it spawned) was stopped."
        }
    }
}

public final class FoundationProcessRunner: ProcessRunning {
    public init() {}

    @discardableResult
    public func run(executable: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval?) throws -> ProcessResult {
        try run(executable: executable, arguments: arguments, environment: environment, timeout: timeout, onOutputLine: nil)
    }

    /// Real implementation backing both `run` overloads. `onOutputLine`,
    /// when non-nil, gets one call per complete line of stdout/stderr as
    /// the process runs (see the protocol's doc comment); `nil` skips the
    /// line-splitting work entirely, leaving the 4-arg overload's
    /// behavior byte-for-byte identical to before this method existed.
    @discardableResult
    public func run(executable: String, arguments: [String], environment: [String: String]?, timeout: TimeInterval?, onOutputLine: (@Sendable (String) -> Void)?) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Accumulate off the readability handlers (background queue callbacks)
        // instead of `readDataToEndOfFile()` — that call blocks the calling
        // thread until EOF, which would defeat the whole point of racing
        // completion against a timeout below.
        let stdoutBuffer = ProcessOutputBuffer()
        let stderrBuffer = ProcessOutputBuffer()
        let stdoutStreamer = onOutputLine.map { LineStreamer(onLine: $0) }
        let stderrStreamer = onOutputLine.map { LineStreamer(onLine: $0) }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutBuffer.append(data)
                stdoutStreamer?.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrBuffer.append(data)
                stderrStreamer?.append(data)
            }
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw ProcessRunError.launchFailed(error.localizedDescription)
        }

        var timedOut = false
        if let timeout {
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                Self.killProcessTree(rootPID: process.processIdentifier)
                // Give the kill a moment to land, then stop waiting either way
                // — a process that ignores SIGKILL doesn't exist on Darwin.
                _ = exited.wait(timeout: .now() + 5)
            }
        } else {
            exited.wait()
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutStreamer?.flush()
        stderrStreamer?.flush()

        if timedOut {
            throw ProcessRunError.timedOut(seconds: timeout ?? 0)
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutBuffer.data, encoding: .utf8) ?? "",
            stderr: String(data: stderrBuffer.data, encoding: .utf8) ?? ""
        )
    }

    /// Kills `rootPID` and every descendant, deepest first, so nothing gets
    /// orphaned mid-kill (a parent dying before its child gets reparented
    /// to launchd and left running). Walks `ps -axo pid=,ppid=` rather than
    /// relying on process groups — a plain non-interactive `sh <script>`
    /// doesn't get its own group by default, so `killpg` risks taking out
    /// unrelated siblings sharing the caller's group instead.
    private static func killProcessTree(rootPID: pid_t) {
        guard let listing = try? processListing() else {
            kill(rootPID, SIGKILL)
            return
        }
        var childrenByParent: [pid_t: [pid_t]] = [:]
        for (pid, ppid) in listing {
            childrenByParent[ppid, default: []].append(pid)
        }
        var deepestFirst: [pid_t] = []
        func collect(_ pid: pid_t) {
            for child in childrenByParent[pid] ?? [] { collect(child) }
            deepestFirst.append(pid)
        }
        collect(rootPID)
        for pid in deepestFirst {
            kill(pid, SIGKILL)
        }
    }

    private static func processListing() throws -> [(pid_t, pid_t)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else { return nil }
            return (pid, ppid)
        }
    }
}

/// Lock-protected accumulator for pipe bytes collected from a
/// `readabilityHandler` (called on an arbitrary background queue, possibly
/// concurrently between stdout/stderr).
private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return _data
    }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        _data.append(chunk)
    }
}

/// Splits each stream's chunks into complete lines as they arrive,
/// carrying any dangling partial line across chunks — used by
/// `FoundationProcessRunner`'s streaming `run` overload to turn raw pipe
/// bytes into per-line `onOutputLine` callbacks in real time instead of
/// only after the process exits.
private final class LineStreamer: @unchecked Sendable {
    private let lock = NSLock()
    private var remainder = Data()
    private let newline = Data([0x0A])
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        lock.lock()
        remainder.append(chunk)
        var lines: [String] = []
        while let range = remainder.range(of: newline) {
            let lineData = remainder.subdata(in: remainder.startIndex..<range.lowerBound)
            remainder.removeSubrange(remainder.startIndex..<range.upperBound)
            lines.append(String(data: lineData, encoding: .utf8) ?? "")
        }
        lock.unlock()
        for line in lines { onLine(line) }
    }

    /// Flushes a trailing line that never got a terminating newline (e.g.
    /// the process's very last bit of output before exit) so it isn't
    /// silently dropped.
    func flush() {
        lock.lock()
        let trailing = remainder
        remainder = Data()
        lock.unlock()
        guard !trailing.isEmpty, let line = String(data: trailing, encoding: .utf8) else { return }
        onLine(line)
    }
}
