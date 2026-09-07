import Foundation

enum VehicleStatus: String, Codable, Sendable {
    case running = "RUNNING"
    case waiting = "WAITING"
    case notAvailable = "NOT_AVAILABLE"
    case unknown = "UNKNOWN"
}

struct ArrivalPrediction: Codable, Hashable, Sendable {
    let order: Int
    let arrivalAt: Date?
    let remainingSeconds: Int?
    let remainingStops: Int?
    let vehicleStatus: VehicleStatus
}

struct RouteArrival: Codable, Hashable, Identifiable, Sendable {
    let routeId: String
    let routeName: String
    let predictions: [ArrivalPrediction]

    var id: String { routeId }

    func nearestPrediction(relativeTo date: Date) -> ArrivalPrediction? {
        let runningPredictions = predictions.compactMap { prediction -> (ArrivalPrediction, Date)? in
            guard prediction.vehicleStatus == .running, let arrivalAt = prediction.arrivalAt else { return nil }
            return (prediction, arrivalAt)
        }

        if let nearestUpcoming = runningPredictions.filter({ $0.1 > date }).min(by: { lhs, rhs in
            if lhs.1 == rhs.1 { return lhs.0.order < rhs.0.order }
            return lhs.1 < rhs.1
        }) {
            return nearestUpcoming.0
        }

        if let mostRecent = runningPredictions.max(by: { lhs, rhs in
            if lhs.1 == rhs.1 { return lhs.0.order > rhs.0.order }
            return lhs.1 < rhs.1
        }) {
            return mostRecent.0
        }

        return predictions.first(where: { $0.vehicleStatus == .waiting }) ?? predictions.first
    }
}

struct ArrivalStation: Codable, Hashable, Sendable {
    let stationId: String
    let name: String
}

struct ArrivalsResponse: Codable, Hashable, Sendable {
    let station: ArrivalStation
    let updatedAt: Date
    let fetchedAt: Date
    let arrivals: [RouteArrival]
}

enum DataFreshness: Equatable, Sendable {
    case fresh
    case slightlyStale
    case delayed
    case needsRefresh

    static func status(updatedAt: Date, relativeTo date: Date) -> DataFreshness {
        let age = max(0, date.timeIntervalSince(updatedAt))
        switch age {
        case ...60:
            return .fresh
        case ...180:
            return .slightlyStale
        case ..<300:
            return .delayed
        default:
            return .needsRefresh
        }
    }
}
