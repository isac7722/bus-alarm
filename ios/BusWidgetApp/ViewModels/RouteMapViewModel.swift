import Foundation
import CoreLocation

@MainActor
final class BusSearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var searchStops = false
    @Published private(set) var routes: [CatalogRoute] = []
    @Published private(set) var stations: [StationSummary] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var warning: String?
    @Published private(set) var recent: [String] = UserDefaults.standard.stringArray(forKey: "routeSearch.recent") ?? []
    private var task: Task<Void, Never>?
    private var generation = 0
    private let client: APIClient?

    init(client: APIClient? = try? APIClient()) { self.client = client }

    func search() {
        task?.cancel()
        generation += 1
        let current = generation
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let stops = searchStops
        routes = []; stations = []; error = nil; warning = nil
        loading = !text.isEmpty
        guard !text.isEmpty else { return }
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let client = self?.client else { throw APIClientError.invalidBaseURL }
                if stops {
                    let stations = try await client.searchStations(query: text)
                    guard !Task.isCancelled, self?.generation == current else { return }
                    self?.stations = stations
                } else {
                    let response = try await client.searchRoutes(query: text)
                    guard !Task.isCancelled, self?.generation == current else { return }
                    self?.routes = response.routes
                    if response.providers.contains(where: { !$0.available }) {
                        self?.warning = "일부 지역의 노선을 불러오지 못했습니다. 다시 검색해 주세요."
                    }
                }
                self?.loading = false
            } catch {
                guard !Task.isCancelled, self?.generation == current else { return }
                self?.error = error.localizedDescription
                self?.loading = false
            }
        }
    }

    func remember() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        recent = Array(([value] + recent.filter { $0 != value }).prefix(5))
        UserDefaults.standard.set(recent, forKey: "routeSearch.recent")
    }
}

@MainActor
final class RouteMapViewModel: ObservableObject {
    @Published private(set) var detail: CatalogDetail?
    @Published private(set) var geometry: RouteGeometry?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var directionId = ""
    @Published var selected: RouteStopOccurrence?
    let route: CatalogRoute
    private let client: APIClient?

    init(route: CatalogRoute, client: APIClient? = try? APIClient()) { self.route = route; self.client = client }
    var stops: [RouteStopOccurrence] {
        guard let detail else { return [] }
        return directionId.isEmpty ? detail.stops : detail.stops.filter { $0.directionId == directionId }
    }
    func changeDirection(_ value: String) { directionId = value; selected = nil }
    func select(_ stop: RouteStopOccurrence) {
        guard !directionId.isEmpty, stop.directionId == directionId, stop.selectable else { return }
        selected = stop
    }
    func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            guard let client else { throw APIClientError.invalidBaseURL }
            let value = try await client.routeDetail(ref: route.routeRef)
            if detail?.revision != value.revision { directionId = ""; selected = nil }
            detail = value
            geometry = try? await client.routeGeometry(ref: route.routeRef)
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
final class BoardingReviewViewModel: ObservableObject {
    @Published private(set) var options: [RouteStopOccurrence] = []
    @Published private(set) var selections: [BoardingSelection]
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var warning: String?
    let station: MapStation
    private let client: APIClient?
    private let store: AppGroupStore?

    init(station: MapStation, initial: BoardingSelection?, client: APIClient? = try? APIClient(), store: AppGroupStore? = AppGroupStore()) {
        self.station = station; self.client = client; self.store = store
        selections = initial.map { [$0] } ?? []
    }
    var canSave: Bool { !selections.isEmpty && !saving && !loading }
    func toggle(_ stop: RouteStopOccurrence) {
        guard stop.selectable, !saving else { return }
        if selections.contains(where: { $0.id == stop.id }) {
            selections.removeAll { $0.id == stop.id }
        } else if let index = selections.firstIndex(where: { $0.routeRef == stop.routeRef }) {
            selections[index] = stop.selection
        } else if selections.count < 4 { selections.append(stop.selection) }
    }
    func disabled(_ stop: RouteStopOccurrence) -> Bool {
        !stop.selectable || saving || (selections.count >= 4 && !selections.contains { $0.routeRef == stop.routeRef })
    }
    func load() async {
        loading = true; error = nil; warning = nil
        defer { loading = false }
        do {
            guard let client else { throw APIClientError.invalidBaseURL }
            let response = try await client.boardingOptions(stationRef: station.stationRef, routeRef: selections.first?.routeRef)
            options = response.options
            warning = response.complete ? nil : response.warnings.joined(separator: "\n")
        } catch { self.error = error.localizedDescription }
    }
    func save() async -> WidgetConfigurationData? {
        guard canSave else { return nil }
        saving = true; error = nil
        defer { saving = false }
        do {
            guard let client else { throw APIClientError.invalidBaseURL }
            let valid = try await client.validateSelection(stationRef: station.stationRef, selections: selections)
            guard let store else { throw CocoaError(.fileWriteUnknown) }
            let configuration = WidgetConfigurationData(validated: valid)
            try store.saveConfiguration(configuration)
            return configuration
        } catch { self.error = error.localizedDescription; return nil }
    }
}

@MainActor
final class StationLocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var message: String?
    private let manager = CLLocationManager()
    private var requested = false
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters }
    func request() {
        requested = true
        message = nil
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        default: message = "위치 없이도 지도와 목록에서 정류장을 고를 수 있어요."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard requested else { return }
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        coordinate = location.coordinate
        if location.horizontalAccuracy > 500 { message = "현재 위치가 정확하지 않을 수 있어요. 정류장 번호와 방향을 확인해 주세요." }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        message = "위치를 찾지 못했어요. 지도와 목록에서 정류장을 고를 수 있어요."
    }
}
