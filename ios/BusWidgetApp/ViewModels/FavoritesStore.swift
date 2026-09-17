import Foundation

@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var items: [SavedStop] = []
    @Published private(set) var loadingNames: Set<UUID> = []
    @Published var error: String?
    private let store: AppGroupStore?
    private let client: APIClient?

    init(store: AppGroupStore? = AppGroupStore(), client: APIClient? = try? APIClient()) {
        self.store = store
        self.client = client
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
        _ = persist(items.filter { $0.id != favorite.id })
    }

    func updateRouteNames(_ routes: [RouteSummary], for original: SavedStop) {
        // An in-flight response must not restore a deleted favorite or overwrite an edit.
        guard var current = items.first(where: { $0.id == original.id }),
              current.configuration == original.configuration else { return }
        let available = routes + current.displayRoutes
        current.routes = current.configuration.routeIds.compactMap { id in
            available.first { $0.routeId == id && !$0.routeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if current.routes != original.routes { _ = save(current) }
    }

    func hydrateLegacyNames() async {
        guard let client else { return }
        for favorite in items where favorite.hasMissingRouteNames {
            guard !Task.isCancelled else { return }
            guard loadingNames.insert(favorite.id).inserted else { continue }
            defer { loadingNames.remove(favorite.id) }
            if let detail = try? await client.stationDetail(stationId: favorite.configuration.stationId), !Task.isCancelled {
                updateRouteNames(detail.routes, for: favorite)
            }
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
