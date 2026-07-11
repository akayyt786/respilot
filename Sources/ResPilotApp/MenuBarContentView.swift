import AppKit
import ResPilotCore
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: AppModel
    @State private var showingEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ResPilotWordmark(markSize: 18, fontSize: 14, color: .primary)
                Spacer()
                if model.hasPendingRestore {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.orange)
                }
            }
            Text(model.statusMessage).font(.caption).foregroundStyle(.secondary)

            Divider()

            if model.profiles.isEmpty {
                Text("No profiles yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.profiles) { profile in
                            ProfileRow(
                                profile: profile,
                                isLaunching: model.launchingProfileID == profile.id,
                                onLaunch: { model.launch(profile) },
                                onRemove: { model.removeProfile(profile) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            Divider()

            Button {
                model.rediscoverBottles()
                showingEditor = true
            } label: {
                Label("Add Profile…", systemImage: "plus")
            }
            .buttonStyle(.plain)

            Button {
                model.restoreNow()
            } label: {
                Label("Restore Display Now", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .disabled(!model.hasPendingRestore)
            .keyboardShortcut("r")

            if let error = model.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            Divider()

            Button("Quit ResPilot") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 320)
        .sheet(isPresented: $showingEditor) {
            ProfileEditorView(model: model, isPresented: $showingEditor)
        }
        .preferredColorScheme(.dark)
        .onAppear { model.refreshAll() }
    }
}

private struct ProfileRow: View {
    let profile: GameProfile
    let isLaunching: Bool
    let onLaunch: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.body)
                Text(displayDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLaunching {
                ProgressView().controlSize(.small)
            } else {
                Button("Launch", action: onLaunch)
                    .controlSize(.small)
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var displayDescription: String {
        profile.display.isLeaveUnchanged
            ? "display unchanged"
            : "\(profile.display.pointWidth)x\(profile.display.pointHeight)\(profile.display.hiDPI ? " HiDPI" : "")"
    }
}
