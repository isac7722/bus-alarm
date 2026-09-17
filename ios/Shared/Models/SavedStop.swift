import Foundation

struct SavedStop: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var nickname: String = ""
    var configuration: WidgetConfigurationData
    var routes: [RouteSummary]

    init(configuration: WidgetConfigurationData, nickname: String = "", routes: [RouteSummary]? = nil) {
        self.configuration = configuration
        self.nickname = nickname
        self.routes = routes ?? configuration.selections?.map { RouteSummary(routeId: $0.routeRef, routeName: $0.routeName) } ?? []
    }

    // A metadata revision refresh doesn't create a second copy of a favorite.
    var combinationID: String {
        let visits = configuration.selections?.map(\.boardingId) ?? configuration.routeIds
        return ([configuration.stationId] + visits.sorted()).joined(separator: "|")
    }
    var routeDescription: String {
        routes.isEmpty ? "저장한 버스 \(configuration.routeIds.count)개" : routes.map(\.routeName).joined(separator: " · ")
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension WidgetConfigurationData {
    func selecting(_ ids: Set<String>) -> WidgetConfigurationData {
        if let selections, version == 2 {
            let station = MapStation(stationRef: stationId, name: stationName, displayNumber: displayNumber ?? "", latitude: nil, longitude: nil)
            return WidgetConfigurationData(validated: ValidatedSelection(station: station, selections: selections.filter { ids.contains($0.routeRef) }))
        }
        return WidgetConfigurationData(stationId: stationId, stationName: stationName, routeIds: routeIds.filter { ids.contains($0) })
    }
}
