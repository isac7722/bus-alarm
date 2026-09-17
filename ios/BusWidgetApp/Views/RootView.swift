import SwiftUI
import WidgetKit

struct RootView: View {
    @EnvironmentObject private var waiting: BusWaitingManager
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var favorites: FavoritesStore
    @State private var tab: Int
    @State private var available: Bool?
    @State private var discoveryError: String?
    @State private var showWaiting = false

    init() {
        let store = FavoritesStore()
        _favorites = StateObject(wrappedValue: store)
        _tab = State(initialValue: store.items.isEmpty ? 1 : 0)
    }
    var body: some View {
        TabView(selection: $tab) {
            FavoritesView { tab = 1 }
                .tabItem { Label("즐겨찾기", systemImage: "star") }.tag(0)
            Group {
                if available == true { StationFinderView() }
                else if available == nil && discoveryError == nil { ProgressView("정류장 지도를 준비하는 중…") }
                else {
                    ContentUnavailableView {
                        Label("정류장 찾기를 준비하고 있어요", systemImage: "map")
                    } description: {
                        Text(discoveryError ?? "잠시 후 다시 시도해 주세요. 저장한 즐겨찾기는 계속 이용할 수 있습니다.")
                    } actions: {
                        Button("다시 시도") { Task { await checkDiscovery() } }
                    }
                }
            }.tabItem { Label("정류장 찾기", systemImage: "map") }.tag(1)
        }
        .environmentObject(favorites)
        .tint(AppTheme.primary)
        #if DEBUG
        .preferredColorScheme(ProcessInfo.processInfo.environment["BUS_WIDGET_TEST_SUITE"] != nil &&
                              ProcessInfo.processInfo.environment["BUS_WIDGET_TEST_COLOR_SCHEME"] == "dark" ? .dark : nil)
        #endif
        .safeAreaInset(edge: .top, spacing: 0) {
            if let activity = waiting.activity {
                Button { showWaiting = true } label: {
                    HStack {
                        Image(systemName: "bus.fill")
                        Text("\(activity.attributes.stationName) · \(activity.attributes.selectedRoutes.count)개 버스 대기 중").lineLimit(2)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                    }.font(.subheadline).padding(12).frame(maxWidth: .infinity, minHeight: 44)
                }.background(.regularMaterial).accessibilityIdentifier("active-wait-banner")
            }
        }
        .sheet(isPresented: $showWaiting) { NavigationStack { ActiveCommuteView() } }
        .task { await checkDiscovery() }
        .task { await waiting.restore() }
        .onOpenURL { url in
            if url.scheme == "buswidget", url.host == "waiting" {
                Task { await waiting.restore(); showWaiting = waiting.activity != nil }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await waiting.restore()
                    if available != true { await checkDiscovery() }
                }
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind)
            }
        }
    }
    private func checkDiscovery() async {
        do { discoveryError = nil; available = try await APIClient().routeMapAvailable() }
        catch { discoveryError = error.localizedDescription }
    }
}
