import Foundation
import Testing
@testable import ResPilotCore

@Suite struct NativeAppInstallerTests {
    private func makeInstaller(
        processRunner: FakeProcessRunner,
        downloader: FakeFileDownloader,
        applicationsDirectory: URL
    ) -> NativeAppInstaller {
        NativeAppInstaller(
            downloader: downloader,
            processRunner: processRunner,
            applicationsDirectory: applicationsDirectory
        )
    }

    /// `ditto -x -k <zip> <dir>` isn't actually run by the fake — this
    /// simulates what a real extraction would have produced (one `.app`
    /// bundle at the destination root) so the rest of the pipeline
    /// (locate the bundle, copy to Applications, clear quarantine) is
    /// exercised honestly.
    private func simulateExtraction(appName: String, runner: FakeProcessRunner) {
        runner.resultProvider = { invocation in
            if invocation.executable == "/usr/bin/ditto", invocation.arguments.contains("-x") {
                let destDir = URL(fileURLWithPath: invocation.arguments.last!)
                let appBundle = destDir.appendingPathComponent("\(appName).app")
                try? FileManager.default.createDirectory(at: appBundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: appBundle.appendingPathComponent("Contents/MacOS/\(appName)").path, contents: Data("fake binary".utf8))
            }
            return nil
        }
    }

    @Test func downloadsExtractsAndInstallsIntoApplicationsDirectory() async throws {
        let dir = Fixtures.makeTempDirectory("native-app-install")
        defer { try? FileManager.default.removeItem(at: dir) }
        let appsDir = dir.appendingPathComponent("Applications")
        let downloader = FakeFileDownloader()
        downloader.data = Data("fake-zip-bytes".utf8)
        let runner = FakeProcessRunner()
        simulateExtraction(appName: "Heroic", runner: runner)
        let installer = makeInstaller(processRunner: runner, downloader: downloader, applicationsDirectory: appsDir)
        let url = URL(string: "https://github.com/example/Heroic-2.22.0-macOS-arm64.zip")!

        let installedPath = try await installer.install(from: url, appName: "Heroic")

        #expect(installedPath == appsDir.appendingPathComponent("Heroic.app").path)
        #expect(FileManager.default.fileExists(atPath: installedPath))
        #expect(downloader.requestedURLs == [url])
        // ditto extract + xattr clear.
        #expect(runner.invocations.count == 2)
        #expect(runner.invocations[0].executable == "/usr/bin/ditto")
        #expect(runner.invocations[0].arguments.first == "-x")
        #expect(runner.invocations[1].executable == "/usr/bin/xattr")
        #expect(runner.invocations[1].arguments == ["-cr", installedPath])
    }

    @Test func localFileSourceSkipsTheDownload() async throws {
        let dir = Fixtures.makeTempDirectory("native-app-local")
        defer { try? FileManager.default.removeItem(at: dir) }
        let appsDir = dir.appendingPathComponent("Applications")
        let downloader = FakeFileDownloader()
        let runner = FakeProcessRunner()
        simulateExtraction(appName: "Heroic", runner: runner)
        let installer = makeInstaller(processRunner: runner, downloader: downloader, applicationsDirectory: appsDir)
        let localZip = dir.appendingPathComponent("already-downloaded.zip")
        FileManager.default.createFile(atPath: localZip.path, contents: Data("local bytes".utf8))

        let installedPath = try await installer.install(from: localZip, appName: "Heroic")

        #expect(downloader.requestedURLs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: installedPath))
    }

    @Test func replacesAnExistingInstallOfTheSameApp() async throws {
        let dir = Fixtures.makeTempDirectory("native-app-replace")
        defer { try? FileManager.default.removeItem(at: dir) }
        let appsDir = dir.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        let existing = appsDir.appendingPathComponent("Heroic.app")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: existing.appendingPathComponent("stale-marker").path, contents: Data())

        let downloader = FakeFileDownloader()
        let runner = FakeProcessRunner()
        simulateExtraction(appName: "Heroic", runner: runner)
        let installer = makeInstaller(processRunner: runner, downloader: downloader, applicationsDirectory: appsDir)

        let installedPath = try await installer.install(from: URL(string: "https://example.com/Heroic.zip")!, appName: "Heroic")

        #expect(!FileManager.default.fileExists(atPath: existing.appendingPathComponent("stale-marker").path))
        #expect(FileManager.default.fileExists(atPath: installedPath))
    }

    @Test func throwsOnDownloadFailure() async {
        let dir = Fixtures.makeTempDirectory("native-app-download-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = FakeFileDownloader()
        downloader.statusCode = 404
        let installer = makeInstaller(processRunner: FakeProcessRunner(), downloader: downloader, applicationsDirectory: dir.appendingPathComponent("Applications"))
        let url = URL(string: "https://example.com/missing.zip")!

        await #expect(throws: NativeAppInstallerError.downloadFailed(url)) {
            try await installer.install(from: url, appName: "Heroic")
        }
    }

    @Test func throwsOnExtractionFailure() async {
        let dir = Fixtures.makeTempDirectory("native-app-extract-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = FakeFileDownloader()
        let runner = FakeProcessRunner()
        runner.defaultResult = ProcessResult(exitCode: 1, stdout: "", stderr: "ditto: broken archive")
        let installer = makeInstaller(processRunner: runner, downloader: downloader, applicationsDirectory: dir.appendingPathComponent("Applications"))

        await #expect(throws: NativeAppInstallerError.extractionFailed("ditto: broken archive")) {
            try await installer.install(from: URL(string: "https://example.com/Heroic.zip")!, appName: "Heroic")
        }
    }

    @Test func throwsWhenNoAppBundleIsFoundAfterExtraction() async {
        let dir = Fixtures.makeTempDirectory("native-app-no-bundle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = FakeFileDownloader()
        let runner = FakeProcessRunner()
        // ditto "succeeds" but never actually writes an .app (e.g. the
        // zip contained something else entirely).
        let installer = makeInstaller(processRunner: runner, downloader: downloader, applicationsDirectory: dir.appendingPathComponent("Applications"))

        await #expect(throws: NativeAppInstallerError.noAppBundleFound) {
            try await installer.install(from: URL(string: "https://example.com/Heroic.zip")!, appName: "Heroic")
        }
    }
}
