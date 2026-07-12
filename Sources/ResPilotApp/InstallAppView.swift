import AppKit
import ResPilotCore
import SwiftUI
import UniformTypeIdentifiers

/// Main-window content for the "Install App" sidebar section: a small,
/// honest catalog (see `AppCatalog`'s own doc comment) — no vendor logos,
/// no fabricated compatibility ratings. "Install" is genuinely one click
/// when a verified direct download link exists for that app: ResPilot
/// downloads the vendor's own installer itself, creates a bottle,
/// provisions Winetricks verbs, and runs it — no browser detour. A manual
/// "already downloaded a file" path stays available as a fallback, since
/// those links are an unofficial discovery vendors could change.
struct InstallAppView: View {
    @ObservedObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !model.isWineEngineInstalled && !model.isInstallingApp {
                    Label(
                        "First install downloads ResPilot's own free Wine engine (WineHQ, ~190MB, one-time) — no CrossOver required.",
                        systemImage: "arrow.down.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                if model.isInstallingApp {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.installStatusText).font(.callout)
                    }
                }
                if let error = model.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(AppCatalog.popular) { app in
                        AppCatalogCard(
                            app: app,
                            isBusy: model.isInstallingApp,
                            onInstall: { bottleName, installerPath in
                                model.installApp(app, bottleName: bottleName, installerPath: installerPath)
                            }
                        )
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Install App").font(.system(size: 28, weight: .bold))
            Text("Install downloads the vendor's own installer automatically, creates a bottle, and provisions common Wine dependencies via Winetricks — no browser needed. ResPilot never runs a binary from anywhere but that vendor's own domain.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AppCatalogCard: View {
    let app: CatalogApp
    let isBusy: Bool
    /// `installerPath == nil` means "download it yourself" (auto flow);
    /// non-nil means the user picked an already-downloaded file.
    let onInstall: (_ bottleName: String, _ installerPath: String?) -> Void

    @State private var bottleName: String

    init(app: CatalogApp, isBusy: Bool, onInstall: @escaping (String, String?) -> Void) {
        self.app = app
        self.isBusy = isBusy
        self.onInstall = onInstall
        _bottleName = State(initialValue: app.name.replacingOccurrences(of: " ", with: ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.headline)
                    Text(app.vendor).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 6) {
                ForEach(app.recommendedVerbs, id: \.self) { verb in
                    Text(verb)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.blue.opacity(0.18)))
                        .foregroundStyle(.blue)
                }
                Spacer(minLength: 0)
            }

            if let issue = app.knownIssue {
                Text(issue)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Bottle name", text: $bottleName)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            HStack {
                Button {
                    onInstall(bottleName, nil)
                } label: {
                    Label("Install", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || bottleName.isEmpty || app.directDownloadURL == nil)

                Spacer()

                Menu {
                    Button("Use a file I already downloaded…") { pickInstallerAndInstall() }
                        .disabled(isBusy || bottleName.isEmpty)
                    Button("Open download page") { NSWorkspace.shared.open(app.downloadPageURL) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }

            if app.directDownloadURL == nil {
                Text("No verified direct link for this app — use \"Use a file I already downloaded…\".")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private func pickInstallerAndInstall() {
        let panel = NSOpenPanel()
        panel.title = "Choose the \(app.name) installer you downloaded"
        panel.allowedContentTypes = ["exe", "msi"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onInstall(bottleName, url.path)
    }
}
