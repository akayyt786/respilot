import ResPilotCore
import SwiftUI

/// Main-window content for the "Bottles" sidebar section: read-only view of
/// every Wine bottle `BottleLocator` found on disk, across both supported
/// lineages. Purely informational — creating profiles from a discovered
/// bottle still goes through `ProfileEditorView`'s own picker.
struct BottlesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                section(
                    title: "CrossOver",
                    bottles: model.discoveredCrossOverBottles,
                    emptyText: "No CrossOver bottles found. Install CrossOver and create a bottle to see it here."
                )
                section(
                    title: "Sikarugir / Wineskin / Kegworks",
                    bottles: model.discoveredWineskinBottles,
                    emptyText: "No wrapper apps found under /Applications or ~/Applications."
                )
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bottles").font(.system(size: 28, weight: .bold))
                Text("Wine prefixes ResPilot found on this Mac — pick one when creating a new profile.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.rediscoverBottles()
            } label: {
                Label("Rediscover", systemImage: "arrow.clockwise")
            }
        }
    }

    private func section(title: String, bottles: [DiscoveredBottle], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if bottles.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(bottles.enumerated()), id: \.element.id) { index, bottle in
                        BottleRow(bottle: bottle)
                        if index < bottles.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(.thinMaterial))
            }
        }
    }
}

private struct BottleRow: View {
    let bottle: DiscoveredBottle

    var body: some View {
        HStack {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(bottle.name).font(.body)
                Text(bottle.target.prefixPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }
}
