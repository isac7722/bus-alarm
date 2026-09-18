import Foundation

enum ArrivalCountdownFormatter {
    static let imminentInterval: TimeInterval = 30

    static func text(arrivalAt: Date, relativeTo date: Date) -> String {
        let remaining = arrivalAt.timeIntervalSince(date)
        guard remaining > imminentInterval else { return "곧 도착" }
        return "\(Int(ceil(remaining / 60)))분"
    }

    static func text(for prediction: ArrivalPrediction?, relativeTo date: Date) -> String {
        guard let prediction else { return "정보 없음" }

        switch prediction.vehicleStatus {
        case .running:
            guard let arrivalAt = prediction.arrivalAt else { return "정보 없음" }
            return text(arrivalAt: arrivalAt, relativeTo: date)
        case .waiting:
            return "운행 전"
        case .notAvailable:
            return "정보 없음"
        case .unknown:
            return "확인 필요"
        }
    }
}
