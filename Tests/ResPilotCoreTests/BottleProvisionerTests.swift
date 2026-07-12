import Foundation
import Testing
@testable import ResPilotCore

@Suite struct BottleProvisionerTests {
    @Test func createsViaCxbottleSiblingToTheWineBinary() throws {
        let dir = Fixtures.makeTempDirectory("provisioner")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefixPath = dir.appendingPathComponent("Bottles/NewBottle").path
        let runner = FakeProcessRunner()
        let provisioner = BottleProvisioner(processRunner: runner)
        let bottle = Fixtures.bottleTarget(
            prefixPath: prefixPath,
            wineBinaryPath: "/opt/CrossOver/bin/wine",
            crossOverBottleName: "NewBottle"
        )

        try provisioner.createPrefix(bottle)

        #expect(runner.invocations.count == 1)
        let call = try #require(runner.invocations.first)
        // cxbottle is CrossOver's own bottle-management tool, a sibling of
        // `wine` in the same bin/ directory — verified against a real
        // CrossOver install; `wine wineboot -u` alone does not create a
        // bottle CrossOver will later recognize via --bottle.
        #expect(call.executable == "/opt/CrossOver/bin/cxbottle")
        #expect(call.arguments == ["--bottle", "NewBottle", "--create", "--template", "win10_64"])
    }

    @Test func skipsCreationWhenThePrefixAlreadyExists() throws {
        let dir = Fixtures.makeTempDirectory("provisioner-existing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: existing.appendingPathComponent("marker").path, contents: Data("x".utf8))

        let runner = FakeProcessRunner()
        let provisioner = BottleProvisioner(processRunner: runner)
        let bottle = Fixtures.bottleTarget(prefixPath: existing.path, crossOverBottleName: "Existing")

        let result = try provisioner.createPrefix(bottle)

        #expect(result.succeeded)
        #expect(runner.invocations.isEmpty) // never touches cxbottle for an existing bottle
        #expect(FileManager.default.fileExists(atPath: existing.appendingPathComponent("marker").path))
    }

    @Test func failedCreationThrows() {
        let dir = Fixtures.makeTempDirectory("provisioner-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = FakeProcessRunner()
        runner.defaultResult = ProcessResult(exitCode: 1, stdout: "", stderr: "cxbottle exploded")
        let provisioner = BottleProvisioner(processRunner: runner)
        let bottle = Fixtures.bottleTarget(
            prefixPath: dir.appendingPathComponent("Broken").path,
            crossOverBottleName: "Broken"
        )

        #expect(throws: BottleProvisionerError.prefixInitFailed("cxbottle exploded")) {
            try provisioner.createPrefix(bottle)
        }
    }

    @Test func wineskinStyleBottlesAreUnsupported() {
        let dir = Fixtures.makeTempDirectory("provisioner-wineskin")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = FakeProcessRunner()
        let provisioner = BottleProvisioner(processRunner: runner)
        let bottle = Fixtures.bottleTarget(
            kind: .wineskinStyle,
            prefixPath: dir.appendingPathComponent("NotSupported").path,
            crossOverBottleName: nil
        )

        #expect(throws: BottleProvisionerError.unsupportedBottleKind) {
            try provisioner.createPrefix(bottle)
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test func createsRespilotManagedPrefixViaWinebootInit() throws {
        let dir = Fixtures.makeTempDirectory("provisioner-respilot")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefixPath = dir.appendingPathComponent("Bottles/NewBottle").path
        let runner = FakeProcessRunner()
        let provisioner = BottleProvisioner(processRunner: runner)
        let bottle = Fixtures.bottleTarget(
            kind: .respilotManaged,
            prefixPath: prefixPath,
            wineBinaryPath: "/opt/ResPilot/WineEngine/Wine Staging.app/Contents/Resources/wine/bin/wine",
            crossOverBottleName: nil
        )

        try provisioner.createPrefix(bottle)

        #expect(FileManager.default.fileExists(atPath: prefixPath))
        #expect(runner.invocations.count == 1)
        let call = try #require(runner.invocations.first)
        // wineboot is a sibling of wine in the same bin/ directory, same
        // pattern as cxbottle for CrossOver — no separate bottle-registry
        // to pre-register a name with for vanilla Wine.
        #expect(call.executable == "/opt/ResPilot/WineEngine/Wine Staging.app/Contents/Resources/wine/bin/wineboot")
        #expect(call.arguments == ["--init"])
        #expect(call.environment?["WINEPREFIX"] == prefixPath)
        #expect(call.environment?["WINEARCH"] == "win64")
        #expect(call.timeout == 300)
    }

    @Test func skipsRespilotManagedCreationWhenThePrefixAlreadyExists() throws {
        let dir = Fixtures.makeTempDirectory("provisioner-respilot-existing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: existing.appendingPathComponent("marker").path, contents: Data("x".utf8))

        let runner = FakeProcessRunner()
        let provisioner = BottleProvisioner(processRunner: runner)
        let bottle = Fixtures.bottleTarget(kind: .respilotManaged, prefixPath: existing.path, crossOverBottleName: nil)

        let result = try provisioner.createPrefix(bottle)

        #expect(result.succeeded)
        #expect(runner.invocations.isEmpty) // never touches wineboot for an existing bottle
        #expect(FileManager.default.fileExists(atPath: existing.appendingPathComponent("marker").path))
    }

    @Test func failedRespilotManagedCreationThrows() {
        let dir = Fixtures.makeTempDirectory("provisioner-respilot-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = FakeProcessRunner()
        runner.defaultResult = ProcessResult(exitCode: 1, stdout: "", stderr: "wineboot exploded")
        let provisioner = BottleProvisioner(processRunner: runner)
        let bottle = Fixtures.bottleTarget(
            kind: .respilotManaged,
            prefixPath: dir.appendingPathComponent("Broken").path,
            crossOverBottleName: nil
        )

        #expect(throws: BottleProvisionerError.prefixInitFailed("wineboot exploded")) {
            try provisioner.createPrefix(bottle)
        }
    }
}
