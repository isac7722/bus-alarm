import Foundation

struct CatalogRoute: Codable, Hashable, Identifiable, Sendable {
    let routeRef: String
    let name: String
    let region: String
    let kind: String
    let start: String
    let end: String
    var id: String { routeRef }
}

struct MapStation: Codable, Hashable, Identifiable, Sendable {
    let stationRef: String
    let name: String
    let displayNumber: String
    let latitude: Double?
    let longitude: Double?
    var id: String { stationRef }
}

struct BoardingSelection: Codable, Hashable, Identifiable, Sendable {
    let boardingId: String
    let routeRef: String
    let routeRevision: String
    let routeName: String
    let stationRef: String
    let sequence: Int
    let directionId: String
    let direction: String
    var id: String { boardingId }
}

struct RouteStopOccurrence: Codable, Hashable, Identifiable, Sendable {
    let boardingId: String
    let routeRef: String
    let routeRevision: String
    let routeName: String
    let stationRef: String
    let sequence: Int
    let directionId: String
    let direction: String
    let station: MapStation
    let nextStop: String
    let selectable: Bool
    let reason: String?
    var id: String { boardingId }
    var selection: BoardingSelection {
        BoardingSelection(boardingId: boardingId, routeRef: routeRef, routeRevision: routeRevision,
                          routeName: routeName, stationRef: stationRef, sequence: sequence,
                          directionId: directionId, direction: direction)
    }
}

struct RouteDirection: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}
struct CatalogDetail: Codable, Sendable {
    let route: CatalogRoute
    let revision: String
    let directions: [RouteDirection]
    let stops: [RouteStopOccurrence]
}
struct ProviderStatus: Codable, Sendable {
    let provider: String
    let available: Bool
    let message: String?
}
struct CatalogSearchResponse: Codable, Sendable {
    let routes: [CatalogRoute]
    let providers: [ProviderStatus]
}
struct BoardingOptions: Codable, Sendable {
    let station: MapStation
    let options: [RouteStopOccurrence]
    let complete: Bool
    let warnings: [String]
}
struct SelectionRequest: Codable, Sendable {
    let stationRef: String
    let selections: [BoardingSelection]
}
struct ValidatedSelection: Codable, Sendable {
    let station: MapStation
    let selections: [BoardingSelection]
}
struct RouteGeometry: Codable, Sendable {
    struct Coordinate: Codable, Sendable { let latitude: Double; let longitude: Double }
    let coordinates: [Coordinate]
    let source: String
}
