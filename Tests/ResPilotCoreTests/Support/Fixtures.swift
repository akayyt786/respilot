import Foundation
import ResPilotCore

/// Shared sample data + filesystem helpers for the ResPilotCore test suite.
/// Every fixture is deliberately minimal — just enough to satisfy whatever
/// invariant the test under it is checking — and every temp directory it
/// hands out is unique per call so tests can run in parallel without
/// colliding on disk.
enum Fixtures {
    static func bottleTarget(
        kind: BottleKind = .crossOver,
        prefixPath: String = "/tmp/respilot-tests/bottle",
        wineBinaryPath: String = "/tmp/respilot-tests/wine",
        crossOverBottleName: String? = "TestBottle"
    ) -> WineBottleTarget {
        WineBottleTarget(
            kind: kind,
            prefixPath: prefixPath,
            wineBinaryPath: wineBinaryPath,
            crossOverBottleName: crossOverBottleName
        )
    }

    static func profile(
        name: String = "Test Game",
        bottle: WineBottleTarget = bottleTarget(),
        launchTarget: LaunchTarget = .appBundle(path: "/Applications/TestGame.app"),
        display: DisplayTarget = .leaveUnchanged,
        wineRetinaMode: Bool = true,
        wineLogPixels: Int? = nil,
        autoRevertOnQuit: Bool = true,
        compatibility: WineCompatibilitySettings = .none
    ) -> GameProfile {
        GameProfile(
            name: name,
            bottle: bottle,
            launchTarget: launchTarget,
            display: display,
            wineRetinaMode: wineRetinaMode,
            wineLogPixels: wineLogPixels,
            autoRevertOnQuit: autoRevertOnQuit,
            compatibility: compatibility
        )
    }

    static func mode(w: Int, h: Int, hiDPI: Bool, hz: Double = 60) -> DisplayModeInfo {
        DisplayModeInfo(
            pointWidth: w,
            pointHeight: h,
            pixelWidth: hiDPI ? w * 2 : w,
            pixelHeight: hiDPI ? h * 2 : h,
            refreshRateHz: hz
        )
    }

    /// A minimal but realistic `user.reg` fixture: one string value in the
    /// Mac Driver section, one dword in the Desktop section, exercising the
    /// exact two lookups `WineRegistry.currentSettings` performs.
    static let regFileFixture = #"""
    WINE REGISTRY Version 2
    ;; All keys relative to \\User\\S-1-5-21-0-0-0-1000

    [Software\\Wine\\Mac Driver] 1700000000
    #time=1d9c1e1e1e1e1e1
    "RetinaMode"="y"

    [Control Panel\\Desktop] 1700000000
    #time=1d9c1e1e1e1e1e2
    "LogPixels"=dword:00000090
    """#

    /// A fresh, uniquely-named temp directory, created on disk. Callers are
    /// responsible for removing it (`defer { try? FileManager.default.removeItem(at: dir) }`).
    static func makeTempDirectory(_ label: String) -> URL {
        // `URL.resolvingSymlinksInPath()` deliberately leaves /tmp, /var,
        // and /etc unresolved (documented Foundation behavior) — but
        // FileManager's own directory-enumeration APIs *do* hand back the
        // canonical /private/var/... form. Canonicalize with POSIX
        // `realpath` up front so every path built from this root compares
        // equal, by plain string equality, to whatever BottleLocator's
        // `contentsOfDirectory` calls hand back.
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResPilotTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        guard let resolved = realpath(unresolved.path, nil) else { return unresolved }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Writes a stub file at `url`, creating parent directories as needed,
    /// optionally setting the executable bit so `isExecutableFile` checks
    /// can be exercised honestly.
    @discardableResult
    static func writeFile(_ url: URL, executable: Bool) -> URL {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let attributes: [FileAttributeKey: Any]? = executable ? [.posixPermissions: 0o755] : nil
        FileManager.default.createFile(atPath: url.path, contents: Data("stub".utf8), attributes: attributes)
        return url
    }

    /// A directory that looks like a real Wine prefix to `BottleLocator`
    /// (`drive_c` + `user.reg` both present), under `bottlesDir/name`.
    @discardableResult
    static func makeBottle(named name: String, under bottlesDir: URL) throws -> URL {
        let bottle = bottlesDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: bottle.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bottle.appendingPathComponent("user.reg").path, contents: Data())
        return bottle
    }
}

struct FakeError: Error, Equatable {
    let message: String
}

/// Thread-safe append-only recorder for values reported from a
/// `@Sendable` callback (e.g. `AppInstaller`'s `onStep`) — captures into a
/// locked class instead of a local `var`, which is the pattern that
/// avoids the "mutation of captured var in concurrently-executing code"
/// warning (a hard error under the Swift 6 language mode).
final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [T] = []

    var values: [T] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }

    func record(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        _values.append(value)
    }
}
