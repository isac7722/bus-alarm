import Foundation

enum ArrivalCountdownFormatter {
    static func text(for prediction: ArrivalPrediction?, relativeTo date: Date) -> String {
        guard let prediction else { return "정보 없음" }

        switch prediction.vehicleStatus {
        case .running:
            guard let arrivalAt = prediction.arrivalAt else { return "정보 없음" }
            let remaining = arrivalAt.timeIntervalSince(date)
            if remaining <= 0 { return "도착" }
            if remaining < 60 { return "곧" }
            return "\(Int(remaining / 60))분"
        case .waiting:
            return "운행 전"
        case .notAvailable:
            return "정보 없음"
        case .unknown:
            return "확인 필요"
        }
    }
}
