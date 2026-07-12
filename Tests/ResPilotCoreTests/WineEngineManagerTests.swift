import CryptoKit
import Foundation
import Testing
@testable import ResPilotCore

@Suite struct WineEngineManagerTests {
    private func binDirectory(under engineDirectory: URL) -> URL {
        engineDirectory.appendingPathComponent("Wine Staging.app/Contents/Resources/wine/bin", isDirectory: true)
    }

    @Test func isInstalledFalseBeforeInstall() {
        let dir = Fixtures.makeTempDirectory("wine-engine-not-installed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = WineEngineManager(engineDirectory: dir)

        #expect(!manager.isInstalled)
    }

    @Test func installIsANoOpWhenAlreadyInstalled() async throws {
        let dir = Fixtures.makeTempDirectory("wine-engine-already")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = binDirectory(under: dir)
        Fixtures.writeFile(bin.appendingPathComponent("wine"), executable: true)
        let downloader = FakeFileDownloader()
        let runner = FakeProcessRunner()
        let manager = WineEngineManager(processRunner: runner, downloader: downloader, engineDirectory: dir)

        let path = try await manager.install()

        #expect(path == bin.appendingPathComponent("wine").path)
        #expect(downloader.requestedURLs.isEmpty) // never touches the network once already installed
        #expect(runner.invocations.isEmpty)
    }

    @Test func installDownloadsVerifiesExtractsAndClearsQuarantine() async throws {
        let dir = Fixtures.makeTempDirectory("wine-engine-install")
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = FakeFileDownloader()
        downloader.data = Data("fake-tarball-bytes".utf8)
        let expectedSHA = SHA256.hash(data: downloader.data).map { String(format: "%02x", $0) }.joined()

        let runner = FakeProcessRunner()
        let bin = binDirectory(under: dir)
        runner.resultProvider = { invocation in
            if invocation.executable == "/usr/bin/tar" {
                // Simulate a real extraction landing the expected binary —
                // the fake never actually runs `tar`.
                Fixtures.writeFile(bin.appendingPathComponent("wine"), executable: true)
            }
            return nil // fall back to defaultResult (exit 0)
        }
        let manager = WineEngineManager(processRunner: runner, downloader: downloader, engineDirectory: dir)
        let url = URL(string: "https://example.com/wine-stable-test.tar.xz")!

        let path = try await manager.install(from: url, sha256: expectedSHA)

        #expect(path == bin.appendingPathComponent("wine").path)
        #expect(manager.isInstalled)
        #expect(downloader.requestedURLs == [url])
        #expect(runner.invocations.count == 2) // tar extract + xattr clear
        #expect(runner.invocations[0].executable == "/usr/bin/tar")
        #expect(runner.invocations[0].arguments.first == "-xJf")
        #expect(runner.invocations[0].arguments.last == dir.path)
        #expect(runner.invocations[0].timeout == 300)
        #expect(runner.invocations[1].executable == "/usr/bin/xattr")
        #expect(runner.invocations[1].arguments == ["-cr", dir.path])
    }

    @Test func installThrowsOnChecksumMismatchAndNeverAttemptsExtraction() async {
        let dir = Fixtures.makeTempDirectory("wine-engine-checksum")
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = FakeFileDownloader()
        downloader.data = Data("not-the-real-tarball".utf8)
        let runner = FakeProcessRunner()
        let manager = WineEngineManager(processRunner: runner, downloader: downloader, engineDirectory: dir)
        let bogusSHA = String(repeating: "0", count: 64)

        await #expect(throws: WineEngineManagerError.self) {
            try await manager.install(sha256: bogusSHA)
        }
        #expect(runner.invocations.isEmpty)
        #expect(!manager.isInstalled)
    }

    @Test func installThrowsOnNonSuccessStatus() async {
        let dir = Fixtures.makeTempDirectory("wine-engine-bad-status")
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = FakeFileDownloader()
        downloader.statusCode = 404
        let url = URL(string: "https://example.com/wine-stable-test.tar.xz")!
        let manager = WineEngineManager(processRunner: FakeProcessRunner(), downloader: downloader, engineDirectory: dir)

        await #expect(throws: WineEngineManagerError.downloadFailed(url)) {
            try await manager.install(from: url, sha256: nil)
        }
    }

    @Test func installThrowsWhenExtractionFails() async {
        let dir = Fixtures.makeTempDirectory("wine-engine-extract-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = FakeFileDownloader()
        let runner = FakeProcessRunner()
        runner.resultProvider = { invocation in
            invocation.executable == "/usr/bin/tar" ? ProcessResult(exitCode: 1, stdout: "", stderr: "tar: bad archive") : nil
        }
        let manager = WineEngineManager(processRunner: runner, downloader: downloader, engineDirectory: dir)

        await #expect(throws: WineEngineManagerError.extractionFailed("tar: bad archive")) {
            try await manager.install(sha256: nil)
        }
    }

    @Test func binaryPathsAreSiblingsUnderTheStandardWineHQLayout() {
        let dir = Fixtures.makeTempDirectory("wine-engine-paths")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = WineEngineManager(engineDirectory: dir)
        let bin = binDirectory(under: dir)

        #expect(manager.wineBinaryPath == bin.appendingPathComponent("wine").path)
        #expect(manager.winebootPath == bin.appendingPathComponent("wineboot").path)
        #expect(manager.wineserverPath == bin.appendingPathComponent("wineserver").path)
    }
}
