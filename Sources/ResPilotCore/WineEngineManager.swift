import CryptoKit
import Foundation

/// Manages ResPilot's own free, self-contained Wine engine so "Install App"
/// (and any `.respilotManaged` bottle) never requires CrossOver — or
/// anything else — to be installed first. Downloads a pinned release of
/// the community-maintained WineHQ macOS builds
/// (github.com/Gcenx/macOS_Wine_builds) — the exact same upstream
/// Homebrew's own `wine@staging` cask installs from (see that cask's
/// formula for the identical URL/bundle layout this was verified against,
/// not guessed). Wine itself is GNU LGPL v2.1+ and freely redistributable;
/// ResPilot never bundles the binary in the repo or the app bundle, only
/// fetches it once to its own support directory — exactly the way it
/// already does for the Winetricks script (see `Winetricks.install`).
///
/// Deliberately **not** `wine-stable`: verified live (booting a real
/// prefix with `wineboot --init`, not just reading changelogs) that
/// `wine-stable` fails on Apple Silicon macOS Sequoia with "could not
/// load kernel32.dll, status c0000135" — a known issue (Homebrew's own
/// `wine-stable` cask already carries `disable! … :fails_gatekeeper_check`
/// ahead of a 2026-09-01 removal; Gcenx/macOS_Wine_builds discussion and
/// the WineHQ forums both point at `wine@devel`/`wine@staging` — which
/// carry additional Apple Silicon/Sequoia patches — as the working
/// channel instead). Confirmed by switching to `wine@staging` and
/// re-running the exact same `wineboot --init` against a real macOS 15
/// (Sequoia) Apple Silicon Mac: prefix boots cleanly (WOW64 layout,
/// `wine --version` reports `wine-11.10 (Staging)`), and a `wine reg add`
/// round-trips correctly through `user.reg` — the same operation
/// `WineRegistry.apply` performs against every bottle ResPilot manages.
///
/// Pinned to a specific version + sha256 (not "latest") on purpose — same
/// reasoning as `AppCatalog`'s direct download URLs: a fixed, verified
/// release never breaks or silently drifts under ResPilot without a code
/// change reviewing the new one first.
public final class WineEngineManager {
    /// The exact release this ships against — `Gcenx/macOS_Wine_builds`
    /// tag `11.10`, the same one Homebrew's `wine@staging` cask points at
    /// as of this writing. sha256 copied from that cask's own formula
    /// (Homebrew-audited) and re-verified against a real download before
    /// shipping this.
    public static let defaultDownloadURL = URL(
        string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.10/wine-staging-11.10-osx64.tar.xz"
    )!
    public static let defaultSHA256 = "940bdd1a177872020be01c5c33917cb8eecc1cc3193ad554914fb6efd90d7889"

    /// Root `.app` bundle name inside the tarball — WineHQ's standard
    /// macOS package layout (`Contents/Resources/wine/bin/...`), the same
    /// one Homebrew's `wine@staging` cask installs to `/Applications`
    /// under. ResPilot keeps its own private copy under its own support
    /// directory instead, so it never depends on, or collides with, a
    /// Homebrew-managed install.
    private static let bundleName = "Wine Staging.app"

    private let processRunner: ProcessRunning
    private let fileManager: FileManager
    private let downloader: FileDownloading
    public let engineDirectory: URL

    public init(
        processRunner: ProcessRunning = FoundationProcessRunner(),
        fileManager: FileManager = .default,
        downloader: FileDownloading = URLSession.shared,
        engineDirectory: URL? = nil
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.downloader = downloader
        self.engineDirectory = engineDirectory ?? Self.defaultEngineDirectory()
    }

    public static func defaultEngineDirectory(
        homeDirectory: URL = ResPilotEnvironment.resolvedHomeDirectory()
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/ResPilot", isDirectory: true)
            .appendingPathComponent("WineEngine", isDirectory: true)
    }

    private var binDirectory: URL {
        engineDirectory
            .appendingPathComponent(Self.bundleName, isDirectory: true)
            .appendingPathComponent("Contents/Resources/wine/bin", isDirectory: true)
    }

    /// The Wine loader every `.respilotManaged` bottle addresses (see
    /// `BottleKind.respilotManaged`). Modern WineHQ macOS packages (this
    /// one included, verified against the real tarball — not assumed)
    /// consolidated to a single 64-bit-native `wine` binary with WOW64
    /// built in; there is no separate `wine64` in this bundle, matching
    /// the same "always WOW64" intent as CrossOver's own `win10_64`
    /// template.
    public var wineBinaryPath: String { binDirectory.appendingPathComponent("wine").path }
    public var winebootPath: String { binDirectory.appendingPathComponent("wineboot").path }
    public var wineserverPath: String { binDirectory.appendingPathComponent("wineserver").path }

    public var isInstalled: Bool { fileManager.fileExists(atPath: wineBinaryPath) }

    /// Downloads `url`, verifies it against `sha256` (defends against a
    /// truncated/corrupted transfer over a plain HTTPS GET with no other
    /// integrity check for a ~190MB file), extracts it via the system
    /// `tar` (it's `.tar.xz`; Foundation has no built-in xz decoder), and
    /// clears the quarantine flag Gatekeeper stamps on anything
    /// downloaded — not because a direct `Process` launch would be
    /// blocked by it (it isn't; quarantine only intercepts the Launch
    /// Services `open()` path a double-clicked `.app` goes through), but
    /// so nothing about the extracted bundle surprises a user who goes
    /// looking at it by hand later. A no-op if the engine is already
    /// installed.
    @discardableResult
    public func install(
        from url: URL = defaultDownloadURL,
        sha256: String? = defaultSHA256,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        if isInstalled { return wineBinaryPath }

        onProgress?("Downloading free Wine engine (one-time, ~190MB)…")
        let (data, response) = try await downloader.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw WineEngineManagerError.downloadFailed(url)
        }
        if let sha256 {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == sha256 else {
                throw WineEngineManagerError.checksumMismatch(expected: sha256, actual: digest)
            }
        }

        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("ResPilotWineEngine-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        let archivePath = tempDir.appendingPathComponent(url.lastPathComponent)
        try data.write(to: archivePath, options: .atomic)

        onProgress?("Extracting Wine engine…")
        if fileManager.fileExists(atPath: engineDirectory.path) {
            try fileManager.removeItem(at: engineDirectory)
        }
        try fileManager.createDirectory(at: engineDirectory, withIntermediateDirectories: true)
        let extractResult = try processRunner.run(
            executable: "/usr/bin/tar",
            arguments: ["-xJf", archivePath.path, "-C", engineDirectory.path],
            environment: ProcessInfo.processInfo.environment,
            timeout: 300
        )
        guard extractResult.succeeded else {
            throw WineEngineManagerError.extractionFailed(extractResult.stderr.isEmpty ? extractResult.stdout : extractResult.stderr)
        }

        // Best-effort only: direct `Process` execution isn't gated by
        // quarantine, so a failure here is never fatal to installability.
        _ = try? processRunner.run(
            executable: "/usr/bin/xattr",
            arguments: ["-cr", engineDirectory.path],
            environment: ProcessInfo.processInfo.environment,
            timeout: 30
        )

        guard isInstalled else {
            throw WineEngineManagerError.extractionFailed("wine not found at \(wineBinaryPath) after extraction.")
        }
        onProgress?("Wine engine ready.")
        return wineBinaryPath
    }
}

public enum WineEngineManagerError: Error, LocalizedError, Equatable {
    case downloadFailed(URL)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let url):
            return "Failed to download the Wine engine from \(url.absoluteString)."
        case .checksumMismatch(let expected, let actual):
            return "Downloaded Wine engine failed its integrity check (expected \(expected), got \(actual)) — try again."
        case .extractionFailed(let reason):
            return "Failed to extract the Wine engine: \(reason)"
        }
    }
}
