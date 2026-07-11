import Foundation

/// Sequences one profile launch: apply Wine registry settings, switch the
/// macOS display mode, launch, then restore the display once the game
/// exits. An `actor` because a background watch task and manual
/// `restoreNow()` calls (from a menu bar "Restore Display Now" button) can
/// legitimately race, and both touch the same "what do we restore to"
/// state.
///
/// Safety invariant this type exists to guarantee: the screen never gets
/// stuck on a mode the user didn't ask for. Concretely —
///   * the display is only ever changed *after* the Wine registry write
///     succeeds (so a failed write never leaves a dangling display change).
///   * if launching the target fails after the display was already
///     switched, it is restored immediately before the error propagates.
///   * `restoreNow()` is always safe to call, from anywhere, at any time
///     (idempotent no-op once nothing is pending).
public actor LaunchOrchestrator {
    private let displayProvider: DisplayModeProviding
    private let wineRegistry: WineRegistry
    private let appLauncher: AppLaunching
    private let breadcrumbStore: DisplayRestoreBreadcrumbStore

    private var lastKnownGoodMode: DisplayModeInfo?
    private var activeWatchTask: Task<Void, Never>?

    public init(
        displayProvider: DisplayModeProviding = CoreGraphicsDisplayModeProvider(),
        wineRegistry: WineRegistry = WineRegistry(),
        appLauncher: AppLaunching = SystemAppLauncher(),
        breadcrumbStore: DisplayRestoreBreadcrumbStore = DisplayRestoreBreadcrumbStore()
    ) {
        self.displayProvider = displayProvider
        self.wineRegistry = wineRegistry
        self.appLauncher = appLauncher
        self.breadcrumbStore = breadcrumbStore
    }

    /// True while a display-mode change is outstanding (i.e. `restoreNow`
    /// would actually do something). Menu bar UI uses this for its status
    /// indicator.
    public var hasPendingRestore: Bool { lastKnownGoodMode != nil }

    @discardableResult
    public func launch(_ profile: GameProfile) async throws -> LaunchHandle {
        let displayID = displayProvider.mainDisplayID
        let before = try displayProvider.currentMode(display: displayID)

        // 1. Wine-side registry keys first: a pure write with no visible
        //    effect, so if it fails we bail before touching the screen.
        try wineRegistry.apply(profile.wineSettings, to: profile.bottle)
        try wineRegistry.apply(profile.compatibility, to: profile.bottle)

        // 2. macOS display mode, only if the profile asks for a change.
        var changedDisplay = false
        if !profile.display.isLeaveUnchanged {
            let available = try displayProvider.availableModes(display: displayID)
            guard let target = DisplayModeMatcher.match(target: profile.display, in: available) else {
                throw DisplayModeError.noMatchingMode(profile.display, available: available)
            }
            try displayProvider.setMode(target, display: displayID)
            changedDisplay = true
        }
        if changedDisplay {
            lastKnownGoodMode = before
            try? breadcrumbStore.write(before)
        }

        // 3. Launch. If this throws after we already changed the display,
        //    put it back before propagating — nothing is going to use the
        //    new mode now.
        let handle: LaunchHandle
        do {
            switch profile.launchTarget {
            case .appBundle(let path):
                // Only override the launched process's environment when
                // there's something to add (ESync/MSync opt-in) — leaves
                // LaunchServices' default inheritance untouched otherwise,
                // so a profile with default compatibility settings behaves
                // byte-for-byte like before this setting existed.
                var launchEnvironment: [String: String]?
                if profile.compatibility.esync || profile.compatibility.msync {
                    var env = ProcessInfo.processInfo.environment
                    if profile.compatibility.esync { env["WINEESYNC"] = "1" }
                    if profile.compatibility.msync { env["WINEMSYNC"] = "1" }
                    launchEnvironment = env
                }
                handle = try await appLauncher.launchApp(at: path, environment: launchEnvironment)
            case .windowsExecutable(let path):
                handle = try await appLauncher.launchWindowsExecutable(path: path, in: profile.bottle, compatibility: profile.compatibility)
            }
        } catch {
            if changedDisplay {
                _ = try? await restoreNow()
            }
            throw error
        }

        if profile.autoRevertOnQuit && changedDisplay {
            activeWatchTask?.cancel()
            let launcher = appLauncher
            activeWatchTask = Task { [weak self] in
                await launcher.awaitCompletion(handle)
                guard let self, !Task.isCancelled else { return }
                _ = try? await self.restoreNow()
            }
        }
        return handle
    }

    /// Awaits the auto-restore watch task started by the last `launch()`
    /// call, if one is active. A blocking CLI invocation uses this to stay
    /// alive until the game exits and the display is back to normal —
    /// without it, the process would exit immediately and the background
    /// `Task` would be orphaned along with it.
    public func awaitActiveSession() async {
        await activeWatchTask?.value
    }

    /// Restores the display mode captured just before the last successful
    /// launch. Safe to call unconditionally (e.g. from a UI escape hatch);
    /// it's a no-op once there is nothing pending.
    @discardableResult
    public func restoreNow() async throws -> Bool {
        activeWatchTask?.cancel()
        activeWatchTask = nil
        guard let mode = lastKnownGoodMode else { return false }
        try displayProvider.setMode(mode, display: displayProvider.mainDisplayID)
        lastKnownGoodMode = nil
        try? breadcrumbStore.clear()
        return true
    }
}

