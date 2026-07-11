import Foundation

/// Persists "the display mode to restore to" on disk, separate from
/// `LaunchOrchestrator`'s in-memory state. A CLI invocation is a fresh
/// process every time — `respilot apply` and a later `respilot restore`
/// don't share memory — and the menu bar app could in principle crash
/// mid-session. Either way, without a breadcrumb on disk there would be no
/// way to recover the pre-game display mode. Written right before a
/// display change, cleared right after a successful restore.
public final class DisplayRestoreBreadcrumbStore {
    private let fileManager: FileManager
    public let fileURL: URL

    public init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultURL()
    }

    public static func defaultURL(
        homeDirectory: URL = ResPilotEnvironment.resolvedHomeDirectory()
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/ResPilot", isDirectory: true)
            .appendingPathComponent("pending-restore.json")
    }

    public func write(_ mode: DisplayModeInfo) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder().encode(mode)
        try data.write(to: fileURL, options: .atomic)
    }

    public func read() -> DisplayModeInfo? {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(DisplayModeInfo.self, from: data)
    }

    public func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
