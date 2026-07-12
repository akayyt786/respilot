import Foundation

/// Creates a fresh bottle — either a CrossOver bottle (via `cxbottle`) or a
/// ResPilot-managed one (via `wineboot --init` against ResPilot's own
/// downloaded engine, see `WineEngineManager`). `.wineskinStyle` bottles
/// are still unsupported here: a Wineskin/Sikarugir bottle *is* its
/// wrapper `.app`, built by that app's own template tooling, and there is
/// no equivalent single command to shell out to for it.
///
/// Verified against a real CrossOver install before shipping the
/// `.crossOver` path, not assumed: `wine wineboot -u` (what an earlier
/// version of this file used) does **not** create a new CrossOver bottle —
/// CrossOver's `wine` wrapper refuses to operate on a `--bottle <name>`
/// that doesn't already exist ("Unable to find the '<name>' bottle"), even
/// if the target directory is pre-created by hand. The actual, documented
/// tool for this is `cxbottle` (a sibling binary next to `wine` in
/// CrossOver's own `bin/` directory): `cxbottle --bottle <name> --create`
/// is what CrossOver's own "New Bottle" UI action shells out to, confirmed
/// by creating and then successfully addressing a real bottle this way.
///
/// `--template win10_64` is required, not cosmetic: without an explicit
/// template, `cxbottle --create` defaults to the legacy `win98` template,
/// which produces a plain 32-bit (`WineArch=win32`) prefix with system
/// files directly under `windows/` and an **empty** `windows/syswow64/`.
/// Winetricks (and most modern installers) assume a WOW64 layout and look
/// for things like `regedit.exe` under `syswow64/`, so verbs fail outright
/// on a `win98`-template bottle. Confirmed by creating a bottle both ways
/// against a real CrossOver install: only `win10_64` produces
/// `WineArch=win64` with `syswow64/` populated.
///
/// The `.respilotManaged` path needs no equivalent template flag: vanilla
/// Wine's combined win32/win64 macOS packaging (the layout WineHQ and
/// Gcenx's builds both ship, see `WineEngineManager`) already produces a
/// WOW64 prefix by default on first boot — `WINEARCH=win64` is set
/// explicitly anyway, matching the same "always WOW64" intent as
/// `win10_64` above rather than relying on an unstated default.
public final class BottleProvisioner {
    private let processRunner: ProcessRunning
    private let fileManager: FileManager

    public init(
        processRunner: ProcessRunning = FoundationProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    /// For `.crossOver`, creates `bottle`'s prefix via
    /// `cxbottle --bottle <name> --create`. For `.respilotManaged`, boots
    /// a fresh prefix via `wineboot --init` against ResPilot's own engine.
    /// Either way, a no-op if the prefix directory already exists — never
    /// overwrites an existing bottle.
    @discardableResult
    public func createPrefix(_ bottle: WineBottleTarget) throws -> ProcessResult {
        switch bottle.kind {
        case .crossOver:
            return try createCrossOverPrefix(bottle)
        case .respilotManaged:
            return try createRespilotManagedPrefix(bottle)
        case .wineskinStyle:
            throw BottleProvisionerError.unsupportedBottleKind
        }
    }

    private func createCrossOverPrefix(_ bottle: WineBottleTarget) throws -> ProcessResult {
        guard let name = bottle.crossOverBottleName, !name.isEmpty else {
            throw BottleProvisionerError.prefixInitFailed("Bottle is missing its CrossOver bottle name.")
        }
        if fileManager.fileExists(atPath: bottle.prefixPath) {
            return ProcessResult(exitCode: 0, stdout: "Bottle already exists; skipped creation.", stderr: "")
        }

        let cxbottlePath = URL(fileURLWithPath: bottle.wineBinaryPath)
            .deletingLastPathComponent()
            .appendingPathComponent("cxbottle")
            .path
        var env = ProcessInfo.processInfo.environment
        env["WINEDEBUG"] = "-all"
        let result = try processRunner.run(
            executable: cxbottlePath,
            arguments: ["--bottle", name, "--create", "--template", "win10_64"],
            environment: env
        )
        guard result.succeeded else {
            throw BottleProvisionerError.prefixInitFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }

    /// `wineboot --init` against a `WINEPREFIX` that doesn't exist yet is
    /// the documented, deterministic way to force a synchronous first-run
    /// prefix setup (the same idiom Bottles/Lutris/PlayOnMac use) — unlike
    /// CrossOver's wrapper, vanilla Wine has no separate bottle-registry to
    /// pre-register a name with, so creating the directory and booting it
    /// is the whole operation. Bounded at 5 minutes: first-boot prefix
    /// initialization is normally seconds, but this is a first-run,
    /// user-facing step where an indefinite hang would be a silent freeze
    /// rather than a bounded, reportable failure.
    private func createRespilotManagedPrefix(_ bottle: WineBottleTarget) throws -> ProcessResult {
        if fileManager.fileExists(atPath: bottle.prefixPath) {
            return ProcessResult(exitCode: 0, stdout: "Bottle already exists; skipped creation.", stderr: "")
        }
        try fileManager.createDirectory(at: URL(fileURLWithPath: bottle.prefixPath), withIntermediateDirectories: true)

        let winebootPath = URL(fileURLWithPath: bottle.wineBinaryPath)
            .deletingLastPathComponent()
            .appendingPathComponent("wineboot")
            .path
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.prefixPath
        env["WINEARCH"] = "win64"
        env["WINEDEBUG"] = "-all"
        let result = try processRunner.run(
            executable: winebootPath,
            arguments: ["--init"],
            environment: env,
            timeout: 300
        )
        guard result.succeeded else {
            throw BottleProvisionerError.prefixInitFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }
}

public enum BottleProvisionerError: Error, LocalizedError, Equatable {
    case unsupportedBottleKind
    case prefixInitFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedBottleKind:
            return "ResPilot can only create CrossOver or its own self-managed bottles — Wineskin/Sikarugir bottles are created through that app's own tooling."
        case .prefixInitFailed(let reason):
            return "Failed to create the bottle: \(reason)"
        }
    }
}
