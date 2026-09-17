import Foundation

@MainActor
final class StationBusViewModel: ObservableObject {
    @Published private(set) var options: [RouteStopOccurrence] = []
    @Published private(set) var selections: [BoardingSelection]
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var warning: String?
    let station: MapStation
    private let api: APIClient?
    private let legacyRoutes: [String]

    init(station: MapStation, favorite: SavedStop? = nil, api: APIClient? = try? APIClient()) {
        self.station = station; self.api = api
        selections = favorite?.configuration.selections ?? []
        legacyRoutes = favorite?.configuration.version == 1 ? favorite?.configuration.routeIds ?? [] : []
    }
    var draft: WidgetConfigurationData {
        WidgetConfigurationData(validated: ValidatedSelection(station: station, selections: selections))
    }
    var canContinue: Bool { !selections.isEmpty && !busy && !loading }
    func toggle(_ stop: RouteStopOccurrence) {
        guard stop.selectable, !busy else { return }
        if selections.contains(where: { $0.id == stop.id }) { remove(stop.id) }
        else if let index = selections.firstIndex(where: { $0.routeRef == stop.routeRef }) { selections[index] = stop.selection }
        else if selections.count < 4 { selections.append(stop.selection) }
    }
    func remove(_ id: String) { if !busy { selections.removeAll { $0.id == id } } }
    func disabled(_ stop: RouteStopOccurrence) -> Bool {
        busy || !stop.selectable || (selections.count >= 4 && !selections.contains { $0.routeRef == stop.routeRef })
    }
    func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            guard let api else { throw APIClientError.invalidBaseURL }
            let result = try await api.boardingOptions(stationRef: station.id)
            options = result.options
            warning = result.complete ? nil : result.warnings.joined(separator: "\n")
            if selections.isEmpty {
                // Upgrade old selections only when exactly one boarding direction is known.
                for route in legacyRoutes {
                    let matches = options.filter { stop in
                        stop.selectable && (route.contains(":") ? stop.routeRef == route : stop.routeRef.split(separator: ":").last.map(String.init) == route)
                    }
                    if matches.count == 1 && selections.count < 4 { selections.append(matches[0].selection) }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func validate() async -> WidgetConfigurationData? {
        guard canContinue else { return nil }
        busy = true; error = nil
        defer { busy = false }
        do {
            guard let api else { throw APIClientError.invalidBaseURL }
            return WidgetConfigurationData(validated: try await api.validateSelection(stationRef: station.id, selections: selections))
        } catch { self.error = error.localizedDescription; return nil }
    }
}

@MainActor
final class CommuteArrivalsModel: ObservableObject {
    @Published private(set) var response: ArrivalsResponse?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private let api: APIClient?
    private var generation = 0
    private var identity: String?
    init(api: APIClient? = try? APIClient()) { self.api = api }
    func refresh(_ configuration: WidgetConfigurationData) async {
        generation += 1
        let current = generation
        if identity != configuration.cacheIdentity { response = nil; identity = configuration.cacheIdentity }
        guard !configuration.routeIds.isEmpty else { response = nil; error = nil; loading = false; return }
        loading = true
        defer { if generation == current { loading = false } }
        do {
            guard let api else { throw APIClientError.invalidBaseURL }
            let result = try await api.arrivals(configuration: configuration)
            guard !Task.isCancelled, current == generation else { return }
            response = result; error = nil
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            self.error = error.localizedDescription
        }
    }
    func upcoming(_ routeID: String, at date: Date) -> Date? {
        guard let response, date.timeIntervalSince(response.updatedAt) <= 90, response.updatedAt <= date.addingTimeInterval(30),
              let prediction = response.arrivals.first(where: { $0.routeId == routeID })?.nearestPrediction(relativeTo: date),
              prediction.vehicleStatus == .running, let arrival = prediction.arrivalAt, arrival > date else { return nil }
        return arrival
    }
    func label(_ routeID: String, at date: Date) -> String {
        if let arrival = upcoming(routeID, at: date) {
            let seconds = Int(ceil(arrival.timeIntervalSince(date)))
            return seconds < 60 ? "곧 도착" : "\(Int(ceil(Double(seconds) / 60)))분"
        }
        if loading && response == nil { return "확인 중" }
        if error != nil && response == nil { return "조회 실패" }
        if let response, date.timeIntervalSince(response.updatedAt) > 90 { return "갱신 필요" }
        return "도착정보 없음"
    }
}
