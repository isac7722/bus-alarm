import SwiftUI

struct RootView: View {
    @EnvironmentObject private var waiting: BusWaitingManager
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var favorites: FavoritesStore
    @State private var addingFavorite = false
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
            FavoritesView { addingFavorite = true; tab = 1 }
                .tabItem { Label("즐겨찾기", systemImage: "bookmark") }.tag(0)
            Group {
                if available == true { StationFinderView(intent: addingFavorite ? .addFavorite : .explore) }
                else if available == nil && discoveryError == nil {
                    ProgressView("정류장 지도를 준비하는 중…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(AppTheme.background)
                }
                else {
                    ScrollView {
                        VStack(spacing: 8) {
                            TransitEmptyState(title: "정류장 찾기를 준비하고 있어요", symbol: "map",
                                message: discoveryError ?? "잠시 후 다시 시도해 주세요. 저장한 즐겨찾기는 계속 이용할 수 있습니다.")
                            Button("다시 시도") { Task { await checkDiscovery() } }
                                .buttonStyle(TransitButtonStyle(prominent: false))
                        }.padding(.vertical, 24)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AppTheme.background)
                }
            }.tabItem { Label("정류장 찾기", systemImage: "bus") }.tag(1)
        }
        .onChange(of: favorites.saveNotice?.id) { _, notice in
            if notice != nil { tab = 0; addingFavorite = false }
        }
        .onChange(of: tab) { _, value in if value == 0 { addingFavorite = false } }
        .task(id: favorites.deletedFavorite?.id) {
            guard let deleted = favorites.deletedFavorite, !voiceOver else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            favorites.expireDeletion(deleted.id)
        }
        .task(id: favorites.saveNotice?.id) {
            guard let notice = favorites.saveNotice else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            if favorites.saveNotice?.id == notice.id { favorites.saveNotice = nil }
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
                }.foregroundStyle(AppTheme.action).background(AppTheme.selection)
                 .accessibilityIdentifier("active-wait-banner")
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
            }
        }
    }
    private func checkDiscovery() async {
        do { discoveryError = nil; available = try await APIClient().routeMapAvailable() }
        catch { discoveryError = error.localizedDescription }
    }
}
