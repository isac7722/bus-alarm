import Foundation

struct StationSummary: Codable, Hashable, Identifiable, Sendable {
    let stationId: String
    let arsId: String
    let name: String
    let direction: String?
    let latitude: Double
    let longitude: Double

    var id: String { stationId }
}

struct RouteSummary: Codable, Hashable, Identifiable, Sendable {
    let routeId: String
    let routeName: String

    var id: String { routeId }
}

struct StationSearchResponse: Codable, Sendable {
    let stations: [StationSummary]
}

struct StationDetailResponse: Codable, Sendable {
    let station: StationSummary
    let routes: [RouteSummary]
}

