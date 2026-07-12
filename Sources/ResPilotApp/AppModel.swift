import Foundation
import ResPilotCore

/// All app state and the only place the SwiftUI layer talks to
/// `ResPilotCore`. Kept deliberately thin — every real decision (sequencing,
/// safety invariants, registry format, discovery) already lives in Core and
/// is unit- and CLI-smoke-tested there; this class just adapts it to
/// `@Published` properties views can bind to.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profiles: [GameProfile] = []
    @Published private(set) var discoveredCrossOverBottles: [DiscoveredBottle] = []
    @Published private(set) var discoveredWineskinBottles: [DiscoveredBottle] = []
    @Published private(set) var discoveredRespilotManagedBottles: [DiscoveredBottle] = []
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var hasPendingRestore: Bool = false
    @Published private(set) var launchingProfileID: UUID?
    @Published var lastError: String?
    @Published private(set) var isInstallingApp = false
    @Published private(set) var installStatusText: String = ""
    @Published private(set) var lastInstalledBottle: WineBottleTarget?
    @Published private(set) var epicAccount: String?
    @Published private(set) var epicGames: [EpicGame] = []
    @Published private(set) var epicBusy = false
    @Published private(set) var epicStatusText = ""
    @Published private(set) var epicPlayingAppName: String?

    private let store: ProfileStore
    private let locator: BottleLocator
    private let orchestrator: LaunchOrchestrator
    private let breadcrumbStore: DisplayRestoreBreadcrumbStore
    private let installer: AppInstaller
    private let winetricks: Winetricks
    private let installerDownloader: InstallerDownloader
    private let wineEngineManager: WineEngineManager
    private let nativeAppInstaller: NativeAppInstaller
    private let legendary: LegendaryClient

    init(
        store: ProfileStore = ProfileStore(),
        locator: BottleLocator = BottleLocator(),
        orchestrator: LaunchOrchestrator = LaunchOrchestrator(),
        breadcrumbStore: DisplayRestoreBreadcrumbStore = DisplayRestoreBreadcrumbStore(),
        installer: AppInstaller = AppInstaller(),
        winetricks: Winetricks = Winetricks(),
        installerDownloader: InstallerDownloader = InstallerDownloader(),
        wineEngineManager: WineEngineManager = WineEngineManager(),
        nativeAppInstaller: NativeAppInstaller = NativeAppInstaller(),
        legendary: LegendaryClient = LegendaryClient()
    ) {
        self.store = store
        self.locator = locator
        self.orchestrator = orchestrator
        self.breadcrumbStore = breadcrumbStore
        self.installer = installer
        self.winetricks = winetricks
        self.installerDownloader = installerDownloader
        self.wineEngineManager = wineEngineManager
        self.nativeAppInstaller = nativeAppInstaller
        self.legendary = legendary
        refreshAll()
    }

    func refreshAll() {
        reloadProfiles()
        rediscoverBottles()
        hasPendingRestore = breadcrumbStore.read() != nil
    }

    func reloadProfiles() {
        do {
            profiles = try store.loadAll().sorted { $0.name < $1.name }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func rediscoverBottles() {
        discoveredCrossOverBottles = locator.discoverCrossOverBottles()
        discoveredWineskinBottles = locator.discoverWineskinStyleWrappers()
        discoveredRespilotManagedBottles = locator.discoverRespilotManagedBottles(wineBinary: wineEngineManager.wineBinaryPath)
    }

    func addProfile(_ profile: GameProfile) {
        do {
            try store.add(profile)
            reloadProfiles()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeProfile(_ profile: GameProfile) {
        do {
            try store.remove(name: profile.name)
            reloadProfiles()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func launch(_ profile: GameProfile) {
        guard launchingProfileID == nil else { return }
        launchingProfileID = profile.id
        statusMessage = "Launching \(profile.name)…"
        lastError = nil
        Task {
            do {
                _ = try await orchestrator.launch(profile)
                launchingProfileID = nil
                hasPendingRestore = await orchestrator.hasPendingRestore
                statusMessage = hasPendingRestore ? "\(profile.name) running" : "Idle"
                await orchestrator.awaitActiveSession()
                hasPendingRestore = await orchestrator.hasPendingRestore
                statusMessage = "Idle"
            } catch {
                lastError = error.localizedDescription
                statusMessage = "Failed to launch \(profile.name)"
                launchingProfileID = nil
            }
        }
    }

    func restoreNow() {
        Task {
            do {
                let didRestore = try await orchestrator.restoreNow()
                statusMessage = didRestore ? "Display restored" : "Nothing to restore"
                hasPendingRestore = false
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// `Install App` no longer requires CrossOver: it downloads and uses
    /// ResPilot's own free engine (`WineEngineManager`) the first time
    /// it's needed, so this is always `true` — kept as a property (rather
    /// than deleted outright) so a view checking it doesn't need to change
    /// if a future gate (e.g. "no disk space") is ever added here.
    var canInstallApps: Bool { true }

    /// Whether `installApp` will need to pause on a one-time ~190MB engine
    /// download before it can do anything else. Views use this to set
    /// expectations up front instead of the first install silently taking
    /// much longer than a later one.
    var isWineEngineInstalled: Bool { wineEngineManager.isInstalled }

    /// The Wine binary every `.respilotManaged` bottle addresses — same
    /// path regardless of whether the engine has been downloaded yet, so
    /// `ProfileEditorView` can build a target for a bottle that will be
    /// created on first launch.
    var wineEngineBinaryPath: String { wineEngineManager.wineBinaryPath }

    /// For a `.wineBottle` app: creates a bottle, provisions
    /// `app`'s recommended Winetricks verbs, then runs an installer
    /// inside it — genuinely one click when `app.resolvedDirectDownloadURL`
    /// exists (downloaded automatically); pass `installerPath` yourself to
    /// use a file you already downloaded instead (the fallback if the
    /// vendor's link ever changes). Uses ResPilot's own free, self-managed
    /// Wine engine — downloading it first if this is the first install
    /// ever — so no CrossOver install is required. Does not create a
    /// `GameProfile` — see `AppInstaller`'s own doc comment for why;
    /// `lastInstalledBottle` is there so a view can hand it straight to
    /// `ProfileEditorView`.
    ///
    /// For a `.nativeMacApp` app (see `CatalogApp.AppInstallKind`):
    /// downloads and installs straight into `/Applications` via
    /// `NativeAppInstaller` — no engine, no bottle, no Winetricks.
    /// `bottleName` is ignored in this branch.
    func installApp(_ app: CatalogApp, bottleName: String, installerPath: String? = nil) {
        guard !isInstallingApp else { return }
        if installerPath == nil, app.resolvedDirectDownloadURL == nil {
            lastError = "No direct download link for \(app.name); choose a file you've already downloaded instead."
            return
        }
        isInstallingApp = true
        installStatusText = "Starting…"
        lastError = nil
        switch app.installKind {
        case .wineBottle:
            installWineBottleApp(app, bottleName: bottleName, installerPath: installerPath)
        case .nativeMacApp:
            installNativeMacApp(app, installerPath: installerPath)
        }
    }

    private func installWineBottleApp(_ app: CatalogApp, bottleName: String, installerPath: String?) {
        Task {
            do {
                if !wineEngineManager.isInstalled {
                    try await wineEngineManager.install(onProgress: { [weak self] status in
                        Task { @MainActor in self?.installStatusText = status }
                    })
                }
                let resolvedInstallerPath: String
                if let installerPath {
                    resolvedInstallerPath = installerPath
                } else {
                    installStatusText = "Downloading the \(app.name) installer…"
                    let localURL = try await installerDownloader.download(app.resolvedDirectDownloadURL!)
                    resolvedInstallerPath = localURL.path
                }
                if !winetricks.isInstalled {
                    installStatusText = "Setting up Winetricks…"
                    try await winetricks.install()
                }
                let bottle = try await installer.install(
                    bottleName: bottleName,
                    bottleDirectory: BottleLocator.defaultRespilotBottleDirectory(),
                    wineBinary: wineEngineManager.wineBinaryPath,
                    kind: .respilotManaged,
                    verbs: app.recommendedVerbs,
                    installerPath: resolvedInstallerPath,
                    onStep: { [weak self] step in
                        Task { @MainActor in self?.apply(step, appName: app.name) }
                    }
                )
                lastInstalledBottle = bottle
                rediscoverBottles()
                isInstallingApp = false
            } catch {
                lastError = error.localizedDescription
                installStatusText = "Failed"
                isInstallingApp = false
            }
        }
    }

    private func installNativeMacApp(_ app: CatalogApp, installerPath: String?) {
        Task {
            do {
                let source = installerPath.map { URL(fileURLWithPath: $0) } ?? app.resolvedDirectDownloadURL!
                _ = try await nativeAppInstaller.install(
                    from: source,
                    appName: app.name,
                    onProgress: { [weak self] status in
                        Task { @MainActor in self?.installStatusText = status }
                    }
                )
                isInstallingApp = false
            } catch {
                lastError = error.localizedDescription
                installStatusText = "Failed"
                isInstallingApp = false
            }
        }
    }

    private func apply(_ step: InstallStep, appName: String) {
        switch step {
        case .creatingBottle: installStatusText = "Creating bottle…"
        case .installingDependencies(let verb): installStatusText = "Installing \(verb)…"
        case .runningInstaller: installStatusText = "Running the \(appName) installer…"
        case .done: installStatusText = "Done"
        }
    }

    // MARK: - Epic Games (via Legendary)

    /// Ensures Legendary is installed, then refreshes `epicAccount` and
    /// (if logged in) `epicGames`. Runs off the main actor (`Task.detached`)
    /// since this can block on real process calls with multi-second-to-
    /// minute timeouts (`accountName`/`listGames`) — same reasoning
    /// `epicInstall`/`epicPlay` detach for their own, much longer blocking
    /// calls. The only Epic method not gated by `guard !epicBusy`: every
    /// other method below calls this once its own operation finishes, and
    /// it must be able to run regardless of the busy state that caller
    /// hasn't cleared yet.
    ///
    /// `self` is captured strongly (not `[weak self]`) into each
    /// `Task.detached` below: `AppModel` is the app's root, app-lifetime
    /// state object, so there's no meaningful early-deallocation case to
    /// guard against here, and a weak capture re-read from a
    /// concurrently-executing (non-actor-isolated) closure is exactly
    /// what the Swift 6 "reference to captured var … in concurrently-
    /// executing code" diagnostic flags as unsafe.
    func refreshEpic() {
        epicBusy = true
        lastError = nil
        let legendary = self.legendary
        Task.detached {
            do {
                if !legendary.isInstalled {
                    try await legendary.install(onProgress: { status in
                        Task { @MainActor in self.epicStatusText = status }
                    })
                }
                let account = try legendary.accountName()
                let games = account != nil ? try legendary.listGames() : []
                await MainActor.run {
                    self.epicAccount = account
                    self.epicGames = games
                    self.epicBusy = false
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.epicBusy = false
                }
            }
        }
    }

    func epicLogin(code: String) {
        guard !epicBusy else { return }
        epicBusy = true
        epicStatusText = "Logging in…"
        lastError = nil
        let legendary = self.legendary
        let trimmed = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        Task.detached {
            do {
                try legendary.login(code: trimmed)
                await self.refreshEpic()
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.epicBusy = false
                }
            }
        }
    }

    func epicLogout() {
        guard !epicBusy else { return }
        epicBusy = true
        lastError = nil
        let legendary = self.legendary
        Task.detached {
            do {
                try legendary.logout()
                await MainActor.run {
                    self.epicAccount = nil
                    self.epicGames = []
                    self.epicBusy = false
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.epicBusy = false
                }
            }
        }
    }

    func epicInstall(_ game: EpicGame) {
        guard !epicBusy else { return }
        epicBusy = true
        epicStatusText = "Installing \(game.title)…"
        lastError = nil
        let legendary = self.legendary
        Task.detached {
            do {
                try legendary.installGame(appName: game.appName, onProgress: { status in
                    Task { @MainActor in self.epicStatusText = status }
                })
                await self.refreshEpic()
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.epicStatusText = "Failed"
                    self.epicBusy = false
                }
            }
        }
    }

    /// Orchestration order: ensure ResPilot's Wine engine is installed,
    /// ensure the shared `EpicGames` bottle exists, provision it with
    /// core fonts/VC++ runtime the first time only, then launch the game
    /// through Legendary — which blocks until the player quits. Runs
    /// entirely off the main actor (`Task.detached`): `legendary.launch`
    /// alone can block for an entire game session.
    func epicPlay(_ game: EpicGame) {
        guard !epicBusy else { return }
        epicBusy = true
        epicStatusText = "Preparing \(game.title)…"
        lastError = nil
        let legendary = self.legendary
        let wineEngineManager = self.wineEngineManager
        let winetricks = self.winetricks
        Task.detached {
            do {
                if !wineEngineManager.isInstalled {
                    try await wineEngineManager.install(onProgress: { status in
                        Task { @MainActor in self.epicStatusText = status }
                    })
                }

                let bottle = WineBottleTarget(
                    kind: .respilotManaged,
                    prefixPath: BottleLocator.defaultRespilotBottleDirectory()
                        .appendingPathComponent(LegendaryClient.epicBottleName).path,
                    wineBinaryPath: wineEngineManager.wineBinaryPath
                )
                let isNewBottle = !FileManager.default.fileExists(atPath: bottle.prefixPath)
                try BottleProvisioner().createPrefix(bottle)

                if isNewBottle {
                    if !winetricks.isInstalled {
                        await MainActor.run { self.epicStatusText = "Setting up Winetricks…" }
                        try await winetricks.install()
                    }
                    await MainActor.run { self.epicStatusText = "Installing fonts and runtime dependencies…" }
                    try winetricks.run(verbs: ["corefonts", "vcrun2019"], in: bottle)
                    await MainActor.run { self.rediscoverBottles() }
                }

                await MainActor.run {
                    self.epicPlayingAppName = game.appName
                    self.epicStatusText = "Launching \(game.title)…"
                }
                try legendary.launch(appName: game.appName, wineBinary: wineEngineManager.wineBinaryPath, winePrefix: bottle.prefixPath)
                await MainActor.run {
                    self.epicPlayingAppName = nil
                    self.epicStatusText = ""
                    self.epicBusy = false
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.epicStatusText = "Failed"
                    self.epicPlayingAppName = nil
                    self.epicBusy = false
                }
            }
        }
    }

    func epicUninstall(_ game: EpicGame) {
        guard !epicBusy else { return }
        epicBusy = true
        epicStatusText = "Uninstalling \(game.title)…"
        lastError = nil
        let legendary = self.legendary
        Task.detached {
            do {
                try legendary.uninstallGame(appName: game.appName)
                await self.refreshEpic()
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.epicStatusText = "Failed"
                    self.epicBusy = false
                }
            }
        }
    }
}
