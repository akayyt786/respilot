import Foundation

/// Stages of `AppInstaller.install`, reported via `onStep` so a UI can show
/// real progress instead of a spinner over what can be a multi-minute
/// operation.
public enum InstallStep: Equatable, Sendable {
    case creatingBottle
    case installingDependencies(verb: String)
    case runningInstaller
    case done
}

/// Orchestrates the real, non-proprietary pieces of a "one-click install":
/// create a fresh bottle (`BottleProvisioner`), provision common runtime
/// dependencies (`Winetricks`), then run an installer the user already
/// downloaded from the vendor's own site through it. Deliberately stops
/// there — it does not try to guess where the resulting app installed to
/// (install paths vary by vendor and version); the caller points
/// `ProfileEditorView`'s existing bottle/launch-target picker at the new
/// bottle to finish creating a profile.
///
/// Supports provisioning either `.crossOver` or `.respilotManaged`
/// bottles: both need only a Wine binary path to initialize with
/// (`BottleProvisioner` handles the kind-specific creation mechanics —
/// `cxbottle` vs `wineboot --init`). A Wineskin/Sikarugir bottle *is* its
/// wrapper `.app`, built by that app's own "New Wrapper" tooling —
/// ResPilot doesn't attempt to replicate that, so `.wineskinStyle` stays
/// unsupported here (see `BottleProvisioner.createPrefix`).
public actor AppInstaller {
    private let provisioner: BottleProvisioner
    private let winetricks: Winetricks
    private let wineRegistry: WineRegistry
    private let processRunner: ProcessRunning
    private let fileManager: FileManager

    public init(
        provisioner: BottleProvisioner = BottleProvisioner(),
        winetricks: Winetricks = Winetricks(),
        processRunner: ProcessRunning = FoundationProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.provisioner = provisioner
        self.winetricks = winetricks
        self.wineRegistry = WineRegistry(processRunner: processRunner)
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    /// Creates `bottleName` under `bottleDirectory` using `wineBinary`,
    /// runs `verbs` through Winetricks, then runs `installerPath` (a file
    /// the caller already downloaded) inside that bottle via `wine`.
    /// Returns the resulting bottle so the caller can hand it straight to
    /// `ProfileEditorView`.
    @discardableResult
    public func install(
        bottleName: String,
        bottleDirectory: URL,
        wineBinary: String,
        kind: BottleKind = .crossOver,
        verbs: [String],
        installerPath: String,
        onStep: (@Sendable (InstallStep) -> Void)? = nil
    ) async throws -> WineBottleTarget {
        let prefixPath = bottleDirectory.appendingPathComponent(bottleName, isDirectory: true).path
        let bottle = WineBottleTarget(
            kind: kind,
            prefixPath: prefixPath,
            wineBinaryPath: wineBinary,
            crossOverBottleName: kind == .crossOver ? bottleName : nil
        )

        onStep?(.creatingBottle)
        try provisioner.createPrefix(bottle)

        for verb in verbs {
            onStep?(.installingDependencies(verb: verb))
            try winetricks.run(verbs: [verb], in: bottle)
        }

        onStep?(.runningInstaller)
        try runInstaller(at: installerPath, in: bottle)

        onStep?(.done)
        return bottle
    }

    /// Bounded the same way `Winetricks.run` is — a downloaded vendor
    /// installer can just as easily stall (a slow embedded download, a
    /// silent-install flag the vendor doesn't actually honor and a window
    /// that will never appear) as a Winetricks verb can.
    private func runInstaller(at installerPath: String, in bottle: WineBottleTarget, timeout: TimeInterval? = 1800) throws {
        guard fileManager.fileExists(atPath: installerPath) else {
            throw AppInstallerError.installerNotFound(installerPath)
        }
        let invocation = try wineRegistry.invocation(for: bottle, subcommand: [installerPath])
        let result = try processRunner.run(
            executable: invocation.executable,
            arguments: invocation.arguments,
            environment: invocation.environment,
            timeout: timeout
        )
        guard result.succeeded else {
            throw AppInstallerError.installerFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }
}

public enum AppInstallerError: Error, LocalizedError, Equatable {
    case installerNotFound(String)
    case installerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .installerNotFound(let path):
            return "Installer file not found at \(path)."
        case .installerFailed(let reason):
            return "Running the installer failed: \(reason)"
        }
    }
}
