import Foundation

/// How `AppInstaller`/`NativeAppInstaller` should install a `CatalogApp`.
public enum AppInstallKind: Equatable, Sendable {
    /// The vendor's own Windows installer, run inside a fresh Wine bottle
    /// via `AppInstaller` (creates the bottle, provisions
    /// `recommendedVerbs` through Winetricks, runs the installer).
    case wineBottle
    /// A native macOS `.app`, downloaded as a `.zip` and installed
    /// straight into `/Applications` via `NativeAppInstaller` — no Wine
    /// bottle, no Winetricks, no engine involved. Used when the vendor's
    /// own Windows installer doesn't work reliably under Wine (see that
    /// entry's `knownIssue`) and a genuinely free, actively-maintained
    /// native alternative exists instead — see `NativeAppInstaller`'s doc
    /// comment for the precedent this follows (CodeWeavers' own official
    /// CrossOver guidance for Epic Games Store). `arm64URL`/`x64URL` are
    /// separate because the app itself ships architecture-specific builds
    /// (unlike ResPilot's own Wine engine, which runs the same x86_64
    /// build under Rosetta 2 on both).
    case nativeMacApp(arm64URL: URL, x64URL: URL)
}

/// A curated shortcut, not a compatibility promise. ResPilot has no app
/// compatibility-testing infrastructure of its own — unlike CrossOver,
/// which ships ratings ("Runs Great"/"Runs Well") backed by CodeWeavers'
/// own QA process, this catalog is deliberately just: where to get the
/// vendor's own installer, and which community-documented Winetricks
/// verbs (from WineHQ AppDB / Lutris / Sikarugir issue trackers) tend to
/// help. No vendor logos are bundled — those are trademarked assets
/// ResPilot doesn't have rights to redistribute.
public struct CatalogApp: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let vendor: String
    /// The vendor's own download *page* — always a fallback the user can
    /// open by hand, since `directDownloadURL` (below) is an unofficial
    /// discovery that could change without notice.
    public let downloadPageURL: URL
    /// A direct link to the vendor's own Windows installer, on the
    /// vendor's own domain. Only meaningful for `.wineBottle` entries —
    /// see `resolvedDirectDownloadURL` for the kind-aware accessor every
    /// call site should actually use. None of Steam, Epic, or Rockstar
    /// *document* a stable direct link for public use — their support
    /// pages just say "go to the website and click Install/Download" —
    /// but the button on each of those pages resolves to one of these
    /// under the hood. Found by inspecting each vendor's real
    /// page/network behavior (not a search-result guess, not a
    /// third-party mirror) and verified live before shipping. `nil` means
    /// only the manual (download-page) path is available for that entry.
    public let directDownloadURL: URL?
    /// Community-documented Winetricks verbs worth trying first. Empty
    /// for `.nativeMacApp` entries — nothing to provision, there's no
    /// bottle. Starting points, not guarantees — see `knownIssue` for
    /// cases where even these are currently insufficient.
    public let recommendedVerbs: [String]
    /// A specific, sourced caveat, surfaced in the UI instead of silently
    /// letting the user hit a confusing failure.
    public let knownIssue: String?
    public let installKind: AppInstallKind

    public init(
        name: String,
        vendor: String,
        downloadPageURL: URL,
        directDownloadURL: URL? = nil,
        recommendedVerbs: [String],
        knownIssue: String? = nil,
        installKind: AppInstallKind = .wineBottle
    ) {
        self.name = name
        self.vendor = vendor
        self.downloadPageURL = downloadPageURL
        self.directDownloadURL = directDownloadURL
        self.recommendedVerbs = recommendedVerbs
        self.knownIssue = knownIssue
        self.installKind = installKind
    }

    /// The URL "Install" actually downloads from, kind- and
    /// architecture-aware. `nil` means only the manual download-page path
    /// is available. Every call site (CLI, GUI) should read this instead
    /// of `directDownloadURL` directly, so a `.nativeMacApp` entry's
    /// one-click install works the same way a `.wineBottle` entry's does.
    public var resolvedDirectDownloadURL: URL? {
        switch installKind {
        case .wineBottle:
            return directDownloadURL
        case .nativeMacApp(let arm64URL, let x64URL):
            #if arch(arm64)
            return arm64URL
            #else
            return x64URL
            #endif
        }
    }
}

public enum AppCatalog {
    public static let popular: [CatalogApp] = [
        CatalogApp(
            name: "Steam",
            vendor: "Valve",
            downloadPageURL: URL(string: "https://store.steampowered.com/")!,
            directDownloadURL: URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!,
            recommendedVerbs: ["corefonts", "vcrun2019"]
        ),
        CatalogApp(
            name: "Epic Games (via Heroic)",
            vendor: "Heroic Games Launcher — open source, GPLv3, not affiliated with Epic",
            downloadPageURL: URL(string: "https://heroicgameslauncher.com/")!,
            recommendedVerbs: [],
            knownIssue: "Epic's own Windows installer/launcher does not complete under Wine: two independent, confirmed upstream bugs block it back-to-back (a certificate-store verification failure, then a wine-mono crash — see the WineHQ/Wine-Mono trackers). CodeWeavers' own official CrossOver guidance doesn't run Epic's installer either — they recommend Heroic Games Launcher instead (support.codeweavers.com/common-actions/heroic-games-launcher-in-crossover). ResPilot does the same: this installs Heroic directly as a native Mac app, no Wine bottle involved. Sign into your Epic account inside Heroic to browse, download, and launch your library; Heroic can use CrossOver as a Windows-game runner if you have it, or point at a ResPilot-managed bottle for any Windows-only title.",
            installKind: .nativeMacApp(
                arm64URL: URL(string: "https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/releases/download/v2.22.0/Heroic-2.22.0-macOS-arm64.zip")!,
                x64URL: URL(string: "https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/releases/download/v2.22.0/Heroic-2.22.0-macOS-x64.zip")!
            )
        ),
        CatalogApp(
            name: "Rockstar Games Launcher",
            vendor: "Rockstar Games",
            downloadPageURL: URL(string: "https://www.rockstargames.com/downloads")!,
            directDownloadURL: URL(string: "https://gamedownloads.rockstargames.com/public/installer/Rockstar-Games-Launcher.exe")!,
            recommendedVerbs: ["vcrun2019"],
            knownIssue: "Winetricks' own \"rockstar\" verb is currently reported broken on macOS (Sikarugir-App/Sikarugir#227, open as of this writing) — its package download fails with \"the package is broken.\" This install may not complete; that's an upstream Winetricks issue, not something ResPilot can route around."
        ),
    ]
}
