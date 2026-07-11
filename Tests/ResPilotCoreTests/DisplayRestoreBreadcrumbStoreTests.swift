import Foundation
import Testing
@testable import ResPilotCore

@Suite struct DisplayRestoreBreadcrumbStoreTests {
    private func makeStore() -> (store: DisplayRestoreBreadcrumbStore, tempDir: URL) {
        let dir = Fixtures.makeTempDirectory("breadcrumb")
        let url = dir.appendingPathComponent("nested/pending-restore.json")
        return (DisplayRestoreBreadcrumbStore(fileURL: url), dir)
    }

    @Test func readReturnsNilWhenNothingWasWritten() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.read() == nil)
    }

    @Test func writeThenReadRoundTripsTheMode() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mode = Fixtures.mode(w: 1440, h: 900, hiDPI: true)

        try store.write(mode)

        #expect(store.read() == mode)
    }

    @Test func writeCreatesMissingParentDirectories() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.write(Fixtures.mode(w: 1920, h: 1080, hiDPI: false))
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func clearRemovesTheFileAndIsANoOpWhenAlreadyAbsent() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.write(Fixtures.mode(w: 1280, h: 800, hiDPI: false))

        try store.clear()
        #expect(store.read() == nil)
        try store.clear() // must not throw when there's nothing to clear
    }
}
