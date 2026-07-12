import Foundation
import Testing
@testable import ResPilotCore

@Suite struct BottleLocatorHelperTests {
    @Test func isWinePrefixRequiresBothDriveCAndUserReg() throws {
        let dir = Fixtures.makeTempDirectory("prefix-check")
        defer { try? FileManager.default.removeItem(at: dir) }
        let locator = BottleLocator()

        #expect(!locator.isWinePrefix(dir))

        try FileManager.default.createDirectory(at: dir.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        #expect(!locator.isWinePrefix(dir)) // drive_c alone isn't enough

        FileManager.default.createFile(atPath: dir.appendingPathComponent("user.reg").path, contents: Data())
        #expect(locator.isWinePrefix(dir))
    }

    @Test func firstExecutableFindsAMatchingNameThatIsActuallyExecutable() throws {
        let dir = Fixtures.makeTempDirectory("first-exe")
        defer { try? FileManager.default.removeItem(at: dir) }
        Fixtures.writeFile(dir.appendingPathComponent("wine"), executable: false)
        Fixtures.writeFile(dir.appendingPathComponent("nested/wine64"), executable: true)

        let found = BottleLocator().firstExecutable(named: ["wine", "wine64"], under: dir, maxDepth: 4)

        #expect(found?.lastPathComponent == "wine64")
    }

    @Test func firstExecutableIgnoresANameMatchThatLacksTheExecutableBit() throws {
        let dir = Fixtures.makeTempDirectory("first-exe-non-x")
        defer { try? FileManager.default.removeItem(at: dir) }
        Fixtures.writeFile(dir.appendingPathComponent("wine"), executable: false)

        #expect(BottleLocator().firstExecutable(named: ["wine"], under: dir, maxDepth: 4) == nil)
    }

    @Test func firstExecutableRespectsMaxDepth() throws {
        let dir = Fixtures.makeTempDirectory("first-exe-depth")
        defer { try? FileManager.default.removeItem(at: dir) }
        Fixtures.writeFile(dir.appendingPathComponent("a/b/c/wine"), executable: true)

        let locator = BottleLocator()
        #expect(locator.firstExecutable(named: ["wine"], under: dir, maxDepth: 3) == nil)
        #expect(locator.firstExecutable(named: ["wine"], under: dir, maxDepth: 4) != nil)
    }
}

@Suite struct BottleLocatorDiscoveryTests {
    @Test func discoverCrossOverBottlesFindsOnlyValidPrefixesAndSortsByName() throws {
        let root = Fixtures.makeTempDirectory("crossover-discovery")
        defer { try? FileManager.default.removeItem(at: root) }

        let appBundle = root.appendingPathComponent("CrossOver.app")
        let wineBinary = Fixtures.writeFile(
            appBundle.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine"),
            executable: true
        )

        let bottlesDir = root.appendingPathComponent("Bottles")
        try Fixtures.makeBottle(named: "GameA", under: bottlesDir)
        try Fixtures.makeBottle(named: "AGame", under: bottlesDir)
        // Not a real prefix — no drive_c/user.reg — must be excluded.
        try FileManager.default.createDirectory(at: bottlesDir.appendingPathComponent("NotABottle"), withIntermediateDirectories: true)

        let found = BottleLocator().discoverCrossOverBottles(bottleDirectory: bottlesDir, appBundle: appBundle)

        #expect(found.map(\.name) == ["AGame", "GameA"])
        #expect(found.allSatisfy { $0.target.kind == .crossOver })
        #expect(found.allSatisfy { $0.target.wineBinaryPath == wineBinary.path })
        #expect(found.first { $0.name == "GameA" }?.target.crossOverBottleName == "GameA")
    }

    @Test func discoverCrossOverBottlesReturnsEmptyWithoutAResolvableWineBinary() throws {
        let root = Fixtures.makeTempDirectory("crossover-no-wine")
        defer { try? FileManager.default.removeItem(at: root) }
        let bottlesDir = root.appendingPathComponent("Bottles")
        try Fixtures.makeBottle(named: "GameA", under: bottlesDir)

        let found = BottleLocator().discoverCrossOverBottles(
            bottleDirectory: bottlesDir,
            appBundle: root.appendingPathComponent("NoSuchApp.app")
        )

        #expect(found.isEmpty)
    }

    @Test func discoverWineskinStyleWrappersFindsAppsWithAnEmbeddedPrefixAndWineBinary() throws {
        let root = Fixtures.makeTempDirectory("wineskin-discovery")
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapper = root.appendingPathComponent("SomeGame.app")
        let prefix = wrapper.appendingPathComponent("Contents/SharedSupport/prefix")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: prefix.appendingPathComponent("user.reg").path, contents: Data())
        Fixtures.writeFile(wrapper.appendingPathComponent("Contents/SharedSupport/wine64"), executable: true)

        // A sibling .app with no embedded prefix at all must be skipped.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Other.app"), withIntermediateDirectories: true)

        let found = BottleLocator().discoverWineskinStyleWrappers(searchRoots: [root])

        #expect(found.count == 1)
        #expect(found.first?.name == "SomeGame")
        #expect(found.first?.target.kind == .wineskinStyle)
        #expect(found.first?.target.prefixPath == prefix.path)
    }

    @Test func discoverWineskinStyleWrappersSkipsAPrefixWithNoResolvableWineBinary() throws {
        let root = Fixtures.makeTempDirectory("wineskin-no-wine")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("SomeGame.app/Contents/SharedSupport/prefix")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: prefix.appendingPathComponent("user.reg").path, contents: Data())
        // No wine/wine64/wine32on64 binary anywhere under SharedSupport.

        #expect(BottleLocator().discoverWineskinStyleWrappers(searchRoots: [root]).isEmpty)
    }

    @Test func discoverRespilotManagedBottlesFindsOnlyValidPrefixesAndSortsByName() throws {
        let root = Fixtures.makeTempDirectory("respilot-discovery")
        defer { try? FileManager.default.removeItem(at: root) }

        try Fixtures.makeBottle(named: "GameA", under: root)
        try Fixtures.makeBottle(named: "AGame", under: root)
        // Not a real prefix — no drive_c/user.reg — must be excluded.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("NotABottle"), withIntermediateDirectories: true)

        let found = BottleLocator().discoverRespilotManagedBottles(bottleDirectory: root, wineBinary: "/opt/ResPilot/wine64")

        #expect(found.map(\.name) == ["AGame", "GameA"])
        #expect(found.allSatisfy { $0.target.kind == .respilotManaged })
        #expect(found.allSatisfy { $0.target.wineBinaryPath == "/opt/ResPilot/wine64" })
        #expect(found.allSatisfy { $0.target.crossOverBottleName == nil })
    }

    @Test func discoverRespilotManagedBottlesReturnsEmptyForAMissingDirectory() throws {
        let root = Fixtures.makeTempDirectory("respilot-missing")
        defer { try? FileManager.default.removeItem(at: root) }

        let found = BottleLocator().discoverRespilotManagedBottles(
            bottleDirectory: root.appendingPathComponent("DoesNotExist"),
            wineBinary: "/opt/ResPilot/wine64"
        )

        #expect(found.isEmpty)
    }
}
