import ActivityKit
import Foundation

struct BusWaitingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        // APNs uses Unix seconds explicitly; no custom ActivityKit date decoding.
        let status: String
        let arrivalAt: Double?
        let remainingStops: Int?
        let updatedAt: Double
        var routes: [RouteState]? = nil

        var arrivalDate: Date? { arrivalAt.map(Date.init(timeIntervalSince1970:)) }

        func message(isStale: Bool = false, relativeTo date: Date = .now) -> String {
            switch status {
            case "arrived": return "버스 도착"
            case "passed": return "버스가 지나간 것으로 예상됩니다"
            case "expired": return "대기 시간이 종료되었습니다"
            case "cancelled": return "대기를 종료했습니다"
            case "finished": return "모든 버스의 대기가 종료되었습니다"
            default:
                if isStale || status == "unavailable" { return "도착 정보 갱신 지연" }
                if let arrivalDate, arrivalDate <= date { return "도착 정보 확인 중" }
                return arrivalAt == nil ? "도착 정보 확인 중" : "도착까지"
            }
        }

        var isEnded: Bool { ["arrived", "passed", "expired", "cancelled", "finished"].contains(status) }

        func nearestRoute(relativeTo date: Date = .now) -> RouteState? {
            routes?.filter {
                $0.content.status == "waiting" && date.timeIntervalSince1970 - $0.content.updatedAt <= 90
                    && ($0.content.arrivalAt ?? 0) > date.timeIntervalSince1970
            }.min { ($0.content.arrivalAt ?? .infinity) < ($1.content.arrivalAt ?? .infinity) }
        }

        func summary(relativeTo date: Date = .now) -> ContentState {
            guard routes != nil, !isEnded else { return self }
            return nearestRoute(relativeTo: date)?.content ?? ContentState(
                status: "unavailable", arrivalAt: nil, remainingStops: nil, updatedAt: updatedAt
            )
        }

        func state(for routeId: String) -> ContentState {
            // A terminal group state takes precedence, including local cancellation.
            if isEnded && status != "finished" { return self }
            return routes?.first { $0.routeId == routeId }?.content ?? (routes == nil ? self : ContentState(
                status: "unavailable", arrivalAt: nil, remainingStops: nil, updatedAt: updatedAt
            ))
        }
    }

    struct RouteState: Codable, Hashable {
        let routeId: String
        let content: ContentState
    }

    struct Route: Codable, Hashable, Identifiable {
        let routeId: String
        let routeName: String
        var boarding: BoardingSelection? = nil
        var id: String { routeId }
    }

    let stationId: String
    let stationName: String
    let routeId: String
    let routeName: String
    let expiresAt: Double
    var boarding: BoardingSelection? = nil
    var routes: [Route]? = nil

    var selectedRoutes: [Route] {
        routes ?? [Route(routeId: routeId, routeName: routeName, boarding: boarding)]
    }
}

struct LiveWaitRegistration: Decodable {
    let expiresAt: Double
    let content: BusWaitingAttributes.ContentState
}
