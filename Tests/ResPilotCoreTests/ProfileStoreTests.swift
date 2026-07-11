import Foundation
import Testing
@testable import ResPilotCore

@Suite struct ProfileStoreTests {
    private func makeStore() -> (store: ProfileStore, tempDir: URL) {
        let dir = Fixtures.makeTempDirectory("profile-store")
        // Nested, not-yet-existing path — exercises auto-creation of parents.
        let url = dir.appendingPathComponent("nested/profiles.json")
        return (ProfileStore(storeURL: url), dir)
    }

    @Test func loadAllReturnsEmptyWhenNoFileExistsYet() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.loadAll() == [])
    }

    @Test func addPersistsAndCreatesMissingParentDirectories() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = Fixtures.profile(name: "Alpha")

        try store.add(profile)

        #expect(try store.loadAll() == [profile])
    }

    @Test func addingADuplicateNameUnderADifferentIDThrowsAndLeavesStoreUntouched() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = Fixtures.profile(name: "Alpha")
        try store.add(first)
        let second = Fixtures.profile(name: "Alpha")

        #expect(throws: ProfileStoreError.duplicateName("Alpha")) {
            try store.add(second)
        }
        #expect(try store.loadAll() == [first])
    }

    @Test func addingTheSameIDAgainUpdatesInPlaceInsteadOfDuplicating() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var profile = Fixtures.profile(name: "Alpha")
        try store.add(profile)
        profile.wineRetinaMode.toggle()

        try store.add(profile)

        let all = try store.loadAll()
        #expect(all.count == 1)
        #expect(all.first?.wineRetinaMode == profile.wineRetinaMode)
    }

    @Test func removeDeletesByNameAndThrowsWhenNotFound() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.add(Fixtures.profile(name: "Alpha"))

        try store.remove(name: "Alpha")
        #expect(try store.loadAll().isEmpty)

        #expect(throws: ProfileStoreError.notFound("Alpha")) {
            try store.remove(name: "Alpha")
        }
    }

    @Test func findReturnsMatchingProfileOrNil() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = Fixtures.profile(name: "Alpha")
        try store.add(profile)

        #expect(try store.find(name: "Alpha") == profile)
        #expect(try store.find(name: "Nope") == nil)
    }
}
