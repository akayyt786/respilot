import AppKit
import ResPilotCore
import SwiftUI

/// Main-window content for the "Epic Games" sidebar section: log in with
/// an Epic account, browse the owned library, install, and play — all
/// inside ResPilot, through its own free Wine engine. No Epic Games
/// Launcher, no CrossOver, no Heroic. See `LegendaryClient`'s own doc
/// comment for what actually drives login/install/launch under the hood.
/// Follows `InstallAppView`'s visual conventions (`ScrollView` + header +
/// status/error rows, `.thinMaterial` cards) so the two sidebar sections
/// feel like one app.
struct EpicGamesView: View {
    @ObservedObject var model: AppModel
    @State private var authCode: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if model.epicBusy || model.epicPlayingAppName != nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.epicStatusText.isEmpty ? "Working…" : model.epicStatusText).font(.callout)
                    }
                }
                if let error = model.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let account = model.epicAccount {
                    loggedInContent(account: account)
                } else {
                    loggedOutContent
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.refreshEpic() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Epic Games").font(.system(size: 28, weight: .bold))
            Text("Log in with your Epic account, install your games, and play them through ResPilot's built-in free Wine engine — no Epic Games Launcher, no CrossOver, no Heroic needed. Powered by the open-source Legendary client (GPLv3).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loggedOutContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click \"Open Epic Login Page\" and sign in.").font(.callout)
                Text("2. Copy the authorizationCode value from the JSON shown after login.").font(.callout)
                Text("3. Paste it here.").font(.callout)
            }

            Button {
                NSWorkspace.shared.open(LegendaryClient.epicLoginURL)
            } label: {
                Label("Open Epic Login Page", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)

            HStack {
                TextField("Paste authorizationCode", text: $authCode)
                    .textFieldStyle(.roundedBorder)
                Button("Log In") {
                    model.epicLogin(code: authCode)
                    authCode = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.epicBusy || authCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private func loggedInContent(account: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Signed in as \(account)").font(.headline)
                Spacer()
                Button("Refresh") { model.refreshEpic() }
                    .disabled(model.epicBusy)
                Button("Log Out") { model.epicLogout() }
                    .disabled(model.epicBusy)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1))

            if model.epicGames.isEmpty {
                Text("No games found in your Epic library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(model.epicGames) { game in
                        EpicGameRow(game: game, model: model)
                    }
                }
            }

            Text("Games install to ~/Games/Epic. First Play downloads ResPilot's free Wine engine (~190MB, one-time) and prepares a shared \"EpicGames\" bottle.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EpicGameRow: View {
    let game: EpicGame
    @ObservedObject var model: AppModel

    private var isBusy: Bool { model.epicBusy || model.epicPlayingAppName != nil }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title).font(.headline)
                Text(game.appName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            if game.installPath != nil {
                Button {
                    model.epicPlay(game)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)

                Menu {
                    Button("Uninstall", role: .destructive) { model.epicUninstall(game) }
                        .disabled(isBusy)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            } else {
                Button {
                    model.epicInstall(game)
                } label: {
                    Label("Install", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}
