import Foundation
import Testing
@testable import ResPilotCore

/// `GameProfile.compatibility` was added after `profiles.json` was already
/// a shipped, on-disk format. These tests exist specifically to prove that
/// addition never breaks decoding a file written before the field existed —
/// the exact regression a hand-written `init(from:)` (instead of relying on
/// synthesized `Codable`) is there to prevent.
@Suite struct GameProfileBackwardCompatibilityTests {
    private static let legacyJSON = """
    {
        "id": "8C8B2E3E-6A9B-4B7C-9B0A-2E6E2C9B7A00",
        "name": "Legacy Game",
        "bottle": {
            "kind": "crossOver",
            "prefixPath": "/tmp/prefix",
            "wineBinaryPath": "/tmp/wine",
            "crossOverBottleName": "LegacyBottle"
        },
        "launchTarget": { "appBundle": { "path": "/Applications/Legacy.app" } },
        "display": { "pointWidth": 0, "pointHeight": 0, "hiDPI": false },
        "wineRetinaMode": true,
        "autoRevertOnQuit": true
    }
    """

    @Test func decodingAProfileWrittenBeforeCompatibilityExistedDefaultsToNone() throws {
        let data = Data(Self.legacyJSON.utf8)
        let profile = try JSONDecoder().decode(GameProfile.self, from: data)

        #expect(profile.name == "Legacy Game")
        #expect(profile.compatibility == .none)
        #expect(profile.compatibility.renderer == nil)
        #expect(profile.compatibility.esync == false)
        #expect(profile.compatibility.msync == false)
    }

    @Test func decodingAProfileArrayWrittenBeforeCompatibilityExisted() throws {
        let data = Data("[\(Self.legacyJSON)]".utf8)
        let profiles = try JSONDecoder().decode([GameProfile].self, from: data)

        #expect(profiles.count == 1)
        #expect(profiles[0].compatibility == .none)
    }

    @Test func roundTripsCompatibilitySettingsThroughEncodeDecode() throws {
        let original = Fixtures.profile(
            compatibility: WineCompatibilitySettings(renderer: .vulkan, esync: true, msync: false)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GameProfile.self, from: data)

        #expect(decoded == original)
        #expect(decoded.compatibility.renderer == .vulkan)
        #expect(decoded.compatibility.esync == true)
        #expect(decoded.compatibility.msync == false)
    }
}
