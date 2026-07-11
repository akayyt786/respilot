import Foundation
import ResPilotCore

func cmdListDisplays() throws {
    let provider = CoreGraphicsDisplayModeProvider()
    let displayID = provider.mainDisplayID
    let current = try provider.currentMode(display: displayID)
    print("Current mode: \(current)")
    print("Available modes:")
    let modes = try provider.availableModes(display: displayID).sorted {
        $0.pointWidth == $1.pointWidth ? $0.pointHeight < $1.pointHeight : $0.pointWidth < $1.pointWidth
    }
    for mode in modes {
        print("  \(mode)")
    }
}

func cmdListBottles() {
    let locator = BottleLocator()
    let crossOver = locator.discoverCrossOverBottles()
    let wineskin = locator.discoverWineskinStyleWrappers()

    print("CrossOver bottles (\(crossOver.count)):")
    for bottle in crossOver {
        print("  \(bottle.name)  [\(bottle.target.prefixPath)]")
    }
    if crossOver.isEmpty {
        print("  (none found — is CrossOver.app installed with at least one bottle?)")
    }

    print("Wineskin/Kegworks/Sikarugir-style wrappers (\(wineskin.count)):")
    for bottle in wineskin {
        print("  \(bottle.name)  [\(bottle.target.prefixPath)]")
    }
    if wineskin.isEmpty {
        print("  (none found under /Applications or ~/Applications)")
    }
}

func cmdListProfiles() throws {
    let profiles = try ProfileStore().loadAll()
    if profiles.isEmpty {
        print("No profiles yet. Create one with \"respilot add-profile\".")
        return
    }
    for profile in profiles.sorted(by: { $0.name < $1.name }) {
        let displayDesc = profile.display.isLeaveUnchanged
            ? "unchanged"
            : "\(profile.display.pointWidth)x\(profile.display.pointHeight)\(profile.display.hiDPI ? " HiDPI" : "")"
        print("\(profile.name) — \(profile.bottle.kind.rawValue), retina=\(profile.wineRetinaMode ? "y" : "n"), display=\(displayDesc)")
    }
}

func cmdShowProfile(_ args: ArgParser) throws {
    let name = try args.requiredString("name")
    guard let profile = try ProfileStore().find(name: name) else {
        throw ProfileStoreError.notFound(name)
    }
    print("Name: \(profile.name)")
    print("Bottle kind: \(profile.bottle.kind.rawValue)")
    print("Prefix: \(profile.bottle.prefixPath)")
    print("Wine binary: \(profile.bottle.wineBinaryPath)")
    if let bottleName = profile.bottle.crossOverBottleName {
        print("CrossOver bottle name: \(bottleName)")
    }
    print("Launch target: \(profile.launchTarget.path)")
    let displayDesc = profile.display.isLeaveUnchanged
        ? "unchanged"
        : "\(profile.display.pointWidth)x\(profile.display.pointHeight)\(profile.display.hiDPI ? " HiDPI" : "")"
    print("Display target: \(displayDesc)")
    print("Wine RetinaMode: \(profile.wineRetinaMode ? "y" : "n")")
    print("Wine LogPixels: \(profile.wineLogPixels.map(String.init) ?? "unset")")
    print("Auto-revert on quit: \(profile.autoRevertOnQuit)")
    print("Wine renderer: \(profile.compatibility.renderer?.rawValue ?? "unset (Wine default)")")
    print("ESync: \(profile.compatibility.esync), MSync: \(profile.compatibility.msync)")
    if let onDisk = WineRegistry().currentSettings(for: profile.bottle) {
        print("Currently on disk in bottle: RetinaMode=\(onDisk.retinaMode ? "y" : "n"), LogPixels=\(onDisk.logPixels.map(String.init) ?? "unset")")
    } else {
        print("Currently on disk in bottle: unreadable (bottle may not have been booted yet)")
    }
}

func cmdAddProfile(_ args: ArgParser) throws {
    let name = try args.requiredString("name")
    let kindRaw = try args.requiredString("kind")
    let kind: BottleKind
    switch kindRaw {
    case "crossover": kind = .crossOver
    case "wineskin": kind = .wineskinStyle
    default: throw CLIError.invalidValue("kind", "\(kindRaw) (expected \"crossover\" or \"wineskin\")")
    }

    let locator = BottleLocator()
    let bottle: WineBottleTarget
    switch kind {
    case .crossOver:
        let bottleName = try args.requiredString("bottle-name")
        if let prefix = args.string("prefix"), let wineBinary = args.string("wine-binary") {
            bottle = WineBottleTarget(kind: .crossOver, prefixPath: prefix, wineBinaryPath: wineBinary, crossOverBottleName: bottleName)
        } else if let match = locator.discoverCrossOverBottles().first(where: { $0.name == bottleName }) {
            bottle = match.target
        } else {
            throw CLIError.invalidValue(
                "bottle-name",
                "\"\(bottleName)\" not found via auto-discovery; pass --prefix and --wine-binary explicitly"
            )
        }
    case .wineskinStyle:
        if let prefix = args.string("prefix"), let wineBinary = args.string("wine-binary") {
            bottle = WineBottleTarget(kind: .wineskinStyle, prefixPath: prefix, wineBinaryPath: wineBinary)
        } else if let wrapperName = args.string("wrapper-name"),
                  let match = locator.discoverWineskinStyleWrappers().first(where: { $0.name == wrapperName }) {
            bottle = match.target
        } else {
            throw CLIError.missingArgument("prefix (or --wrapper-name for auto-discovery)")
        }
    }

    let launchTarget: LaunchTarget
    if let appPath = args.string("launch-app") {
        launchTarget = .appBundle(path: appPath)
    } else if let exePath = args.string("launch-exe") {
        launchTarget = .windowsExecutable(path: exePath)
    } else {
        throw CLIError.missingArgument("launch-app (or --launch-exe)")
    }

    let display: DisplayTarget
    if let width = args.int("width"), let height = args.int("height") {
        display = DisplayTarget(pointWidth: width, pointHeight: height, hiDPI: args.flag("hidpi"))
    } else {
        display = .leaveUnchanged
    }

    let retinaRaw = try args.requiredString("retina-mode")
    guard retinaRaw == "on" || retinaRaw == "off" else {
        throw CLIError.invalidValue("retina-mode", "\(retinaRaw) (expected \"on\" or \"off\")")
    }

    let renderer: WineD3DRenderer?
    if let rendererRaw = args.string("renderer") {
        guard let parsed = WineD3DRenderer(rawValue: rendererRaw) else {
            throw CLIError.invalidValue("renderer", "\(rendererRaw) (expected one of: \(WineD3DRenderer.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        renderer = parsed
    } else {
        renderer = nil
    }

    let profile = GameProfile(
        name: name,
        bottle: bottle,
        launchTarget: launchTarget,
        display: display,
        wineRetinaMode: retinaRaw == "on",
        wineLogPixels: args.int("dpi"),
        autoRevertOnQuit: !args.flag("no-auto-revert"),
        compatibility: WineCompatibilitySettings(renderer: renderer, esync: args.flag("esync"), msync: args.flag("msync"))
    )
    try ProfileStore().add(profile)
    print("Saved profile \"\(name)\".")
}

func cmdRemoveProfile(_ args: ArgParser) throws {
    let name = try args.requiredString("name")
    try ProfileStore().remove(name: name)
    print("Removed \"\(name)\".")
}

func cmdApply(_ args: ArgParser) async throws {
    let name = try args.requiredString("name")
    guard let profile = try ProfileStore().find(name: name) else {
        throw ProfileStoreError.notFound(name)
    }

    if args.flag("dry-run") {
        let displayDesc = profile.display.isLeaveUnchanged
            ? "unchanged"
            : "\(profile.display.pointWidth)x\(profile.display.pointHeight)\(profile.display.hiDPI ? " HiDPI" : "")"
        print("""
        Would apply "\(profile.name)":
          Bottle:              \(profile.bottle.kind.rawValue) at \(profile.bottle.prefixPath)
          Launch:               \(profile.launchTarget.path)
          Wine RetinaMode:      \(profile.wineRetinaMode ? "y" : "n")
          Wine LogPixels:       \(profile.wineLogPixels.map(String.init) ?? "unset")
          Wine renderer:        \(profile.compatibility.renderer?.rawValue ?? "unset (Wine default)")
          ESync / MSync:        \(profile.compatibility.esync) / \(profile.compatibility.msync)
          macOS display target: \(displayDesc)
        """)
        return
    }

    let orchestrator = LaunchOrchestrator()
    print("Applying \"\(profile.name)\"...")
    _ = try await orchestrator.launch(profile)
    print("Launched. Waiting for it to exit so the display can be restored (detaching early leaves the breadcrumb — run \"respilot restore\" any time)...")
    await orchestrator.awaitActiveSession()
    print("Done.")
}

func cmdRestore() throws {
    let store = DisplayRestoreBreadcrumbStore()
    guard let mode = store.read() else {
        print("Nothing to restore.")
        return
    }
    let provider = CoreGraphicsDisplayModeProvider()
    try provider.setMode(mode, display: provider.mainDisplayID)
    try store.clear()
    print("Restored to \(mode).")
}

func cmdListApps() {
    print("Available apps (Winetricks handles common dependencies; see notes for known issues):")
    for app in AppCatalog.popular {
        print("  \(app.name) — \(app.vendor)")
        print("    \(app.directDownloadURL != nil ? "One-click install (auto-downloads from \(app.directDownloadURL!.host ?? "vendor site"))" : "Manual only — no verified direct link")")
        print("    Download page: \(app.downloadPageURL.absoluteString)")
        print("    Winetricks verbs: \(app.recommendedVerbs.joined(separator: ", "))")
        if let issue = app.knownIssue {
            print("    Known issue: \(issue)")
        }
    }
}

func cmdInstallApp(_ args: ArgParser) async throws {
    let query = try args.requiredString("app")
    guard let catalogApp = AppCatalog.popular.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) else {
        throw CLIError.invalidValue("app", "\"\(query)\" not found. Run \"respilot list-apps\" to see options.")
    }
    let bottleName = args.string("bottle-name") ?? catalogApp.name.replacingOccurrences(of: " ", with: "")

    if args.flag("dry-run") {
        print("""
        Would install "\(catalogApp.name)":
          Vendor:            \(catalogApp.vendor)
          Bottle name:       \(bottleName)
          Winetricks verbs:  \(catalogApp.recommendedVerbs.joined(separator: ", "))
          Download page:     \(catalogApp.downloadPageURL.absoluteString)
        """)
        if let issue = catalogApp.knownIssue {
            print("  Known issue:       \(issue)")
        }
        return
    }

    let installerPath: String
    if let providedPath = args.string("installer") {
        installerPath = providedPath
    } else {
        guard let directURL = catalogApp.directDownloadURL else {
            throw CLIError.invalidValue(
                "installer",
                "No verified direct download link for \"\(catalogApp.name)\" — pass --installer <path to a file you downloaded>."
            )
        }
        print("Downloading \(catalogApp.name) installer from \(directURL.host ?? directURL.absoluteString)...")
        let localURL = try await InstallerDownloader().download(directURL)
        installerPath = localURL.path
    }

    let locator = BottleLocator()
    guard
        let appBundle = BottleLocator.crossOverAppCandidates().first(where: { FileManager.default.fileExists(atPath: $0.path) }),
        let wineBinary = locator.crossOverWineBinary(appBundle: appBundle)
    else {
        throw CLIError.invalidValue(
            "app",
            "No installed CrossOver.app found — ResPilot needs an existing Wine engine to create a new bottle with."
        )
    }

    let winetricks = Winetricks()
    if !winetricks.isInstalled {
        print("Setting up Winetricks...")
        try await winetricks.install()
    }

    print("Installing \"\(catalogApp.name)\" into bottle \"\(bottleName)\"...")
    let installer = AppInstaller(winetricks: winetricks)
    let bottle = try await installer.install(
        bottleName: bottleName,
        bottleDirectory: BottleLocator.defaultCrossOverBottleDirectory(),
        wineBinary: wineBinary.path,
        verbs: catalogApp.recommendedVerbs,
        installerPath: installerPath,
        onStep: { step in
            switch step {
            case .creatingBottle: print("  Creating bottle...")
            case .installingDependencies(let verb): print("  Installing dependency: \(verb)...")
            case .runningInstaller: print("  Running the \(catalogApp.name) installer...")
            case .done: print("  Done.")
            }
        }
    )
    print("Installed. Bottle: \(bottle.prefixPath)")
    print("Run \"respilot add-profile\" with --kind crossover --bottle-name \(bottleName) once you know the installed launcher's path inside the bottle, to finish creating a profile.")
}

func printHelp() {
    print("""
    respilot — display-resolution / HiDPI auto-switcher for Wine gaming on macOS
    (works alongside CrossOver or Sikarugir/Wineskin-style wrappers; touches neither's binary)

    Usage:
      respilot list-displays
      respilot list-bottles
      respilot list-profiles
      respilot show-profile   --name <name>
      respilot add-profile    --name <name> --kind crossover|wineskin
                               (--bottle-name <name> | --wrapper-name <name> | --prefix <path> --wine-binary <path>)
                               (--launch-app <path> | --launch-exe <path>)
                               --retina-mode on|off [--dpi <logPixels>]
                               [--width <n> --height <n> [--hidpi]] [--no-auto-revert]
                               [--renderer gl|vulkan|gdi] [--esync] [--msync]
      respilot remove-profile --name <name>
      respilot apply          --name <name> [--dry-run]
      respilot restore
      respilot list-apps
      respilot install-app    --app steam|"epic games launcher"|"rockstar games launcher"
                               [--installer <path to a file you already downloaded>] [--bottle-name <name>] [--dry-run]
                               (creates a bottle, provisions common Wine dependencies via Winetricks,
                                then runs the installer — downloaded automatically from the vendor's own
                                site unless --installer overrides it; see "respilot list-apps" for what
                                each one needs and any known issues)

    Environment:
      RESPILOT_HOME   overrides where profiles.json / pending-restore.json live
                       (default: ~/Library/Application Support/ResPilot)
    """)
}
