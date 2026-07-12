import CryptoKit
import Foundation

/// A game in a player's Epic library, as reported by Legendary. `title`
/// comes from `app_title` in `legendary list --json` (owned library) or
/// `title` in `legendary list-installed --json` (installed set) — both
/// dataclasses (`Game`/`InstalledGame`, `legendary/models/game.py`) use
/// `app_name` as the stable identifier either way, which is what
/// `LegendaryClient.listGames()` merges the two lists on.
public struct EpicGame: Identifiable, Equatable, Sendable {
    public var id: String { appName }
    /// Legendary's `app_name` — an opaque catalog id, not user-facing.
    public let appName: String
    public let title: String
    /// Non-nil (Legendary's `install_path`) once this game is installed.
    public var installPath: String?

    public init(appName: String, title: String, installPath: String? = nil) {
        self.appName = appName
        self.title = title
        self.installPath = installPath
    }
}

/// Drives Legendary (github.com/derrod/legendary, GPLv3) — the open-source
/// Epic Games CLI client Heroic Games Launcher itself shells out to for
/// every Epic operation (login, library listing, download/install, and
/// launch). ResPilot does the same thing directly, through the same
/// `ProcessRunning` seam already used for Winetricks and the Wine engine,
/// instead of requiring a second app: downloads the standalone macOS
/// binary once to its own support directory (never bundled/redistributed
/// in this repo, same rule as `Winetricks`/`WineEngineManager`), then
/// shells out to it for every Epic operation. Games themselves install
/// under `defaultGamesBasePath` and launch through ResPilot's own Wine
/// engine (`WineEngineManager`) — no CrossOver, no Heroic.
///
/// Every fact this class is pinned to was verified live against the real
/// release binary (`--version`, `status --json`, `auth -h`, `launch -h`
/// under a sandbox `HOME`) and the matching source tag — not guessed:
/// the zip contains exactly one file, `legendary` (Mach-O x86_64, runs
/// under Rosetta 2 exactly like ResPilot's Wine engine), and it does
/// **not** carry the executable bit, so `chmod 755` after extraction is
/// mandatory, not defensive.
public final class LegendaryClient {
    /// Release `0.20.34`, codename "Direct Intervention" — pinned for the
    /// same reason `WineEngineManager`/`AppCatalog` pin their URLs: a
    /// fixed, verified release never breaks or silently drifts under
    /// ResPilot without a code change reviewing the new one first.
    public static let defaultDownloadURL = URL(
        string: "https://github.com/legendary-gl/legendary/releases/download/0.20.34/legendary_macOS.zip"
    )!
    public static let defaultSHA256 = "875e5977697d1fe1bc49ae5fe4a38d904bf62b01eead42f21538c68dc5e0409c"
    /// Where a user signs in; the page then shows JSON containing an
    /// `authorizationCode` field the user copies into ResPilot (source:
    /// `legendary/cli.py:154` at tag `0.20.34`). Non-interactive
    /// (`--disable-webview`) auth is what `login(code:)` performs with it.
    public static let epicLoginURL = URL(string: "https://legendary.gl/epiclogin")!
    /// The single shared `.respilotManaged` bottle every installed Epic
    /// game launches through — matches CrossOver's own Heroic-guide setup
    /// (one bottle for all Epic titles); per-game bottles are a
    /// follow-up, not built here.
    public static let epicBottleName = "EpicGames"
    public static let defaultGamesBasePath = NSString("~/Games/Epic").expandingTildeInPath

    private static let loggedOutSentinel = "<not logged in>"

    private let processRunner: ProcessRunning
    private let fileManager: FileManager
    private let downloader: FileDownloading
    public let binaryURL: URL

    public init(
        processRunner: ProcessRunning = FoundationProcessRunner(),
        fileManager: FileManager = .default,
        downloader: FileDownloading = URLSession.shared,
        binaryURL: URL? = nil
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.downloader = downloader
        self.binaryURL = binaryURL ?? Self.defaultBinaryURL()
    }

    /// Sibling of `Winetricks.defaultScriptURL()` — same support directory,
    /// same "ResPilot's own state, respects `RESPILOT_HOME`" convention.
    public static func defaultBinaryURL(
        homeDirectory: URL = ResPilotEnvironment.resolvedHomeDirectory()
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/ResPilot", isDirectory: true)
            .appendingPathComponent("legendary")
    }

    public var isInstalled: Bool { fileManager.isExecutableFile(atPath: binaryURL.path) }

    /// Downloads `url`, verifies it against `sha256`, extracts it via the
    /// system `ditto` (a plain zip; no external decoder needed, unlike the
    /// Wine engine's `.tar.xz`), marks the extracted `legendary` binary
    /// executable (the zip does not carry the bit itself — verified), and
    /// clears the quarantine flag. A no-op if already installed. Mirrors
    /// `WineEngineManager.install`'s shape exactly, just against a zip
    /// instead of a tarball.
    @discardableResult
    public func install(
        from url: URL = defaultDownloadURL,
        sha256: String? = defaultSHA256,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        if isInstalled { return binaryURL.path }

        onProgress?("Downloading Legendary (open-source Epic Games client, one-time, ~7MB)…")
        let (data, response) = try await downloader.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw LegendaryClientError.downloadFailed(url)
        }
        if let sha256 {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == sha256 else {
                throw LegendaryClientError.checksumMismatch(expected: sha256, actual: digest)
            }
        }

        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("ResPilotLegendary-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        let zipPath = tempDir.appendingPathComponent(url.lastPathComponent.isEmpty ? "legendary.zip" : url.lastPathComponent)
        try data.write(to: zipPath, options: .atomic)

        onProgress?("Extracting Legendary…")
        let extractDir = tempDir.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let extractResult = try processRunner.run(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", zipPath.path, extractDir.path],
            environment: ProcessInfo.processInfo.environment,
            timeout: 60
        )
        guard extractResult.succeeded else {
            throw LegendaryClientError.extractionFailed(extractResult.stderr.isEmpty ? extractResult.stdout : extractResult.stderr)
        }

        guard let extractedBinary = Self.locateExtractedBinary(in: extractDir, fileManager: fileManager) else {
            throw LegendaryClientError.extractionFailed("No file found in the downloaded archive at \(extractDir.path).")
        }

        let parentDirectory = binaryURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDirectory.path) {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: binaryURL.path) {
            try fileManager.removeItem(at: binaryURL)
        }
        try fileManager.copyItem(at: extractedBinary, to: binaryURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        // Best-effort only — same reasoning as WineEngineManager/
        // NativeAppInstaller: direct Process execution isn't gated by
        // quarantine, so a failure here is never fatal to installability.
        _ = try? processRunner.run(
            executable: "/usr/bin/xattr",
            arguments: ["-cr", binaryURL.path],
            environment: ProcessInfo.processInfo.environment,
            timeout: 30
        )

        guard isInstalled else {
            throw LegendaryClientError.extractionFailed("legendary not found at \(binaryURL.path) after extraction.")
        }
        onProgress?("Legendary ready.")
        return binaryURL.path
    }

    /// The file literally named `legendary` if present; otherwise the
    /// first regular file at the extract root (defensive — the zip is
    /// documented to contain exactly `legendary` at its root, but a
    /// future release changing that shouldn't hard-fail installation).
    private static func locateExtractedBinary(in directory: URL, fileManager: FileManager) -> URL? {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        func isRegularFile(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        if let named = entries.first(where: { $0.lastPathComponent == "legendary" }), isRegularFile(named) {
            return named
        }
        return entries.first(where: isRegularFile)
    }

    /// Non-interactive login with the `authorizationCode` copied from the
    /// JSON page shown after signing in at `epicLoginURL`.
    public func login(code: String) throws {
        try runCommand(["auth", "--code", code, "--disable-webview"], timeout: 120)
    }

    public func logout() throws {
        try runCommand(["auth", "--delete"], timeout: 30)
    }

    /// `nil` means logged out. Parses stdout only — Legendary logs to
    /// stderr and prints its JSON payload to stdout — and defensively
    /// takes the substring starting at the first `{`/`[` in case any
    /// non-JSON text precedes it.
    public func accountName() throws -> String? {
        let result = try runCommand(["status", "--json"], timeout: 120)
        guard
            let object = try? JSONSerialization.jsonObject(with: Self.jsonPayload(from: result.stdout)) as? [String: Any],
            let account = object["account"] as? String,
            account != Self.loggedOutSentinel
        else {
            return nil
        }
        return account
    }

    /// Merges the owned library (`list --platform Windows --json`) with
    /// the installed set (`list-installed --json --show-dirs`) on
    /// `app_name`, sorted by title. Installed entries absent from the
    /// owned list (e.g. hidden UE assets) are still included, using their
    /// own `title`. `list-installed` exiting non-zero when nothing is
    /// installed yet (verified live) is treated as "installed set is
    /// empty," not a failure of this call.
    public func listGames() throws -> [EpicGame] {
        let ownedResult = try runCommand(["list", "--platform", "Windows", "--json"], timeout: 300)
        let owned = try JSONDecoder().decode([LegendaryOwnedGameDTO].self, from: Self.jsonPayload(from: ownedResult.stdout))

        var installedByAppName: [String: LegendaryInstalledGameDTO] = [:]
        do {
            let installedResult = try runCommand(["list-installed", "--json", "--show-dirs"], timeout: 120)
            let installed = try JSONDecoder().decode([LegendaryInstalledGameDTO].self, from: Self.jsonPayload(from: installedResult.stdout))
            installedByAppName = Dictionary(uniqueKeysWithValues: installed.map { ($0.appName, $0) })
        } catch {
            // Nothing installed yet — an empty install set, not a failed
            // listGames() call. See the doc comment above.
        }

        var gamesByAppName: [String: EpicGame] = [:]
        for game in owned {
            gamesByAppName[game.appName] = EpicGame(
                appName: game.appName,
                title: game.appTitle,
                installPath: installedByAppName[game.appName]?.installPath
            )
        }
        for (appName, installed) in installedByAppName where gamesByAppName[appName] == nil {
            gamesByAppName[appName] = EpicGame(appName: appName, title: installed.title, installPath: installed.installPath)
        }
        return gamesByAppName.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Downloads and installs `appName` into `basePath` (created first if
    /// needed). GB-scale, can take hours — uses the streaming `run`
    /// overload so every non-empty output line reaches `onProgress` as it
    /// happens, instead of only after the whole download completes.
    public func installGame(
        appName: String,
        basePath: String = defaultGamesBasePath,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) throws {
        guard isInstalled else { throw LegendaryClientError.notInstalled }
        try fileManager.createDirectory(atPath: basePath, withIntermediateDirectories: true)
        let result = try processRunner.run(
            executable: binaryURL.path,
            arguments: ["-y", "install", appName, "--base-path", basePath, "--platform", "Windows", "--skip-dlcs", "--skip-sdl"],
            environment: ProcessInfo.processInfo.environment,
            timeout: 21_600,
            onOutputLine: { line in
                guard !line.isEmpty else { return }
                onProgress?(line)
            }
        )
        guard result.succeeded else {
            throw LegendaryClientError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    /// Runs `appName` under `wineBinary`/`winePrefix` — a user-controlled
    /// game session, so `timeout` is deliberately `nil` (see the doc
    /// comment on `ProcessRunning.run`'s `timeout` parameter): this call
    /// blocks until the player quits the game.
    public func launch(appName: String, wineBinary: String, winePrefix: String) throws {
        var env = ProcessInfo.processInfo.environment
        env["WINEDEBUG"] = "-all"
        try runCommand(["launch", appName, "--wine", wineBinary, "--wine-prefix", winePrefix], timeout: nil, environment: env)
    }

    public func uninstallGame(appName: String) throws {
        try runCommand(["-y", "uninstall", appName], timeout: 300)
    }

    @discardableResult
    private func runCommand(
        _ arguments: [String],
        timeout: TimeInterval?,
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        guard isInstalled else { throw LegendaryClientError.notInstalled }
        let result = try processRunner.run(
            executable: binaryURL.path,
            arguments: arguments,
            environment: environment ?? ProcessInfo.processInfo.environment,
            timeout: timeout
        )
        guard result.succeeded else {
            throw LegendaryClientError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }

    /// Defensive substring starting at the first `{`/`[` in `stdout`, so a
    /// stray non-JSON line ahead of Legendary's actual payload doesn't
    /// break parsing.
    private static func jsonPayload(from stdout: String) -> Data {
        guard let index = stdout.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return Data(stdout.utf8)
        }
        return Data(stdout[index...].utf8)
    }
}

/// `legendary list --json` element shape (dataclass `Game`,
/// `legendary/models/game.py`) — only the two fields ResPilot needs.
private struct LegendaryOwnedGameDTO: Decodable {
    let appName: String
    let appTitle: String

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case appTitle = "app_title"
    }
}

/// `legendary list-installed --json --show-dirs` element shape (dataclass
/// `InstalledGame`, `legendary/models/game.py:131`) — only the fields
/// ResPilot needs.
private struct LegendaryInstalledGameDTO: Decodable {
    let appName: String
    let title: String
    let installPath: String?

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case title
        case installPath = "install_path"
    }
}

public enum LegendaryClientError: Error, LocalizedError, Equatable {
    case notInstalled
    case downloadFailed(URL)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case commandFailed(String)
    case notLoggedIn

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Legendary (the Epic Games client) isn't set up yet."
        case .downloadFailed(let url):
            return "Failed to download Legendary from \(url.absoluteString)."
        case .checksumMismatch(let expected, let actual):
            return "Downloaded Legendary failed its integrity check (expected \(expected), got \(actual)) — try again."
        case .extractionFailed(let reason):
            return "Failed to extract Legendary: \(reason)"
        case .commandFailed(let reason):
            return "Legendary failed: \(reason)"
        case .notLoggedIn:
            return "Not logged into Epic Games — log in first."
        }
    }
}
