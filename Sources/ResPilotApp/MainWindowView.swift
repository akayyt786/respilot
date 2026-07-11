import ResPilotCore
import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case profiles = "Profiles"
    case bottles = "Bottles"
    case installApp = "Install App"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .profiles: return "gamecontroller"
        case .bottles: return "shippingbox"
        case .installApp: return "arrow.down.app"
        }
    }
}

/// The app's primary window: a sidebar (branding + section nav) and a
/// detail pane driven by `AppModel`'s existing published state — no data
/// or business logic lives here, same rule `MenuBarContentView` and
/// `ProfileEditorView` already follow.
struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SidebarSection.ID? = SidebarSection.profiles.id

    private var selectedSection: SidebarSection {
        SidebarSection.allCases.first { $0.id == selection } ?? .profiles
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section.id)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .top) {
                ResPilotWordmark()
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 10)
            }
        } detail: {
            switch selectedSection {
            case .profiles:
                ProfilesView(model: model)
            case .bottles:
                BottlesView(model: model)
            case .installApp:
                InstallAppView(model: model)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .preferredColorScheme(.dark)
        .onAppear { model.refreshAll() }
    }
}
