import ResPilotCore
import SwiftUI

/// Main-window content for the "Profiles" sidebar section: every saved
/// `GameProfile`, launchable in place. Replaces the cramped menu-bar list
/// as the primary way to manage profiles; `MenuBarContentView` keeps a
/// trimmed-down version for quick access without opening the window.
struct ProfilesView: View {
    @ObservedObject var model: AppModel
    @State private var showingEditor = false

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 380), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let error = model.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if model.profiles.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.profiles) { profile in
                            ProfileCard(
                                profile: profile,
                                isLaunching: model.launchingProfileID == profile.id,
                                onLaunch: { model.launch(profile) },
                                onRemove: { model.removeProfile(profile) }
                            )
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingEditor) {
            ProfileEditorView(model: model, isPresented: $showingEditor)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Profiles").font(.system(size: 28, weight: .bold))
                Text(model.statusMessage).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.hasPendingRestore {
                Button {
                    model.restoreNow()
                } label: {
                    Label("Restore Display Now", systemImage: "arrow.uturn.backward")
                }
            }
            Button {
                showingEditor = true
            } label: {
                Label("New Profile", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No profiles yet").font(.headline)
            Text("Create a profile to launch a game with the right display resolution and Wine settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("New Profile") { showingEditor = true }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

private struct ProfileCard: View {
    let profile: GameProfile
    let isLaunching: Bool
    let onLaunch: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(profile.name).font(.headline).lineLimit(1)
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            FlowBadges {
                Badge(profile.bottle.kind.displayLabel)
                if !profile.display.isLeaveUnchanged {
                    Badge("\(profile.display.pointWidth)×\(profile.display.pointHeight)\(profile.display.hiDPI ? " HiDPI" : "")")
                }
                if profile.wineRetinaMode {
                    Badge("Retina")
                }
                if let renderer = profile.compatibility.renderer {
                    Badge(renderer.displayName, tint: .purple)
                }
                if profile.compatibility.esync {
                    Badge("ESync", tint: .blue)
                }
                if profile.compatibility.msync {
                    Badge("MSync", tint: .blue)
                }
            }

            Text(profile.launchTarget.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            HStack {
                Spacer()
                if isLaunching {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Launch", action: onLaunch)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(minHeight: 160, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

/// Simple left-aligned wrapping row of badges — `HStack` wrapped in a
/// `WrappingHStack`-less flow using a plain `HStack` is fine here since
/// badge counts per card are small (≤6); avoids pulling in a layout dep.
private struct FlowBadges<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 6) {
            content
            Spacer(minLength: 0)
        }
    }
}

private struct Badge: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}
