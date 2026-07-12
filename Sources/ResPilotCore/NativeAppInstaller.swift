import Foundation

/// Installs a native macOS app — distributed as a `.zip` containing exactly
/// one `.app` at its root — directly into `/Applications`. No Wine bottle,
/// no Winetricks, no engine download.
///
/// Exists for `CatalogApp.AppInstallKind.nativeMacApp` entries: cases where
/// the vendor's own Windows installer doesn't work reliably under Wine (see
/// that app's `knownIssue`) and a genuinely free, actively-maintained
/// native macOS alternative exists instead. The precedent isn't invented —
/// it's the same substitution CodeWeavers' own official CrossOver guidance
/// makes for Epic Games Store: their support article is literally titled
/// "Open source replacement for Epic Games Launcher" and walks through
/// installing Heroic Games Launcher rather than Epic's own installer
/// (support.codeweavers.com/common-actions/heroic-games-launcher-in-crossover).
/// ResPilot does the same thing, just without requiring CrossOver first.
public final class NativeAppInstaller {
    private let downloader: FileDownloading
    private let processRunner: ProcessRunning
    private let fileManager: FileManager
    private let applicationsDirectory: URL

    public init(
        downloader: FileDownloading = URLSession.shared,
        processRunner: ProcessRunning = FoundationProcessRunner(),
        fileManager: FileManager = .default,
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    ) {
        self.downloader = downloader
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.applicationsDirectory = applicationsDirectory
    }

    /// `source` is either a remote `https://` URL (downloaded here) or a
    /// local `file://` URL (e.g. a path the user already downloaded by
    /// hand, or one `InstallerDownloader` already fetched) — either way, a
    /// `.zip` containing one `.app` at its root. Extracts it, copies the
    /// `.app` into `applicationsDirectory` (replacing any existing copy of
    /// the same name), and clears the quarantine flag the same way
    /// `WineEngineManager` does for its own download. Returns the
    /// installed `.app`'s path.
    @discardableResult
    public func install(
        from source: URL,
        appName: String,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("ResPilotNativeApp-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let zipPath: URL
        if source.isFileURL {
            zipPath = source
        } else {
            onProgress?("Downloading \(appName)…")
            let (data, response) = try await downloader.data(from: source)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                throw NativeAppInstallerError.downloadFailed(source)
            }
            let downloadedZip = tempDir.appendingPathComponent(source.lastPathComponent.isEmpty ? "app.zip" : source.lastPathComponent)
            try data.write(to: downloadedZip, options: .atomic)
            zipPath = downloadedZip
        }

        onProgress?("Extracting \(appName)…")
        let extractDir = tempDir.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let unzipResult = try processRunner.run(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", zipPath.path, extractDir.path],
            environment: ProcessInfo.processInfo.environment,
            timeout: 300
        )
        guard unzipResult.succeeded else {
            throw NativeAppInstallerError.extractionFailed(unzipResult.stderr.isEmpty ? unzipResult.stdout : unzipResult.stderr)
        }

        guard let appBundle = (try? fileManager.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else {
            throw NativeAppInstallerError.noAppBundleFound
        }

        onProgress?("Installing \(appName)…")
        if !fileManager.fileExists(atPath: applicationsDirectory.path) {
            try fileManager.createDirectory(at: applicationsDirectory, withIntermediateDirectories: true)
        }
        let destination = applicationsDirectory.appendingPathComponent(appBundle.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: appBundle, to: destination)

        // Best-effort only, same reasoning as WineEngineManager: direct
        // Process execution isn't gated by quarantine, and this app is
        // launched via LaunchServices (Finder/Dock) where it does matter.
        _ = try? processRunner.run(
            executable: "/usr/bin/xattr",
            arguments: ["-cr", destination.path],
            environment: ProcessInfo.processInfo.environment,
            timeout: 30
        )

        onProgress?("\(appName) installed.")
        return destination.path
    }
}

public enum NativeAppInstallerError: Error, LocalizedError, Equatable {
    case downloadFailed(URL)
    case extractionFailed(String)
    case noAppBundleFound

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let url):
            return "Failed to download from \(url.absoluteString)."
        case .extractionFailed(let reason):
            return "Failed to extract the downloaded archive: \(reason)"
        case .noAppBundleFound:
            return "Downloaded archive did not contain a .app bundle."
        }
    }
}
