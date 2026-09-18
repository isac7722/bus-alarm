import Foundation
import MapKit

@MainActor
final class RouteStopFinderViewModel: ObservableObject {
    enum Scope: String, CaseIterable { case nearby = "가까운 정류장", all = "전체 정류장" }
    @Published private(set) var detail: CatalogDetail?
    @Published private(set) var geometry: RouteGeometry?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var scope: Scope = .all
    @Published private(set) var notice: String?
    @Published var selected: RouteStopOccurrence?
    @Published var focusedStationID: String?
    @Published var camera = TransitMapCamera(region: MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.978),
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)))
    let route: CatalogRoute
    private let api: APIClient?
    private var coordinate: CLLocationCoordinate2D?

    init(route: CatalogRoute, api: APIClient? = try? APIClient()) { self.route = route; self.api = api }

    var line: [CLLocationCoordinate2D] {
        let coordinates = geometry?.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            .filter { CLLocationCoordinate2DIsValid($0) } ?? []
        return coordinates.isEmpty ? stops.compactMap { Self.point($0.station) } : coordinates
    }
    var approximateLine: Bool { geometry?.source != "provider" || (geometry?.coordinates.isEmpty ?? true) }
    func loadGeometry() async {
        guard geometry == nil, let api else { return }
        let result = try? await api.routeGeometry(ref: route.id)
        if !Task.isCancelled { geometry = result }
    }
    var stops: [RouteStopOccurrence] { detail?.stops.sorted { $0.sequence < $1.sequence } ?? [] }
    var nearbyStops: [RouteStopOccurrence] {
        guard let coordinate else { return [] }
        return Self.nearby(stops, coordinate: coordinate)
    }
    var visibleStops: [RouteStopOccurrence] {
        let values = scope == .nearby ? nearbyStops : stops
        return focusedStationID.map { id in values.filter { $0.stationRef == id } } ?? values
    }
    var mapStations: [MapStation] {
        var seen = Set<String>()
        return (scope == .nearby ? nearbyStops : stops).compactMap {
            seen.insert($0.stationRef).inserted ? $0.station : nil
        }
    }
    // A straight-line 1 km radius is for ranking candidates, not for estimating a walking route.
    static func nearby(_ stops: [RouteStopOccurrence], coordinate: CLLocationCoordinate2D) -> [RouteStopOccurrence] {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return stops.compactMap { stop -> (RouteStopOccurrence, Double)? in
            guard let point = point(stop.station) else { return nil }
            let distance = origin.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
            return distance <= 1_000 ? (stop, distance) : nil
        }.sorted { a, b in a.1 == b.1 ? a.0.sequence < b.0.sequence : a.1 < b.1 }.map(\.0)
    }
    static func point(_ station: MapStation) -> CLLocationCoordinate2D? {
        guard let lat = station.latitude, let lon = station.longitude else { return nil }
        let value = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        return CLLocationCoordinate2DIsValid(value) ? value : nil
    }
    func load(coordinate: CLLocationCoordinate2D?) async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            guard let api else { throw APIClientError.invalidBaseURL }
            let value = try await api.routeDetail(ref: route.id)
            try Task.checkCancellation()
            detail = value
            show(.nearby, coordinate: coordinate)
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
    func show(_ requested: Scope, coordinate: CLLocationCoordinate2D?) {
        self.coordinate = coordinate
        focusedStationID = nil
        if requested == .nearby, coordinate != nil, !nearbyStops.isEmpty {
            scope = .nearby; notice = nil
        } else {
            scope = .all
            notice = requested == .nearby
                ? (coordinate == nil ? "전체 정류장을 보고 있어요. 내 위치를 사용하면 가까운 정류장을 찾을 수 있어요."
                   : "주변 1km에 이 버스의 정류장이 없어 전체 정류장을 보여드려요.") : nil
        }
        fitMap()
    }
    func focus(_ station: MapStation) {
        focusedStationID = station.id
        let matches = (scope == .nearby ? nearbyStops : stops).filter { $0.stationRef == station.id }
        if matches.count == 1, let stop = matches.first, stop.selectable { select(stop) }
        else { selected = nil }
    }
    func select(_ stop: RouteStopOccurrence) {
        guard stop.selectable else { return }
        selected = stop
        if let point = Self.point(stop.station) { camera = TransitMapCamera(region: .init(center: point, latitudinalMeters: 500, longitudinalMeters: 500)) }
    }
    private func fitMap() {
        var points = mapStations.compactMap(Self.point)
        if scope == .nearby, let coordinate { points.append(coordinate) }
        guard let minLat = points.map(\.latitude).min(), let maxLat = points.map(\.latitude).max(),
              let minLon = points.map(\.longitude).min(), let maxLon = points.map(\.longitude).max() else { return }
        camera = TransitMapCamera(region: MKCoordinateRegion(
            center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: .init(latitudeDelta: max(0.006, (maxLat - minLat) * 1.25), longitudeDelta: max(0.006, (maxLon - minLon) * 1.25))))
    }
}
