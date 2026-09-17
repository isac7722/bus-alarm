import Foundation
import MapKit

@MainActor
final class StationFinderViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var stations: [MapStation] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var truncated = false
    @Published var selected: MapStation?
    @Published private(set) var resolving = false
    var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.978),
                                     span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025))
    private let api: APIClient?
    private var task: Task<Void, Never>?
    private var generation = 0
    init(api: APIClient? = try? APIClient()) { self.api = api }

    func search() {
        task?.cancel()
        generation += 1
        let current = generation
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let area = region
        loading = true; error = nil; truncated = false
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let api = self?.api else { throw APIClientError.invalidBaseURL }
                let values: [MapStation]
                var capped = false
                if text.isEmpty {
                    let result = try await api.nearbyStations(
                        south: area.center.latitude - area.span.latitudeDelta / 2, west: area.center.longitude - area.span.longitudeDelta / 2,
                        north: area.center.latitude + area.span.latitudeDelta / 2, east: area.center.longitude + area.span.longitudeDelta / 2)
                    values = result.stations; capped = result.truncated
                } else {
                    values = try await api.searchStations(query: text).map {
                        MapStation(stationRef: $0.stationId, name: $0.name, displayNumber: $0.arsId, latitude: $0.latitude, longitude: $0.longitude)
                    }
                }
                guard !Task.isCancelled, self?.generation == current else { return }
                self?.stations = values; self?.truncated = capped; self?.loading = false
            } catch {
                guard !Task.isCancelled, self?.generation == current else { return }
                self?.error = error.localizedDescription; self?.loading = false
                self?.stations = []
            }
        }
    }
    func select(_ station: MapStation) async {
        guard !resolving else { return }
        resolving = true
        defer { resolving = false }
        do {
            guard let api else { throw APIClientError.invalidBaseURL }
            selected = station.stationRef.contains(":") ? station : try await api.resolveStation(id: station.stationRef)
        } catch { self.error = error.localizedDescription }
    }
    func cancel() { task?.cancel(); loading = false }
}
