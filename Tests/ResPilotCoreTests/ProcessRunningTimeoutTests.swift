import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
@testable import ResPilotCore

/// Exercises `FoundationProcessRunner`'s timeout against real spawned
/// processes — no fakes. This is what a Winetricks verb hanging (found by
/// reproducing it for real: a stalled step, no subprocess left, no network
/// activity, still "installing" 30+ minutes later with zero way back for
/// the caller) actually needs: a bounded wait, and every descendant the
/// hung shell forked along the way actually gone afterward, not orphaned.
@Suite struct ProcessRunningTimeoutTests {
    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    @Test func processCompletingBeforeTimeoutReturnsNormally() throws {
        let runner = FoundationProcessRunner()
        let result = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo hi"],
            environment: nil,
            timeout: 5
        )
        #expect(result.succeeded)
        #expect(result.stdout == "hi\n")
    }

    @Test func processExceedingTimeoutThrowsPromptlyInsteadOfWaitingTheFullSleep() throws {
        let runner = FoundationProcessRunner()
        let start = Date()

        #expect(throws: ProcessRunError.self) {
            try runner.run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 30"],
                environment: nil,
                timeout: 1
            )
        }

        // The whole point of the fix: this returns close to the 1s bound,
        // not anywhere near the 30s the hung process asked to sleep for.
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func killsTheFullDescendantTreeNotJustTheDirectChild() throws {
        let dir = Fixtures.makeTempDirectory("process-timeout-tree")
        defer { try? FileManager.default.removeItem(at: dir) }
        let parentPIDFile = dir.appendingPathComponent("parent.pid").path
        let childPIDFile = dir.appendingPathComponent("child.pid").path

        // The parent shell forks a background grandchild, records both
        // PIDs to disk, then blocks on `wait` — mirroring exactly the
        // shape that produced the real hang (winetricks re-execing/forking
        // nested shells, one of which stalls with the ancestor just
        // sitting in `wait`).
        let script = """
        echo $$ > \(parentPIDFile)
        (sh -c 'echo $$ > \(childPIDFile); sleep 30') &
        wait
        """

        let runner = FoundationProcessRunner()
        #expect(throws: ProcessRunError.self) {
            try runner.run(executable: "/bin/sh", arguments: ["-c", script], environment: nil, timeout: 2)
        }

        // Give the filesystem a moment in case the grandchild's own write
        // raced the timeout (it's given a full 2s head start above, but be
        // defensive rather than flaky).
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: childPIDFile), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        let parentPID = try #require(pid_t(String(contentsOfFile: parentPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let childPID = try #require(pid_t(String(contentsOfFile: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))

        #expect(!isAlive(parentPID), "direct child should be dead")
        #expect(!isAlive(childPID), "grandchild forked by the hung script should be dead too, not orphaned")
    }
}
