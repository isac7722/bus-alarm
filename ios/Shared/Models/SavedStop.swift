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
    var displayRoutes: [RouteSummary] {
        let known = routes + (configuration.selections?.map { RouteSummary(routeId: $0.routeRef, routeName: $0.routeName) } ?? [])
        return configuration.routeIds.compactMap { id in
            known.first { $0.routeId == id && !$0.routeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }
    var hasMissingRouteNames: Bool { displayRoutes.count < configuration.routeIds.count }
    var displayNumber: String? {
        if let number = configuration.displayNumber, !number.isEmpty { return number }
        return configuration.version == 1 ? configuration.stationId : nil
    }
    var directions: [String] {
        (configuration.selections ?? []).reduce(into: []) { result, selection in
            if !selection.direction.isEmpty && !result.contains(selection.direction) { result.append(selection.direction) }
        }
    }
    var routeDescription: String {
        displayRoutes.isEmpty ? "버스 번호 확인 필요" : displayRoutes.map(\.routeName).joined(separator: " · ")
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
