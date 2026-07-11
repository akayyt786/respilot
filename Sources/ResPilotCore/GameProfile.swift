import Foundation

/// What a profile launches once display/registry settings are applied.
public enum LaunchTarget: Codable, Equatable, Sendable {
    /// A `.app` bundle (CrossOver-installed app, or a Wineskin-style
    /// wrapper itself) — opened via `open`.
    case appBundle(path: String)
    /// A raw Windows executable inside the bottle's `drive_c` — launched
    /// via `wine start /unix <path>`.
    case windowsExecutable(path: String)

    public var path: String {
        switch self {
        case .appBundle(let path): return path
        case .windowsExecutable(let path): return path
        }
    }
}

/// A saved "how to run this game" recipe: which bottle, what to launch, and
/// the macOS + Wine display settings that combination needs.
public struct GameProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var bottle: WineBottleTarget
    public var launchTarget: LaunchTarget
    public var display: DisplayTarget
    public var wineRetinaMode: Bool
    public var wineLogPixels: Int?
    public var autoRevertOnQuit: Bool
    /// Wine compatibility toggles beyond display/DPI — see
    /// `WineCompatibilitySettings`. Defaults to `.none` (touches nothing),
    /// so profiles saved before this field existed keep behaving exactly
    /// as before.
    public var compatibility: WineCompatibilitySettings

    public init(
        id: UUID = UUID(),
        name: String,
        bottle: WineBottleTarget,
        launchTarget: LaunchTarget,
        display: DisplayTarget,
        wineRetinaMode: Bool,
        wineLogPixels: Int? = nil,
        autoRevertOnQuit: Bool = true,
        compatibility: WineCompatibilitySettings = .none
    ) {
        self.id = id
        self.name = name
        self.bottle = bottle
        self.launchTarget = launchTarget
        self.display = display
        self.wineRetinaMode = wineRetinaMode
        self.wineLogPixels = wineLogPixels
        self.autoRevertOnQuit = autoRevertOnQuit
        self.compatibility = compatibility
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, bottle, launchTarget, display, wineRetinaMode, wineLogPixels, autoRevertOnQuit, compatibility
    }

    /// Hand-written so a `compatibility` key missing from disk (any
    /// `profiles.json` written before this field existed) decodes as
    /// `.none` instead of failing the whole load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bottle = try container.decode(WineBottleTarget.self, forKey: .bottle)
        launchTarget = try container.decode(LaunchTarget.self, forKey: .launchTarget)
        display = try container.decode(DisplayTarget.self, forKey: .display)
        wineRetinaMode = try container.decode(Bool.self, forKey: .wineRetinaMode)
        wineLogPixels = try container.decodeIfPresent(Int.self, forKey: .wineLogPixels)
        autoRevertOnQuit = try container.decode(Bool.self, forKey: .autoRevertOnQuit)
        compatibility = try container.decodeIfPresent(WineCompatibilitySettings.self, forKey: .compatibility) ?? .none
    }

    public var wineSettings: WineDisplaySettings {
        WineDisplaySettings(retinaMode: wineRetinaMode, logPixels: wineLogPixels)
    }
}

/// Common DPI presets (standard Windows `LogPixels` values).
public enum DPIPreset {
    public static let scale100 = 96
    public static let scale125 = 120
    public static let scale150 = 144
    public static let scale200 = 192
}

/// `wined3d`'s backend selector — the upstream-documented
/// `HKCU\Software\Wine\Direct3D\renderer` key (see
/// winehq.org/UsefulRegistryKeys). Valid values per that doc are `gdi`,
/// `gl`, and `vulkan`; `gdi`'s "no3d" alias is omitted here as redundant.
/// Deliberately does NOT cover DXVK/DXMT/D3DMetal: switching those
/// requires installing/uninstalling actual translation-layer DLLs inside
/// the bottle (what Sikarugir's and CrossOver's own backend toggles do
/// under the hood), which ResPilot has no part in — it manages settings on
/// bottles it doesn't create or provision. Flipping a DLL override to
/// "native" without the DLL present breaks the bottle instead of helping it.
public enum WineD3DRenderer: String, Codable, Sendable, Equatable, CaseIterable {
    case gl
    case vulkan
    case gdi

    public var displayName: String {
        switch self {
        case .gl: return "OpenGL (default)"
        case .vulkan: return "Vulkan (work in progress upstream)"
        case .gdi: return "GDI / software (no 3D)"
        }
    }
}

/// Wine compatibility toggles beyond display/DPI that ResPilot can safely
/// manage without touching bottle contents: the `wined3d` renderer and the
/// ESync/MSync synchronization primitives (`WINEESYNC`/`WINEMSYNC`
/// environment variables, standard since Wine 3.x / wine-staging).
public struct WineCompatibilitySettings: Codable, Equatable, Sendable {
    /// `nil` leaves whatever renderer is already configured (or Wine's
    /// built-in default) untouched — no registry write happens.
    public var renderer: WineD3DRenderer?
    public var esync: Bool
    public var msync: Bool

    public init(renderer: WineD3DRenderer? = nil, esync: Bool = false, msync: Bool = false) {
        self.renderer = renderer
        self.esync = esync
        self.msync = msync
    }

    /// No-op value: no registry write, no environment override. Also the
    /// decode default for profiles saved before this setting existed.
    public static let none = WineCompatibilitySettings()
}
