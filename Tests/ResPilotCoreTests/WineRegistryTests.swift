import Foundation
import Testing
@testable import ResPilotCore

@Suite struct WineRegistryInvocationTests {
    @Test func crossOverInvocationAddsBottleFlagAndDisablesWineDebug() throws {
        let bottle = Fixtures.bottleTarget(kind: .crossOver, crossOverBottleName: "MyBottle")
        let registry = WineRegistry(processRunner: FakeProcessRunner())
        let invocation = try registry.invocation(for: bottle, subcommand: ["start", "/unix", "C:\\game.exe"])

        #expect(invocation.executable == bottle.wineBinaryPath)
        #expect(invocation.arguments == ["--bottle", "MyBottle", "start", "/unix", "C:\\game.exe"])
        #expect(invocation.environment["WINEDEBUG"] == "-all")
        #expect(invocation.environment["WINEPREFIX"] == nil)
    }

    @Test func crossOverInvocationWithoutBottleNameThrows() {
        let bottle = Fixtures.bottleTarget(kind: .crossOver, crossOverBottleName: nil)
        let registry = WineRegistry(processRunner: FakeProcessRunner())
        #expect(throws: WineRegistryError.missingCrossOverBottleName) {
            try registry.invocation(for: bottle, subcommand: [])
        }
    }

    @Test func crossOverInvocationWithEmptyBottleNameThrows() {
        let bottle = Fixtures.bottleTarget(kind: .crossOver, crossOverBottleName: "")
        let registry = WineRegistry(processRunner: FakeProcessRunner())
        #expect(throws: WineRegistryError.missingCrossOverBottleName) {
            try registry.invocation(for: bottle, subcommand: [])
        }
    }

    @Test func wineskinInvocationUsesWinePrefixEnvironmentInsteadOfBottleFlag() throws {
        let bottle = Fixtures.bottleTarget(kind: .wineskinStyle, prefixPath: "/tmp/prefix", crossOverBottleName: nil)
        let registry = WineRegistry(processRunner: FakeProcessRunner())
        let invocation = try registry.invocation(for: bottle, subcommand: ["reg", "query", "HKCU"])

        #expect(invocation.arguments == ["reg", "query", "HKCU"])
        #expect(invocation.environment["WINEPREFIX"] == "/tmp/prefix")
    }

    @Test func respilotManagedInvocationUsesWinePrefixEnvironmentInsteadOfBottleFlag() throws {
        let bottle = Fixtures.bottleTarget(kind: .respilotManaged, prefixPath: "/tmp/respilot-prefix", crossOverBottleName: nil)
        let registry = WineRegistry(processRunner: FakeProcessRunner())
        let invocation = try registry.invocation(for: bottle, subcommand: ["reg", "query", "HKCU"])

        #expect(invocation.arguments == ["reg", "query", "HKCU"])
        #expect(invocation.environment["WINEPREFIX"] == "/tmp/respilot-prefix")
    }

    @Test func defaultCompatibilityProducesNoEsyncOrMsyncKeys() throws {
        let bottle = Fixtures.bottleTarget()
        let registry = WineRegistry(processRunner: FakeProcessRunner())
        let invocation = try registry.invocation(for: bottle, subcommand: [])
        #expect(invocation.environment["WINEESYNC"] == nil)
        #expect(invocation.environment["WINEMSYNC"] == nil)
    }

    @Test func esyncAndMsyncAreOptInOnly() throws {
        let bottle = Fixtures.bottleTarget()
        let registry = WineRegistry(processRunner: FakeProcessRunner())
        let invocation = try registry.invocation(
            for: bottle,
            subcommand: [],
            compatibility: WineCompatibilitySettings(esync: true, msync: true)
        )
        #expect(invocation.environment["WINEESYNC"] == "1")
        #expect(invocation.environment["WINEMSYNC"] == "1")
    }
}

@Suite struct WineRegistryApplyTests {
    @Test func appliesRetinaModeOnlyWhenLogPixelsIsNil() throws {
        let runner = FakeProcessRunner()
        let registry = WineRegistry(processRunner: runner)
        let bottle = Fixtures.bottleTarget()

        try registry.apply(WineDisplaySettings(retinaMode: true, logPixels: nil), to: bottle)

        #expect(runner.invocations.count == 1)
        let call = try #require(runner.invocations.first)
        #expect(call.arguments.contains("RetinaMode"))
        #expect(call.arguments.contains("y"))
    }

    @Test func appliesBothRetinaModeAndLogPixelsWhenSet() throws {
        let runner = FakeProcessRunner()
        let registry = WineRegistry(processRunner: runner)
        let bottle = Fixtures.bottleTarget()

        try registry.apply(WineDisplaySettings(retinaMode: false, logPixels: DPIPreset.scale150), to: bottle)

        #expect(runner.invocations.count == 2)
        #expect(runner.invocations[0].arguments.contains("RetinaMode"))
        #expect(runner.invocations[0].arguments.contains("n"))
        #expect(runner.invocations[1].arguments.contains("LogPixels"))
        #expect(runner.invocations[1].arguments.contains("144"))
    }

    @Test func retinaFailureThrowsAndNeverAttemptsLogPixels() {
        let runner = FakeProcessRunner()
        runner.defaultResult = ProcessResult(exitCode: 1, stdout: "", stderr: "boom")
        let registry = WineRegistry(processRunner: runner)
        let bottle = Fixtures.bottleTarget()

        #expect(throws: WineRegistryError.wineCommandFailed("boom")) {
            try registry.apply(WineDisplaySettings(retinaMode: true, logPixels: 96), to: bottle)
        }
        #expect(runner.invocations.count == 1)
    }

    @Test func logPixelsFailurePropagatesAfterRetinaSucceeded() {
        let runner = FakeProcessRunner()
        runner.resultProvider = { invocation in
            invocation.arguments.contains("LogPixels")
                ? ProcessResult(exitCode: 1, stdout: "", stderr: "dpi failed")
                : nil
        }
        let registry = WineRegistry(processRunner: runner)
        let bottle = Fixtures.bottleTarget()

        #expect(throws: WineRegistryError.wineCommandFailed("dpi failed")) {
            try registry.apply(WineDisplaySettings(retinaMode: true, logPixels: 96), to: bottle)
        }
        #expect(runner.invocations.count == 2)
    }
}

@Suite struct WineCompatibilityApplyTests {
    @Test func noOpWhenRendererIsUnset() throws {
        let runner = FakeProcessRunner()
        let registry = WineRegistry(processRunner: runner)
        let bottle = Fixtures.bottleTarget()

        let result = try registry.apply(WineCompatibilitySettings.none, to: bottle)

        #expect(result == nil)
        #expect(runner.invocations.isEmpty)
    }

    @Test func writesTheDirect3DRendererKeyWhenSet() throws {
        let runner = FakeProcessRunner()
        let registry = WineRegistry(processRunner: runner)
        let bottle = Fixtures.bottleTarget()

        try registry.apply(WineCompatibilitySettings(renderer: .vulkan), to: bottle)

        #expect(runner.invocations.count == 1)
        let call = try #require(runner.invocations.first)
        #expect(call.arguments.contains("HKCU\\Software\\Wine\\Direct3D"))
        #expect(call.arguments.contains("renderer"))
        #expect(call.arguments.contains("vulkan"))
    }

    @Test func rendererWriteFailureThrows() {
        let runner = FakeProcessRunner()
        runner.defaultResult = ProcessResult(exitCode: 1, stdout: "", stderr: "renderer write failed")
        let registry = WineRegistry(processRunner: runner)
        let bottle = Fixtures.bottleTarget()

        #expect(throws: WineRegistryError.wineCommandFailed("renderer write failed")) {
            try registry.apply(WineCompatibilitySettings(renderer: .gdi), to: bottle)
        }
    }
}

@Suite struct WineRegistryCurrentSettingsTests {
    @Test func readsRetinaModeAndLogPixelsFromUserReg() throws {
        let dir = Fixtures.makeTempDirectory("wine-current-settings")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Fixtures.regFileFixture.write(to: dir.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)

        let bottle = Fixtures.bottleTarget(prefixPath: dir.path)
        let registry = WineRegistry(processRunner: FakeProcessRunner())
        let settings = try #require(registry.currentSettings(for: bottle))

        #expect(settings.retinaMode == true)
        #expect(settings.logPixels == 144)
    }

    @Test func returnsNilWhenUserRegMissing() {
        let dir = Fixtures.makeTempDirectory("wine-missing-reg")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bottle = Fixtures.bottleTarget(prefixPath: dir.path)
        let registry = WineRegistry(processRunner: FakeProcessRunner())
        #expect(registry.currentSettings(for: bottle) == nil)
    }
}

@Suite struct WineRegistryFileParserTests {
    @Test func readsStringValueFromItsSection() {
        let text = Fixtures.regFileFixture
        #expect(WineRegistryFileParser.readString(text, section: #"Software\\Wine\\Mac Driver"#, key: "RetinaMode") == "y")
    }

    @Test func readsDWordAsDecimalFromHexEncoding() {
        let text = Fixtures.regFileFixture
        #expect(WineRegistryFileParser.readDWord(text, section: #"Control Panel\\Desktop"#, key: "LogPixels") == 144)
    }

    @Test func doesNotBleedValuesAcrossSectionBoundaries() {
        // "LogPixels" only exists in the Desktop section; looking it up
        // against the (earlier, adjacent) Mac Driver section must miss —
        // regression coverage for sectionBody's next-"["-line cutoff.
        let text = Fixtures.regFileFixture
        #expect(WineRegistryFileParser.readDWord(text, section: #"Software\\Wine\\Mac Driver"#, key: "LogPixels") == nil)
    }

    @Test func returnsNilForUnknownSection() {
        #expect(WineRegistryFileParser.readString(Fixtures.regFileFixture, section: "Nope\\Nope", key: "RetinaMode") == nil)
    }
}
