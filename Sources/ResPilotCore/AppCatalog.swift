import Foundation

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
    /// vendor's own domain. None of Steam, Epic, or Rockstar *document* a
    /// stable direct link for public use — their support pages just say
    /// "go to the website and click Install/Download" — but the button on
    /// each of those pages resolves to one of these under the hood. Found
    /// by inspecting each vendor's real page/network behavior (not a
    /// search-result guess, not a third-party mirror) and verified live
    /// before shipping. `nil` means only the manual (download-page) path
    /// is available for that entry.
    public let directDownloadURL: URL?
    /// Community-documented Winetricks verbs worth trying first. Starting
    /// points, not guarantees — see `knownIssue` for cases where even
    /// these are currently insufficient.
    public let recommendedVerbs: [String]
    /// A specific, sourced caveat, surfaced in the UI instead of silently
    /// letting the user hit a confusing failure.
    public let knownIssue: String?

    public init(
        name: String,
        vendor: String,
        downloadPageURL: URL,
        directDownloadURL: URL? = nil,
        recommendedVerbs: [String],
        knownIssue: String? = nil
    ) {
        self.name = name
        self.vendor = vendor
        self.downloadPageURL = downloadPageURL
        self.directDownloadURL = directDownloadURL
        self.recommendedVerbs = recommendedVerbs
        self.knownIssue = knownIssue
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
            name: "Epic Games Launcher",
            vendor: "Epic Games",
            downloadPageURL: URL(string: "https://store.epicgames.com/download")!,
            // Epic's own launcher API — redirects to whatever the current
            // version's CDN URL is, so this stays correct as they ship updates.
            directDownloadURL: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.exe")!,
            recommendedVerbs: ["vcrun2019"],
            knownIssue: "Currently does not complete on Wine — two independent, confirmed upstream blockers stack back-to-back. (1) The installer verifies its embedded MSI payload's Authenticode signature before running and fails with \"The embedded MSI payload failed signature verification. Certificate CN does not match 'Epic Games Inc.'\", because a fresh Wine bottle's certificate store ships with no root CAs (long-standing Wine/WinTrust limitation; no Winetricks/registry fix exists). (2) Clicking past that, the installer's .NET-based components crash Wine's built-in Mono runtime with \"wine-mono-11.1.0/mono/mono/eglib/gmisc-win32.c: assertion 'filename != NULL' failed\" (tracked upstream, e.g. lutris/lutris#6690) — fixing this needs a full standalone Mono MSI installed into the bottle, not a Winetricks verb. Reproduced live against a real bottle, both blockers confirmed independently; not a ResPilot bug and not something its provisioning can currently route around."
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
