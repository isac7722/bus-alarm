import SwiftUI

struct ArrivalPredictionView: View {
    let prediction: ArrivalPrediction
    let referenceDate: Date

    var body: some View {
        Group {
            switch prediction.vehicleStatus {
            case .running:
                Text(ArrivalCountdownFormatter.text(for: prediction, relativeTo: referenceDate))
            case .waiting:
                Text("운행 전")
            case .notAvailable:
                Text("정보 없음")
            case .unknown:
                Text("확인 필요")
            }
        }
        .font(.caption.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}
