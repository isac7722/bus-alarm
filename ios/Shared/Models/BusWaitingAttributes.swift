import ActivityKit
import Foundation

struct BusWaitingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        // APNs uses Unix seconds explicitly; no custom ActivityKit date decoding.
        let status: String
        let arrivalAt: Double?
        let remainingStops: Int?
        let updatedAt: Double

        var arrivalDate: Date? { arrivalAt.map(Date.init(timeIntervalSince1970:)) }

        func message(isStale: Bool = false, relativeTo date: Date = .now) -> String {
            switch status {
            case "arrived": return "버스 도착"
            case "passed": return "버스가 지나간 것으로 예상됩니다"
            case "expired": return "대기 시간이 종료되었습니다"
            case "cancelled": return "대기를 종료했습니다"
            default:
                if isStale || status == "unavailable" { return "도착 정보 갱신 지연" }
                if let arrivalDate, arrivalDate <= date { return "도착 정보 확인 중" }
                return arrivalAt == nil ? "도착 정보 확인 중" : "도착까지"
            }
        }

        var isEnded: Bool { ["arrived", "passed", "expired", "cancelled"].contains(status) }
    }

    let stationId: String
    let stationName: String
    let routeId: String
    let routeName: String
    let expiresAt: Double
    var boarding: BoardingSelection? = nil
}

struct LiveWaitRegistration: Decodable {
    let expiresAt: Double
    let content: BusWaitingAttributes.ContentState
}
