import SwiftUI
import WidgetKit

struct RootView: View {
    @EnvironmentObject private var waiting: BusWaitingManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var configuration = AppGroupStore()?.loadConfiguration()
    @State private var isEditing = AppGroupStore()?.loadConfiguration() == nil

    var body: some View {
        Group {
            if let configuration, !isEditing {
                SavedConfigurationView(configuration: configuration) {
                    isEditing = true
                }
            } else {
                StationSearchView { savedConfiguration in
                    configuration = savedConfiguration
                    isEditing = false
                }
            }
        }
        .tint(AppTheme.primary)
        .task { await waiting.restore() }
        .onOpenURL { url in
            if url.scheme == "buswidget", url.host == "waiting" {
                isEditing = configuration == nil
                Task { await waiting.restore() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, configuration != nil {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind)
                Task { await waiting.restore() }
            }
        }
    }
}
