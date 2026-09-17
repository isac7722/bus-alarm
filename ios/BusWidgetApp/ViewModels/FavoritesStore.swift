import Foundation
import WidgetKit

@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var items: [SavedStop] = []
    @Published private(set) var widgetConfiguration: WidgetConfigurationData?
    @Published var error: String?
    private let store: AppGroupStore?

    init(store: AppGroupStore? = AppGroupStore()) {
        self.store = store
        widgetConfiguration = store?.loadConfiguration()
        reload()
    }
    func reload() {
        do {
            guard let store else { throw CocoaError(.fileReadUnknown) }
            items = try store.loadFavorites()
            error = nil
        } catch { self.error = "즐겨찾기를 읽지 못했습니다. 다시 시도해 주세요." }
    }
    @discardableResult
    func save(_ favorite: SavedStop) -> Bool {
        guard error == nil else { return false }
        var updated = items
        if let index = updated.firstIndex(where: { $0.id == favorite.id }) {
            updated[index] = favorite
        } else if let index = updated.firstIndex(where: { $0.combinationID == favorite.combinationID }) {
            var refreshed = favorite
            refreshed.id = updated[index].id
            if refreshed.nickname.isEmpty { refreshed.nickname = updated[index].nickname }
            updated[index] = refreshed
        } else { updated.append(favorite) }
        return persist(updated)
    }
    func delete(_ favorite: SavedStop) {
        guard persist(items.filter { $0.id != favorite.id }) else { return }
        if isPinned(favorite) {
            store?.clearConfiguration()
            widgetConfiguration = nil
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind)
        }
    }
    func isPinned(_ favorite: SavedStop) -> Bool {
        guard let widgetConfiguration else { return false }
        return SavedStop(configuration: widgetConfiguration).combinationID == favorite.combinationID
    }
    func pin(_ favorite: SavedStop) {
        do {
            guard let store else { throw CocoaError(.fileWriteUnknown) }
            try store.saveConfiguration(favorite.configuration)
            widgetConfiguration = favorite.configuration
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind)
        } catch { self.error = "위젯에 표시할 정류장을 저장하지 못했습니다." }
    }
    func hydrateLegacyNames() async {
        guard let client = try? APIClient() else { return }
        for favorite in items where favorite.routes.isEmpty {
            guard let detail = try? await client.stationDetail(stationId: favorite.configuration.stationId),
                  var current = items.first(where: { $0.id == favorite.id }) else { continue }
            current.routes = detail.routes.filter { current.configuration.routeIds.contains($0.routeId) }
            if !current.routes.isEmpty { save(current) }
        }
    }
    private func persist(_ updated: [SavedStop]) -> Bool {
        do {
            guard let store else { throw CocoaError(.fileWriteUnknown) }
            try store.saveFavorites(updated)
            items = updated
            return true
        } catch { self.error = "즐겨찾기를 저장하지 못했습니다. 다시 시도해 주세요."; return false }
    }
}
