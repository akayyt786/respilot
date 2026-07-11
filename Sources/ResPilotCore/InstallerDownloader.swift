import Foundation

/// Downloads the installer a `CatalogApp.directDownloadURL` points at, so
/// "Install" can genuinely be one click instead of requiring a manual
/// detour through the vendor's website and a file picker.
///
/// Every URL in `AppCatalog` was found by inspecting each vendor's own
/// download page — not guessed, not from a third-party mirror — and lands
/// on that vendor's own domain (steamstatic.com, epicgames.com,
/// rockstargames.com). Vendors can still change these without notice,
/// which is exactly why `AppModel`/`cmdInstallApp` also accept a manually
/// downloaded file as a fallback.
public final class InstallerDownloader {
    private let downloader: FileDownloading
    private let fileManager: FileManager

    public init(downloader: FileDownloading = URLSession.shared, fileManager: FileManager = .default) {
        self.downloader = downloader
        self.fileManager = fileManager
    }

    /// Downloads `url` into a freshly created temp directory, keeping the
    /// URL's own filename (e.g. "SteamSetup.exe") so it still looks like a
    /// normal installer to Wine. Returns the local file's URL.
    public func download(_ url: URL) async throws -> URL {
        let (data, response) = try await downloader.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw InstallerDownloaderError.downloadFailed(url)
        }
        let filename = url.lastPathComponent.isEmpty ? "installer.exe" : url.lastPathComponent
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("ResPilotInstaller-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}

public enum InstallerDownloaderError: Error, LocalizedError, Equatable {
    case downloadFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let url):
            return "Failed to download the installer from \(url.absoluteString)."
        }
    }
}
