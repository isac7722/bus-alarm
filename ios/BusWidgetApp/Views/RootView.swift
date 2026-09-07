import SwiftUI
import WidgetKit

struct RootView: View {
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, configuration != nil {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind)
            }
        }
    }
}
