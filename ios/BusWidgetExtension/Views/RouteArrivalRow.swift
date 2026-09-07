import SwiftUI

struct RouteArrivalRow: View {
    let arrival: RouteArrival
    let referenceDate: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(arrival.routeName)
                .font(.callout.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            if let prediction = arrival.nearestPrediction(relativeTo: referenceDate) {
                ArrivalPredictionView(prediction: prediction, referenceDate: referenceDate)
            } else {
                Text("정보 없음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
