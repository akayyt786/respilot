import Foundation

/// A Wine bottle found on disk, ready to be turned into a `GameProfile`.
public struct DiscoveredBottle: Equatable, Sendable, Identifiable {
    public var id: String { target.prefixPath }
    public let name: String
    public let target: WineBottleTarget

    public init(name: String, target: WineBottleTarget) {
        self.name = name
        self.target = target
    }
}

/// Finds Wine bottles on disk across the two lineages ResPilot supports.
/// Every path here comes from each project's own public documentation
/// (CodeWeavers' bottle-directory support article, the Wineskin wrapper
/// layout docs) — never from inspecting a downloaded binary. Discovery
/// degrades gracefully: if a conventional path is wrong for some future
/// release, callers fall back to letting the user point at a bottle by
/// hand (see `respilot add-profile --prefix`).
public final class BottleLocator {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public static func defaultCrossOverBottleDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
    }

    public static func crossOverAppCandidates(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/CrossOver.app"),
            homeDirectory.appendingPathComponent("Applications/CrossOver.app"),
        ]
    }

    public static func defaultWineskinSearchRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            homeDirectory.appendingPathComponent("Applications"),
            homeDirectory.appendingPathComponent("Applications/Wineskin"),
        ]
    }

    /// ResPilot's own bottle directory — where `.respilotManaged` bottles
    /// created via `BottleProvisioner`/`AppInstaller` live. Uses
    /// `ResPilotEnvironment.resolvedHomeDirectory()` (respects
    /// `RESPILOT_HOME`), unlike the CrossOver/Wineskin roots above: those
    /// point at *other* apps' real, non-redirectable install locations,
    /// while this one is ResPilot's own state — same convention as
    /// `ProfileStore`/`Winetricks`/`DisplayRestoreBreadcrumbStore`.
    public static func defaultRespilotBottleDirectory(
        homeDirectory: URL = ResPilotEnvironment.resolvedHomeDirectory()
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/ResPilot", isDirectory: true)
            .appendingPathComponent("Bottles", isDirectory: true)
    }

    /// Locates `wine` inside an installed CrossOver.app: the documented
    /// `Contents/SharedSupport/CrossOver/bin/wine` path first, then a
    /// bounded search of the bundle as a fallback.
    public func crossOverWineBinary(appBundle: URL) -> URL? {
        let conventional = appBundle.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine")
        if fileManager.isExecutableFile(atPath: conventional.path) {
            return conventional
        }
        let sharedSupport = appBundle.appendingPathComponent("Contents/SharedSupport")
        return firstExecutable(named: ["wine", "wine64"], under: sharedSupport, maxDepth: 4)
    }

    /// Every subdirectory of the CrossOver bottle directory that looks like
    /// a real Wine prefix (has `drive_c` and `user.reg`).
    public func discoverCrossOverBottles(
        bottleDirectory: URL? = nil,
        appBundle: URL? = nil
    ) -> [DiscoveredBottle] {
        let bottleDir = bottleDirectory ?? Self.defaultCrossOverBottleDirectory()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: bottleDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        let resolvedApp = appBundle ?? Self.crossOverAppCandidates().first { fileManager.fileExists(atPath: $0.path) }
        let wineBinary = resolvedApp.flatMap { crossOverWineBinary(appBundle: $0) }
        guard let wineBinary else { return [] }

        return entries.compactMap { entry -> DiscoveredBottle? in
            guard isWinePrefix(entry) else { return nil }
            let target = WineBottleTarget(
                kind: .crossOver,
                prefixPath: entry.path,
                wineBinaryPath: wineBinary.path,
                crossOverBottleName: entry.lastPathComponent
            )
            return DiscoveredBottle(name: entry.lastPathComponent, target: target)
        }.sorted { $0.name < $1.name }
    }

    /// Any `.app` under the search roots containing
    /// `Contents/SharedSupport/prefix` — the documented Wineskin/Kegworks/
    /// Sikarugir wrapper layout, where each wrapper is its own bottle.
    public func discoverWineskinStyleWrappers(searchRoots: [URL]? = nil) -> [DiscoveredBottle] {
        let roots = searchRoots ?? Self.defaultWineskinSearchRoots()
        var results: [DiscoveredBottle] = []
        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for entry in entries where entry.pathExtension == "app" {
                let prefix = entry.appendingPathComponent("Contents/SharedSupport/prefix")
                guard isWinePrefix(prefix) else { continue }
                let sharedSupport = entry.appendingPathComponent("Contents/SharedSupport")
                guard let wineBinary = firstExecutable(named: ["wine64", "wine32on64", "wine"], under: sharedSupport, maxDepth: 4) else {
                    continue
                }
                let target = WineBottleTarget(kind: .wineskinStyle, prefixPath: prefix.path, wineBinaryPath: wineBinary.path)
                results.append(DiscoveredBottle(name: entry.deletingPathExtension().lastPathComponent, target: target))
            }
        }
        return results.sorted { $0.name < $1.name }
    }

    /// Every subdirectory of ResPilot's own bottle directory that looks
    /// like a real Wine prefix — bottles `BottleProvisioner`/
    /// `AppInstaller` created against `WineEngineManager`'s self-managed
    /// engine, no CrossOver or Wineskin involved. `wineBinary` defaults to
    /// wherever `WineEngineManager` keeps its engine; pass it explicitly
    /// only in tests or if the engine hasn't been installed yet.
    public func discoverRespilotManagedBottles(
        bottleDirectory: URL? = nil,
        wineBinary: String? = nil
    ) -> [DiscoveredBottle] {
        let bottleDir = bottleDirectory ?? Self.defaultRespilotBottleDirectory()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: bottleDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        let resolvedWineBinary = wineBinary ?? WineEngineManager().wineBinaryPath
        return entries.compactMap { entry -> DiscoveredBottle? in
            guard isWinePrefix(entry) else { return nil }
            let target = WineBottleTarget(kind: .respilotManaged, prefixPath: entry.path, wineBinaryPath: resolvedWineBinary)
            return DiscoveredBottle(name: entry.lastPathComponent, target: target)
        }.sorted { $0.name < $1.name }
    }

    // MARK: - Helpers

    func isWinePrefix(_ directory: URL) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent("drive_c").path) &&
        fileManager.fileExists(atPath: directory.appendingPathComponent("user.reg").path)
    }

    func firstExecutable(named candidates: [String], under root: URL, maxDepth: Int) -> URL? {
        guard maxDepth > 0 else { return nil }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return nil
        }
        for entry in entries where candidates.contains(entry.lastPathComponent) {
            if fileManager.isExecutableFile(atPath: entry.path) {
                return entry
            }
        }
        for entry in entries {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let found = firstExecutable(named: candidates, under: entry, maxDepth: maxDepth - 1) {
                return found
            }
        }
        return nil
    }
}
