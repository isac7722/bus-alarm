import Foundation
import WidgetKit

@MainActor
final class RouteSelectionViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var routes: [RouteSummary] = []
    @Published private(set) var selectedRouteIds: Set<String> = []
    @Published private(set) var state: State = .loading
    @Published private(set) var saveError: String?

    let station: StationSummary
    private let client: APIClient?
    private let store: AppGroupStore?

    init(
        station: StationSummary,
        client: APIClient? = try? APIClient(),
        store: AppGroupStore? = AppGroupStore()
    ) {
        self.station = station
        self.client = client
        self.store = store
    }

    var canSave: Bool { !selectedRouteIds.isEmpty }
    var selectionCountText: String { "\(selectedRouteIds.count)/4 선택" }

    func load() async {
        guard let client else {
            state = .failed(APIClientError.invalidBaseURL.localizedDescription)
            return
        }
        state = .loading
        do {
            let detail = try await client.stationDetail(stationId: station.stationId)
            routes = detail.routes
            let saved = store?.loadConfiguration()
            if saved?.stationId == station.stationId {
                selectedRouteIds = Set(saved?.routeIds ?? [])
            }
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func toggle(_ route: RouteSummary) {
        if selectedRouteIds.contains(route.routeId) {
            selectedRouteIds.remove(route.routeId)
        } else if selectedRouteIds.count < 4 {
            selectedRouteIds.insert(route.routeId)
        }
    }

    func isSelected(_ route: RouteSummary) -> Bool {
        selectedRouteIds.contains(route.routeId)
    }

    func isDisabled(_ route: RouteSummary) -> Bool {
        selectedRouteIds.count >= 4 && !isSelected(route)
    }

    func save() -> WidgetConfigurationData? {
        guard canSave else { return nil }
        let orderedIds = routes.map(\.routeId).filter(selectedRouteIds.contains)
        let configuration = WidgetConfigurationData(
            stationId: station.stationId,
            stationName: station.name,
            routeIds: orderedIds
        )
        guard let store else {
            saveError = "App Group 저장소를 열 수 없습니다. 서명 설정을 확인해 주세요."
            return nil
        }
        do {
            try store.saveConfiguration(configuration)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind)
            saveError = nil
            return configuration
        } catch {
            saveError = "설정을 저장하지 못했습니다. 다시 시도해 주세요."
            return nil
        }
    }

    func dismissSaveError() {
        saveError = nil
    }
}
