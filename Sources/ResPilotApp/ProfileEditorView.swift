import AppKit
import ResPilotCore
import SwiftUI

struct ProfileEditorView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var kind: BottleKind = .respilotManaged
    @State private var selectedBottleID: String?
    @State private var useManualBottle = false
    @State private var manualBottleIdentifier = ""
    @State private var manualWineBinary = ""

    @State private var launchIsAppBundle = true
    @State private var launchPath = ""

    @State private var changeDisplay = false
    @State private var availableModes: [DisplayModeInfo] = []
    @State private var selectedMode: DisplayModeInfo?

    @State private var retinaMode = true
    @State private var useCustomDPI = false
    @State private var dpi: Int = DPIPreset.scale150

    @State private var autoRevert = true
    @State private var renderer: WineD3DRenderer?
    @State private var esync = false
    @State private var msync = false
    @State private var validationError: String?

    private var discoveredBottles: [DiscoveredBottle] {
        switch kind {
        case .crossOver: return model.discoveredCrossOverBottles
        case .wineskinStyle: return model.discoveredWineskinBottles
        case .respilotManaged: return model.discoveredRespilotManagedBottles
        }
    }

    private var manualIdentifierLabel: String {
        switch kind {
        case .crossOver: return "Bottle name (as CrossOver knows it)"
        case .wineskinStyle: return "Prefix path"
        case .respilotManaged: return "Bottle name"
        }
    }

    private var emptyBottleHint: String {
        switch kind {
        case .crossOver: return "No CrossOver bottles auto-detected. Enter the bottle name manually."
        case .wineskinStyle: return "No wrapper apps auto-detected. Enter the path manually."
        case .respilotManaged: return "No ResPilot-managed bottles yet — enter a name to create one on first launch, or use Install App for a guided setup."
        }
    }

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: $name)
            }

            Section("Bottle") {
                Picker("Type", selection: $kind) {
                    Text("ResPilot (free, built-in)").tag(BottleKind.respilotManaged)
                    Text("CrossOver").tag(BottleKind.crossOver)
                    Text("Sikarugir / Wineskin").tag(BottleKind.wineskinStyle)
                }
                .pickerStyle(.segmented)
                .onChange(of: kind) { _ in selectedBottleID = nil }

                if !discoveredBottles.isEmpty {
                    Picker("Bottle", selection: $selectedBottleID) {
                        Text("Choose…").tag(String?.none)
                        ForEach(discoveredBottles) { bottle in
                            Text(bottle.name).tag(String?.some(bottle.id))
                        }
                    }
                    Toggle("Enter it manually instead", isOn: $useManualBottle)
                } else {
                    Text(emptyBottleHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if useManualBottle || discoveredBottles.isEmpty {
                    TextField(manualIdentifierLabel, text: $manualBottleIdentifier)
                    if kind != .respilotManaged {
                        TextField("Wine binary path", text: $manualWineBinary)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            Section("Launch") {
                Picker("Target type", selection: $launchIsAppBundle) {
                    Text(".app bundle").tag(true)
                    Text("Windows .exe").tag(false)
                }
                .pickerStyle(.segmented)
                HStack {
                    TextField(launchIsAppBundle ? "Path to .app" : "Path to .exe inside the bottle", text: $launchPath)
                    Button("Choose…") { pickLaunchTarget() }
                }
            }

            Section("Display") {
                Toggle("Change macOS display resolution while running", isOn: $changeDisplay)
                if changeDisplay {
                    Picker("Resolution", selection: $selectedMode) {
                        Text("Choose…").tag(DisplayModeInfo?.none)
                        ForEach(availableModes, id: \.self) { mode in
                            Text(mode.description).tag(DisplayModeInfo?.some(mode))
                        }
                    }
                }
                Toggle("Wine RetinaMode (sharp HiDPI rendering)", isOn: $retinaMode)
                Toggle("Custom Wine DPI scaling", isOn: $useCustomDPI)
                if useCustomDPI {
                    Picker("Scale", selection: $dpi) {
                        Text("100%").tag(DPIPreset.scale100)
                        Text("125%").tag(DPIPreset.scale125)
                        Text("150%").tag(DPIPreset.scale150)
                        Text("200%").tag(DPIPreset.scale200)
                    }
                }
                Toggle("Restore previous display automatically when it quits", isOn: $autoRevert)
            }

            Section("Compatibility") {
                Picker("Wine renderer", selection: $renderer) {
                    Text("Unset (Wine default)").tag(WineD3DRenderer?.none)
                    ForEach(WineD3DRenderer.allCases, id: \.self) { option in
                        Text(option.displayName).tag(WineD3DRenderer?.some(option))
                    }
                }
                Toggle("ESync", isOn: $esync)
                Toggle("MSync", isOn: $msync)
                Text("Toggles the upstream Wine renderer/sync primitives only — does not install or switch DXVK, DXMT, or D3DMetal, which require translation-layer binaries ResPilot doesn't manage.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let validationError {
                Text(validationError).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 560)
        .preferredColorScheme(.dark)
        .onAppear(perform: loadAvailableModes)
    }

    private func loadAvailableModes() {
        let provider = CoreGraphicsDisplayModeProvider()
        availableModes = (try? provider.availableModes(display: provider.mainDisplayID))?
            .sorted { $0.pointWidth == $1.pointWidth ? $0.pointHeight < $1.pointHeight : $0.pointWidth < $1.pointWidth } ?? []
    }

    private func pickLaunchTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        if launchIsAppBundle {
            panel.allowedContentTypes = [.application]
        }
        if panel.runModal() == .OK, let url = panel.url {
            launchPath = url.path
        }
    }

    private func resolvedBottle() -> WineBottleTarget? {
        if useManualBottle || discoveredBottles.isEmpty {
            guard !manualBottleIdentifier.isEmpty else { return nil }
            switch kind {
            case .crossOver:
                guard !manualWineBinary.isEmpty else { return nil }
                // The CrossOver default bottle directory is documented by
                // CodeWeavers (~/Library/Application Support/CrossOver/Bottles),
                // so the manual field only needs the bottle's name.
                let prefixPath = BottleLocator.defaultCrossOverBottleDirectory()
                    .appendingPathComponent(manualBottleIdentifier).path
                return WineBottleTarget(
                    kind: .crossOver,
                    prefixPath: prefixPath,
                    wineBinaryPath: manualWineBinary,
                    crossOverBottleName: manualBottleIdentifier
                )
            case .wineskinStyle:
                guard !manualWineBinary.isEmpty else { return nil }
                return WineBottleTarget(kind: .wineskinStyle, prefixPath: manualBottleIdentifier, wineBinaryPath: manualWineBinary)
            case .respilotManaged:
                // No manual wine-binary field for this kind — there's only
                // ever one engine, ResPilot's own (`WineEngineManager`), so
                // the field is never shown and there's nothing to guard on.
                let prefixPath = BottleLocator.defaultRespilotBottleDirectory()
                    .appendingPathComponent(manualBottleIdentifier).path
                return WineBottleTarget(kind: .respilotManaged, prefixPath: prefixPath, wineBinaryPath: model.wineEngineBinaryPath)
            }
        }
        return discoveredBottles.first(where: { $0.id == selectedBottleID })?.target
    }

    private func save() {
        guard !name.isEmpty else {
            validationError = "Name is required."
            return
        }
        guard let bottle = resolvedBottle() else {
            validationError = "Choose a bottle, or enter its path manually."
            return
        }
        guard !launchPath.isEmpty else {
            validationError = "Choose what to launch."
            return
        }
        let launchTarget: LaunchTarget = launchIsAppBundle ? .appBundle(path: launchPath) : .windowsExecutable(path: launchPath)

        let display: DisplayTarget
        if changeDisplay {
            guard let mode = selectedMode else {
                validationError = "Choose a resolution, or turn off \"Change macOS display resolution.\""
                return
            }
            display = DisplayTarget(pointWidth: mode.pointWidth, pointHeight: mode.pointHeight, hiDPI: mode.isHiDPI)
        } else {
            display = .leaveUnchanged
        }

        let profile = GameProfile(
            name: name,
            bottle: bottle,
            launchTarget: launchTarget,
            display: display,
            wineRetinaMode: retinaMode,
            wineLogPixels: useCustomDPI ? dpi : nil,
            autoRevertOnQuit: autoRevert,
            compatibility: WineCompatibilitySettings(renderer: renderer, esync: esync, msync: msync)
        )
        model.addProfile(profile)
        isPresented = false
    }
}
