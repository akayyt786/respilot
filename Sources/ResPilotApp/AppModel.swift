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
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var hasPendingRestore: Bool = false
    @Published private(set) var launchingProfileID: UUID?
    @Published var lastError: String?
    @Published private(set) var isInstallingApp = false
    @Published private(set) var installStatusText: String = ""
    @Published private(set) var lastInstalledBottle: WineBottleTarget?

    private let store: ProfileStore
    private let locator: BottleLocator
    private let orchestrator: LaunchOrchestrator
    private let breadcrumbStore: DisplayRestoreBreadcrumbStore
    private let installer: AppInstaller
    private let winetricks: Winetricks
    private let installerDownloader: InstallerDownloader

    init(
        store: ProfileStore = ProfileStore(),
        locator: BottleLocator = BottleLocator(),
        orchestrator: LaunchOrchestrator = LaunchOrchestrator(),
        breadcrumbStore: DisplayRestoreBreadcrumbStore = DisplayRestoreBreadcrumbStore(),
        installer: AppInstaller = AppInstaller(),
        winetricks: Winetricks = Winetricks(),
        installerDownloader: InstallerDownloader = InstallerDownloader()
    ) {
        self.store = store
        self.locator = locator
        self.orchestrator = orchestrator
        self.breadcrumbStore = breadcrumbStore
        self.installer = installer
        self.winetricks = winetricks
        self.installerDownloader = installerDownloader
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

    /// True when a CrossOver.app is installed and ResPilot can discover
    /// its `wine` binary — the one thing `installApp` needs to create a
    /// fresh bottle. Views use this to disable the Install action with an
    /// honest reason instead of letting it fail deep into the flow.
    var canInstallApps: Bool { discoveredCrossOverWineBinary() != nil }

    private func discoveredCrossOverWineBinary() -> URL? {
        BottleLocator.crossOverAppCandidates()
            .first { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap { locator.crossOverWineBinary(appBundle: $0) }
    }

    /// Creates a bottle, provisions `app`'s recommended Winetricks verbs,
    /// then runs an installer inside it — genuinely one click when
    /// `app.directDownloadURL` exists (downloaded automatically); pass
    /// `installerPath` yourself to use a file you already downloaded
    /// instead (the fallback if the vendor's link ever changes). Does not
    /// create a `GameProfile` — see `AppInstaller`'s own doc comment for
    /// why; `lastInstalledBottle` is there so a view can hand it straight
    /// to `ProfileEditorView`.
    func installApp(_ app: CatalogApp, bottleName: String, installerPath: String? = nil) {
        guard !isInstallingApp else { return }
        guard let wineBinary = discoveredCrossOverWineBinary() else {
            lastError = "No installed CrossOver.app found — ResPilot needs an existing Wine engine to create a new bottle with."
            return
        }
        if installerPath == nil, app.directDownloadURL == nil {
            lastError = "No direct download link for \(app.name); choose a file you've already downloaded instead."
            return
        }
        isInstallingApp = true
        installStatusText = "Starting…"
        lastError = nil
        Task {
            do {
                let resolvedInstallerPath: String
                if let installerPath {
                    resolvedInstallerPath = installerPath
                } else {
                    installStatusText = "Downloading the \(app.name) installer…"
                    let localURL = try await installerDownloader.download(app.directDownloadURL!)
                    resolvedInstallerPath = localURL.path
                }
                if !winetricks.isInstalled {
                    installStatusText = "Setting up Winetricks…"
                    try await winetricks.install()
                }
                let bottle = try await installer.install(
                    bottleName: bottleName,
                    bottleDirectory: BottleLocator.defaultCrossOverBottleDirectory(),
                    wineBinary: wineBinary.path,
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

    private func apply(_ step: InstallStep, appName: String) {
        switch step {
        case .creatingBottle: installStatusText = "Creating bottle…"
        case .installingDependencies(let verb): installStatusText = "Installing \(verb)…"
        case .runningInstaller: installStatusText = "Running the \(appName) installer…"
        case .done: installStatusText = "Done"
        }
    }
}
