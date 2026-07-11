import Foundation
import Testing
@testable import ResPilotCore

@Suite struct InstallerDownloaderTests {
    @Test func downloadsToATempFileKeepingTheURLsFilename() async throws {
        let downloader = FakeFileDownloader()
        downloader.data = Data("fake-installer-bytes".utf8)
        let installerDownloader = InstallerDownloader(downloader: downloader)

        let localURL = try await installerDownloader.download(URL(string: "https://cdn.example.com/client/installer/SteamSetup.exe")!)
        defer { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }

        #expect(localURL.lastPathComponent == "SteamSetup.exe")
        #expect(FileManager.default.fileExists(atPath: localURL.path))
        let contents = try Data(contentsOf: localURL)
        #expect(contents == Data("fake-installer-bytes".utf8))
    }

    @Test func throwsOnNonSuccessStatus() async {
        let downloader = FakeFileDownloader()
        downloader.statusCode = 404
        let installerDownloader = InstallerDownloader(downloader: downloader)
        let url = URL(string: "https://cdn.example.com/missing.exe")!

        await #expect(throws: InstallerDownloaderError.downloadFailed(url)) {
            try await installerDownloader.download(url)
        }
    }

    @Test func throwsOnEmptyBody() async {
        let downloader = FakeFileDownloader()
        downloader.data = Data()
        let installerDownloader = InstallerDownloader(downloader: downloader)
        let url = URL(string: "https://cdn.example.com/empty.exe")!

        await #expect(throws: InstallerDownloaderError.downloadFailed(url)) {
            try await installerDownloader.download(url)
        }
    }

    @Test func requestsExactlyTheGivenURL() async throws {
        let downloader = FakeFileDownloader()
        let installerDownloader = InstallerDownloader(downloader: downloader)
        let url = URL(string: "https://gamedownloads.rockstargames.com/public/installer/Rockstar-Games-Launcher.exe")!

        let localURL = try await installerDownloader.download(url)
        defer { try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent()) }

        #expect(downloader.requestedURLs == [url])
    }
}
