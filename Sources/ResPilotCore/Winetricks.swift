import Foundation

/// Thin wrapper around the upstream Winetricks script
/// (https://github.com/Winetricks/winetricks, GNU LGPL v2.1) — the same
/// open-source dependency-installer Bottles, Lutris, and Sikarugir itself
/// use to silently provision things like Visual C++ redistributables,
/// .NET, and core fonts into a Wine prefix. ResPilot does not reimplement
/// any of that; it downloads the upstream script once (to its own support
/// directory, never bundled/redistributed in the repo) and shells out to
/// it, exactly the way any of those other tools do.
///
/// Verified from the script's own source before wiring this up (never
/// guessed): `-q`/`--unattended` is the documented unattended-install flag,
/// and `WINE`/`WINEPREFIX`/`WINESERVER` are the environment variables it
/// reads to target a specific bottle instead of whatever `wine` resolves
/// to on `PATH` (falls back to plain `wine` when `WINE` is unset).
public final class Winetricks {
    private let processRunner: ProcessRunning
    private let fileManager: FileManager
    private let downloader: FileDownloading
    public let scriptURL: URL

    public init(
        processRunner: ProcessRunning = FoundationProcessRunner(),
        fileManager: FileManager = .default,
        downloader: FileDownloading = URLSession.shared,
        scriptURL: URL? = nil
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.downloader = downloader
        self.scriptURL = scriptURL ?? Self.defaultScriptURL()
    }

    public static func defaultScriptURL(
        homeDirectory: URL = ResPilotEnvironment.resolvedHomeDirectory()
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/ResPilot", isDirectory: true)
            .appendingPathComponent("winetricks")
    }

    public var isInstalled: Bool { fileManager.fileExists(atPath: scriptURL.path) }

    /// Downloads the upstream script from its canonical GitHub raw URL and
    /// marks it executable. Safe to call repeatedly — overwrites in place,
    /// so calling this again doubles as "update to latest".
    public func install(
        from remoteURL: URL = URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks")!
    ) async throws {
        let directory = scriptURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let (data, response) = try await downloader.data(from: remoteURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw WinetricksError.downloadFailed
        }
        try data.write(to: scriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Runs `winetricks -q <verbs...>` against `bottle`, pointing `WINE`
    /// and `WINEPREFIX` at that specific bottle rather than letting
    /// Winetricks fall back to a `wine` found on `PATH`. Bounded by
    /// `timeout` (default 30 minutes, covering the whole batch of
    /// `verbs`) — found this needed by reproducing a real hang: a verb's
    /// download stalled mid-run with no subprocess left to inspect and no
    /// network activity, and a bare `Process` + `waitUntilExit()` sat
    /// blocked indefinitely with no way back for the caller. `nil` opts
    /// back into waiting forever, for callers that want that.
    ///
    /// `.crossOver` bottles need two extra fixups beyond plain env vars —
    /// both found by actually running Winetricks against a real CrossOver
    /// bottle, not guessed:
    /// 1. CrossOver's `wine` is a *shared* binary addressed via
    ///    `--bottle <name>`; a bare `WINE=<path>` (no `--bottle`) makes it
    ///    silently target the nonexistent "default" bottle. Since an env
    ///    var can't carry extra argv, `WINE` is pointed at a tiny
    ///    generated wrapper script that bakes the flag in.
    /// 2. CrossOver's `wine` is a Perl dispatcher script, not a Mach-O
    ///    binary. Winetricks' own arch auto-detection shells out to
    ///    `lipo` on whatever `WINE` resolves to, which fatals against a
    ///    text file ("can't figure out the architecture type of...").
    ///    Winetricks' own docs name the fix: set `WINE_BIN`/
    ///    `WINESERVER_BIN` to the *actual* Mach-O binaries so it inspects
    ///    those instead — CrossOver ships them as `wineloader` (wine) and
    ///    `wineserver` (already Mach-O) alongside the `wine` script.
    @discardableResult
    public func run(verbs: [String], in bottle: WineBottleTarget, timeout: TimeInterval? = 1800) throws -> ProcessResult {
        guard isInstalled else { throw WinetricksError.notInstalled }
        guard !verbs.isEmpty else { throw WinetricksError.noVerbs }

        let binDirectory = URL(fileURLWithPath: bottle.wineBinaryPath).deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.prefixPath
        env["WINEDEBUG"] = "-all"

        switch bottle.kind {
        case .crossOver:
            guard let name = bottle.crossOverBottleName, !name.isEmpty else {
                throw WinetricksError.verbFailed("Bottle is missing its CrossOver bottle name.")
            }
            let wrapperURL = scriptURL.deletingLastPathComponent()
                .appendingPathComponent("wine-wrapper-\(Self.sanitize(name)).sh")
            let wrapperScript = "#!/bin/sh\nexec \"\(bottle.wineBinaryPath)\" --bottle \"\(name)\" \"$@\"\n"
            try wrapperScript.write(to: wrapperURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)
            env["WINE"] = wrapperURL.path

            let wineLoaderPath = binDirectory.appendingPathComponent("wineloader").path
            if fileManager.fileExists(atPath: wineLoaderPath) {
                env["WINE_BIN"] = wineLoaderPath
            }
            let wineServerPath = binDirectory.appendingPathComponent("wineserver").path
            env["WINESERVER"] = wineServerPath
            if fileManager.fileExists(atPath: wineServerPath) {
                env["WINESERVER_BIN"] = wineServerPath
            }
        case .wineskinStyle, .respilotManaged:
            env["WINE"] = bottle.wineBinaryPath
            env["WINESERVER"] = binDirectory.appendingPathComponent("wineserver").path
        }

        let result = try processRunner.run(
            executable: "/bin/sh",
            arguments: [scriptURL.path, "-q"] + verbs,
            environment: env,
            timeout: timeout
        )
        guard result.succeeded else {
            throw WinetricksError.verbFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }

    private static func sanitize(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }
}

public enum WinetricksError: Error, LocalizedError, Equatable {
    case notInstalled
    case downloadFailed
    case noVerbs
    case verbFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Winetricks isn't set up yet."
        case .downloadFailed:
            return "Failed to download Winetricks."
        case .noVerbs:
            return "No Winetricks verbs specified."
        case .verbFailed(let reason):
            return "Winetricks failed: \(reason)"
        }
    }
}

