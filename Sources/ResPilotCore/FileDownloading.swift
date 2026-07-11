import Foundation

/// Download seam shared by anything that fetches a file over HTTP
/// (`Winetricks.install()`, `InstallerDownloader`) so those call sites are
/// testable without a real network call — same pattern as
/// `ProcessRunning`/`DisplayModeProviding` elsewhere in this module.
public protocol FileDownloading: Sendable {
    func data(from url: URL) async throws -> (Data, URLResponse)
}

extension URLSession: FileDownloading {}
