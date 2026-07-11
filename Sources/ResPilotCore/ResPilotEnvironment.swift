import Foundation

/// Central place to resolve "home" for ResPilot's own config/state files.
/// Respects `RESPILOT_HOME` when set so tests (and the CLI smoke tests run
/// during development) never touch the real
/// `~/Library/Application Support`, and so a user can run isolated
/// configurations side by side if they want to.
public enum ResPilotEnvironment {
    public static func resolvedHomeDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["RESPILOT_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
