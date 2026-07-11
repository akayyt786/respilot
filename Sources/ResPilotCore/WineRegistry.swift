import Foundation

/// How a Wine bottle is addressed. Two lineages exist in the wild and they
/// use *different* invocation conventions for the same underlying Wine
/// `reg` tool — see `WineRegistry.invocation(for:subcommand:)`.
public enum BottleKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// CrossOver: one shared `wine` binary inside CrossOver.app, bottles
    /// selected by name via `--bottle <name>` (CodeWeavers' own documented
    /// CLI convention).
    case crossOver
    /// Wineskin/Kegworks/Sikarugir-lineage: each wrapped `.app` carries its
    /// own private `wine` binary and prefix, addressed via `WINEPREFIX`.
    case wineskinStyle
}

public struct WineBottleTarget: Codable, Equatable, Sendable {
    public let kind: BottleKind
    /// Root of the actual Wine prefix (contains drive_c, user.reg, system.reg).
    public let prefixPath: String
    /// Path to the `wine` (or `wine64`) executable to invoke.
    public let wineBinaryPath: String
    /// For `.crossOver` bottles, the bottle's display name as CrossOver
    /// knows it. Required for that kind, unused for `.wineskinStyle`.
    public let crossOverBottleName: String?

    public init(kind: BottleKind, prefixPath: String, wineBinaryPath: String, crossOverBottleName: String? = nil) {
        self.kind = kind
        self.prefixPath = prefixPath
        self.wineBinaryPath = wineBinaryPath
        self.crossOverBottleName = crossOverBottleName
    }
}

/// The two Wine-side settings that, together with the macOS display mode,
/// determine whether a game renders sharp or blurry / the right size.
/// Registry keys per upstream Wine (winemac.drv `RetinaMode`, standard
/// Windows `LogPixels`) — see project README for sources.
public struct WineDisplaySettings: Equatable, Sendable {
    public var retinaMode: Bool
    /// Windows DPI value (96 = 100%, 144 = 150%, 192 = 200% ...). `nil`
    /// leaves whatever is already set.
    public var logPixels: Int?

    public init(retinaMode: Bool, logPixels: Int? = nil) {
        self.retinaMode = retinaMode
        self.logPixels = logPixels
    }
}

public enum WineRegistryError: Error, LocalizedError, Equatable {
    case missingCrossOverBottleName
    case wineCommandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCrossOverBottleName:
            return "CrossOver bottle target is missing its bottle name."
        case .wineCommandFailed(let message):
            return "wine reg command failed: \(message)"
        }
    }
}

public final class WineRegistry {
    private let processRunner: ProcessRunning

    public init(processRunner: ProcessRunning = FoundationProcessRunner()) {
        self.processRunner = processRunner
    }

    /// Builds the argv/env to invoke `wine <subcommand...>` against a
    /// specific bottle, addressing it the way its lineage expects. Exposed
    /// (not private) so tests can assert exact invocation shape.
    public func invocation(
        for bottle: WineBottleTarget,
        subcommand: [String],
        compatibility: WineCompatibilitySettings = .none
    ) throws -> (executable: String, arguments: [String], environment: [String: String]) {
        var args: [String] = []
        var env = ProcessInfo.processInfo.environment
        switch bottle.kind {
        case .crossOver:
            guard let name = bottle.crossOverBottleName, !name.isEmpty else {
                throw WineRegistryError.missingCrossOverBottleName
            }
            args.append(contentsOf: ["--bottle", name])
        case .wineskinStyle:
            env["WINEPREFIX"] = bottle.prefixPath
        }
        args.append(contentsOf: subcommand)
        env["WINEDEBUG"] = "-all"
        // Opt-in only: an unset key leaves Wine's own default (and any
        // ambient shell env) untouched, so a profile that never asks for
        // ESync/MSync produces byte-identical invocations to before this
        // setting existed — no forced "off" that could regress a bottle
        // that already relies on one being on.
        if compatibility.esync { env["WINEESYNC"] = "1" }
        if compatibility.msync { env["WINEMSYNC"] = "1" }
        return (bottle.wineBinaryPath, args, env)
    }

    /// Writes both registry keys via `wine reg add` (never by hand-patching
    /// `user.reg` — wineserver owns that file while running and a direct
    /// text edit can be lost or corrupt it).
    @discardableResult
    public func apply(_ settings: WineDisplaySettings, to bottle: WineBottleTarget) throws -> [ProcessResult] {
        var results: [ProcessResult] = []

        let retinaArgs = [
            "reg", "add", "HKCU\\Software\\Wine\\Mac Driver",
            "/v", "RetinaMode", "/t", "REG_SZ", "/d", settings.retinaMode ? "y" : "n", "/f",
        ]
        let retinaInvocation = try invocation(for: bottle, subcommand: retinaArgs)
        let retinaResult = try processRunner.run(
            executable: retinaInvocation.executable,
            arguments: retinaInvocation.arguments,
            environment: retinaInvocation.environment
        )
        guard retinaResult.succeeded else {
            throw WineRegistryError.wineCommandFailed(retinaResult.stderr.isEmpty ? retinaResult.stdout : retinaResult.stderr)
        }
        results.append(retinaResult)

        if let logPixels = settings.logPixels {
            let dpiArgs = [
                "reg", "add", "HKCU\\Control Panel\\Desktop",
                "/v", "LogPixels", "/t", "REG_DWORD", "/d", String(logPixels), "/f",
            ]
            let dpiInvocation = try invocation(for: bottle, subcommand: dpiArgs)
            let dpiResult = try processRunner.run(
                executable: dpiInvocation.executable,
                arguments: dpiInvocation.arguments,
                environment: dpiInvocation.environment
            )
            guard dpiResult.succeeded else {
                throw WineRegistryError.wineCommandFailed(dpiResult.stderr.isEmpty ? dpiResult.stdout : dpiResult.stderr)
            }
            results.append(dpiResult)
        }
        return results
    }

    /// Writes the `wined3d` renderer key — the only compatibility toggle
    /// with a plain registry representation. A no-op (no `wine` call at
    /// all) when `renderer` is `nil`. ESync/MSync are environment
    /// variables, not registry state, so they're applied at launch time
    /// via `invocation(for:subcommand:compatibility:)` instead.
    @discardableResult
    public func apply(_ settings: WineCompatibilitySettings, to bottle: WineBottleTarget) throws -> ProcessResult? {
        guard let renderer = settings.renderer else { return nil }
        let rendererArgs = [
            "reg", "add", "HKCU\\Software\\Wine\\Direct3D",
            "/v", "renderer", "/t", "REG_SZ", "/d", renderer.rawValue, "/f",
        ]
        let rendererInvocation = try invocation(for: bottle, subcommand: rendererArgs)
        let result = try processRunner.run(
            executable: rendererInvocation.executable,
            arguments: rendererInvocation.arguments,
            environment: rendererInvocation.environment
        )
        guard result.succeeded else {
            throw WineRegistryError.wineCommandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result
    }

    /// Read-only snapshot parsed directly from the bottle's `user.reg` text
    /// file. Safe to call anytime — no wineserver round trip — but may lag
    /// a write made through `apply` by a moment. Never used as the source
    /// of truth before a write; only for status display.
    public func currentSettings(for bottle: WineBottleTarget) -> WineDisplaySettings? {
        let userRegPath = (bottle.prefixPath as NSString).appendingPathComponent("user.reg")
        guard let text = try? String(contentsOfFile: userRegPath, encoding: .utf8) else { return nil }
        guard let retina = WineRegistryFileParser.readString(text, section: "Software\\\\Wine\\\\Mac Driver", key: "RetinaMode") else {
            return nil
        }
        let dpi = WineRegistryFileParser.readDWord(text, section: "Control Panel\\\\Desktop", key: "LogPixels")
        return WineDisplaySettings(retinaMode: retina == "y", logPixels: dpi)
    }
}

/// Minimal parser for the `WINE REGISTRY Version 2` text format used by
/// `user.reg`/`system.reg`. Only supports what ResPilot reads: locating a
/// `[Section\\Path]` block and pulling a `"Name"="string"` or
/// `"Name"=dword:XXXXXXXX` value out of it. Not a general .reg parser.
public enum WineRegistryFileParser {
    public static func readString(_ text: String, section: String, key: String) -> String? {
        guard let body = sectionBody(text, section: section) else { return nil }
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: body) else { return nil }
        return String(body[range])
    }

    public static func readDWord(_ text: String, section: String, key: String) -> Int? {
        guard let body = sectionBody(text, section: section) else { return nil }
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"=dword:([0-9a-fA-F]{8})"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: body) else { return nil }
        return Int(body[range], radix: 16)
    }

    /// Text of one `[Section]` block: everything after its header line up
    /// to (not including) the next `[`-prefixed line, or EOF.
    private static func sectionBody(_ text: String, section: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        let header = "[\(section)]"
        guard let startIndex = lines.firstIndex(where: { $0.hasPrefix(header) }) else { return nil }
        var endIndex = lines.count
        for i in (startIndex + 1)..<lines.count where lines[i].hasPrefix("[") {
            endIndex = i
            break
        }
        guard startIndex + 1 <= endIndex else { return "" }
        return lines[(startIndex + 1)..<endIndex].joined(separator: "\n")
    }
}
