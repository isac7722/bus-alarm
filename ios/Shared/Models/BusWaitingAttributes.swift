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
        var revision: Int64? = nil

        var arrivalDate: Date? { arrivalAt.map(Date.init(timeIntervalSince1970:)) }

        func message(isStale: Bool = false, relativeTo date: Date = .now) -> String {
            switch status {
            case "arrived": return "버스 도착"
            case "passed": return "버스가 지나간 것으로 예상됩니다"
            case "expired": return "대기 시간이 종료되었습니다"
            case "cancelled": return "대기를 종료했습니다"
            case "finished": return "모든 버스의 대기가 종료되었습니다"
            default:
                if status == "unavailable" || arrivalDate == nil || arrivalDate! <= date { return "다시 연결 중" }
                return "도착까지"
            }
        }

        var isEnded: Bool { ["arrived", "passed", "expired", "cancelled", "finished"].contains(status) }

        /// Age does not stop a last-known countdown. The next ETA is the system's next presentation boundary.
        func nextTransition(after date: Date = .now) -> Date? {
            let states = routes?.map(\.content) ?? [self]
            return states.filter { $0.status == "waiting" }.compactMap(\.arrivalDate).filter { $0 > date }.min()
        }
        func supersedes(_ old: ContentState) -> Bool {
            if old.isEnded { return false }
            if let revision {
                // The first tracked server state supersedes a local preview; source age is checked on the server.
                guard let previous = old.revision else { return true }
                return revision > previous
            }
            if old.revision != nil { return false }
            return updatedAt >= old.updatedAt
        }

        func nearestRoute(relativeTo date: Date = .now) -> RouteState? {
            routes?.filter {
                $0.content.status == "waiting"
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
