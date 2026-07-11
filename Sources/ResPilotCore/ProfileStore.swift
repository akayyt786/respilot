import Foundation

public enum ProfileStoreError: Error, LocalizedError, Equatable {
    case duplicateName(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateName(let name): return "A profile named \"\(name)\" already exists."
        case .notFound(let name): return "No profile named \"\(name)\"."
        }
    }
}

/// JSON-backed CRUD store for `GameProfile`s. Every mutation reads the
/// current file, edits in memory, then writes the whole array back with an
/// atomic `Data.write(options: .atomic)` — simple, and safe against a
/// torn/partial file from a crash mid-write.
public final class ProfileStore {
    private let fileManager: FileManager
    public let storeURL: URL

    public init(fileManager: FileManager = .default, storeURL: URL? = nil) {
        self.fileManager = fileManager
        self.storeURL = storeURL ?? Self.defaultStoreURL()
    }

    public static func defaultStoreURL(
        homeDirectory: URL = ResPilotEnvironment.resolvedHomeDirectory()
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/ResPilot", isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    public func loadAll() throws -> [GameProfile] {
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }
        let data = try Data(contentsOf: storeURL)
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        return try decoder.decode([GameProfile].self, from: data)
    }

    public func saveAll(_ profiles: [GameProfile]) throws {
        let directory = storeURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try data.write(to: storeURL, options: .atomic)
    }

    @discardableResult
    public func add(_ profile: GameProfile) throws -> GameProfile {
        var all = try loadAll()
        if all.contains(where: { $0.name == profile.name && $0.id != profile.id }) {
            throw ProfileStoreError.duplicateName(profile.name)
        }
        all.removeAll { $0.id == profile.id }
        all.append(profile)
        try saveAll(all)
        return profile
    }

    public func remove(name: String) throws {
        var all = try loadAll()
        guard all.contains(where: { $0.name == name }) else {
            throw ProfileStoreError.notFound(name)
        }
        all.removeAll { $0.name == name }
        try saveAll(all)
    }

    public func find(name: String) throws -> GameProfile? {
        try loadAll().first { $0.name == name }
    }
}
