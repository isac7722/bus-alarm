import Foundation
import MapKit

@MainActor
final class StationFinderViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var stations: [MapStation] = []
    @Published private(set) var routes: [CatalogRoute] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var routeWarning: String?
    @Published private(set) var truncated = false
    @Published var selected: MapStation?
    @Published private(set) var resolving = false
    private(set) var hasSearched = false
    var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.978),
                                     span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025))
    private let api: APIClient?
    private var task: Task<Void, Never>?
    private var generation = 0
    init(api: APIClient? = try? APIClient()) { self.api = api }

    private enum SearchResult: Sendable {
        case stations([StationSummary])
        case routes(CatalogSearchResponse)
        case stationFailure(String)
        case routeFailure(String)
    }

    func search() {
        task?.cancel()
        generation += 1
        let current = generation
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let area = region
        hasSearched = true
        loading = true; error = nil; routeWarning = nil; truncated = false
        stations = []; routes = []
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let api = self?.api else { throw APIClientError.invalidBaseURL }
                if text.isEmpty {
                    let result = try await api.nearbyStations(
                        south: area.center.latitude - area.span.latitudeDelta / 2, west: area.center.longitude - area.span.longitudeDelta / 2,
                        north: area.center.latitude + area.span.latitudeDelta / 2, east: area.center.longitude + area.span.longitudeDelta / 2)
                    guard !Task.isCancelled, self?.generation == current else { return }
                    self?.stations = result.stations; self?.truncated = result.truncated
                } else {
                    // Deliver either source as soon as it finishes; one outage must not hide the other.
                    await withTaskGroup(of: SearchResult.self) { group in
                        group.addTask {
                            do { return .stations(try await api.searchStations(query: text)) }
                            catch { return .stationFailure(error.localizedDescription) }
                        }
                        group.addTask {
                            do { return .routes(try await api.searchRoutes(query: text)) }
                            catch { return .routeFailure(error.localizedDescription) }
                        }
                        for await result in group {
                            guard !Task.isCancelled, self?.generation == current else { continue }
                            switch result {
                            case .stations(let values):
                                self?.stations = values.map {
                                    MapStation(stationRef: $0.stationId, name: $0.name, displayNumber: $0.arsId, latitude: $0.latitude, longitude: $0.longitude)
                                }
                            case .routes(let result):
                                self?.routes = result.routes
                                let messages = result.providers.filter { !$0.available }.map {
                                    "\($0.provider == "gg" ? "경기" : "서울"): \($0.message ?? "검색하지 못했습니다. 다시 시도해 주세요.")"
                                }
                                self?.routeWarning = messages.isEmpty ? nil : messages.joined(separator: "\n")
                            case .stationFailure(let message): self?.error = "정류장 검색: \(message)"
                            case .routeFailure(let message): self?.routeWarning = "버스 검색: \(message)"
                            }
                        }
                    }
                }
                guard !Task.isCancelled, self?.generation == current else { return }
                self?.loading = false
            } catch {
                guard !Task.isCancelled, self?.generation == current else { return }
                self?.error = error.localizedDescription; self?.loading = false
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
    func cancel() {
        if loading { hasSearched = false }
        generation += 1; task?.cancel(); loading = false
    }
}
