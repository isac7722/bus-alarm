import Foundation

struct WidgetConfigurationData: Codable, Equatable, Sendable {
    let stationId: String
    let stationName: String
    let routeIds: [String]
    var version: Int = 1
    var displayNumber: String?
    var selections: [BoardingSelection]?

    init(stationId: String, stationName: String, routeIds: [String]) {
        self.stationId = stationId
        self.stationName = stationName
        self.routeIds = Array(routeIds.prefix(4))
    }

    init(validated: ValidatedSelection) {
        stationId = validated.station.stationRef
        stationName = validated.station.name
        routeIds = validated.selections.map(\.routeRef)
        version = 2
        displayNumber = validated.station.displayNumber
        selections = validated.selections
    }

    var cacheIdentity: String {
        ([String(version), stationId] + (selections?.map { $0.boardingId + ":" + $0.routeRevision } ?? routeIds)).joined(separator: "|")
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == 1 || version == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported configuration")
        }
        stationId = try container.decode(String.self, forKey: .stationId)
        stationName = try container.decode(String.self, forKey: .stationName)
        displayNumber = try container.decodeIfPresent(String.self, forKey: .displayNumber)
        selections = try container.decodeIfPresent([BoardingSelection].self, forKey: .selections)
        let stationNode = stationId.split(separator: ":").last
        if version == 2 {
            guard let selections, (1...4).contains(selections.count),
                  Set(selections.map(\.routeRef)).count == selections.count,
                  selections.allSatisfy({ !$0.boardingId.isEmpty && !$0.routeRevision.isEmpty && $0.sequence > 0 && !$0.directionId.isEmpty && $0.stationRef.split(separator: ":").last == stationNode }) else {
                throw DecodingError.dataCorruptedError(forKey: .selections, in: container, debugDescription: "Invalid boarding selection")
            }
            routeIds = selections.map(\.routeRef)
        } else {
            routeIds = Array(try container.decode([String].self, forKey: .routeIds).prefix(4))
        }
    }
}
