import Foundation

struct WidgetConfigurationData: Codable, Equatable, Sendable {
    let stationId: String
    let stationName: String
    let routeIds: [String]

    init(stationId: String, stationName: String, routeIds: [String]) {
        self.stationId = stationId
        self.stationName = stationName
        self.routeIds = Array(routeIds.prefix(4))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stationId = try container.decode(String.self, forKey: .stationId)
        stationName = try container.decode(String.self, forKey: .stationName)
        routeIds = Array(try container.decode([String].self, forKey: .routeIds).prefix(4))
    }
}

