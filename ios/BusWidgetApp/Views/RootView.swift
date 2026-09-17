import SwiftUI
import WidgetKit

struct RootView: View {
    @EnvironmentObject private var waiting: BusWaitingManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var configuration = AppGroupStore()?.loadConfiguration()
    @State private var routeMapAvailable = false
    @State private var capabilityChecked = false
    @State private var isEditing = AppGroupStore()?.loadConfiguration() == nil

    var body: some View {
        Group {
            if let configuration, !isEditing {
                SavedConfigurationView(configuration: configuration) {
                    isEditing = true
                }
            } else if !capabilityChecked {
                ProgressView("설정 화면을 준비하는 중…")
            } else if routeMapAvailable {
                BusSearchView(previous: configuration, onSave: { saved in
                    configuration = saved
                    isEditing = false
                }, onCancel: { isEditing = false })
            } else {
                StationSearchView { savedConfiguration in
                    configuration = savedConfiguration
                    isEditing = false
                }
            }
        }
        #if DEBUG
        .preferredColorScheme(ProcessInfo.processInfo.environment["BUS_WIDGET_TEST_SUITE"] != nil &&
                              ProcessInfo.processInfo.environment["BUS_WIDGET_TEST_COLOR_SCHEME"] == "dark" ? .dark : nil)
        #endif
        .tint(AppTheme.primary)
        .task {
            await waiting.restore()
            routeMapAvailable = (try? await APIClient().routeMapAvailable()) ?? false
            capabilityChecked = true
        }
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
