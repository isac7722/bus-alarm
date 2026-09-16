import SwiftUI
import WidgetKit

struct BusArrivalWidget: Widget {
    let kind = WidgetConstants.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BusWidgetProvider()) { entry in
            BusWidgetView(entry: entry)
        }
        .configurationDisplayName("버스 도착")
        .description("선택한 정류소의 버스 도착 시간을 홈 및 잠금 화면에서 확인합니다.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
        ])
    }
}

@main
struct BusWidgetBundle: WidgetBundle {
    var body: some Widget {
        BusArrivalWidget()
        BusWaitingLiveActivity()
    }
}

#Preview(as: .systemSmall) {
    BusArrivalWidget()
} timeline: {
    BusWidgetEntry.placeholder
}

#Preview(as: .systemMedium) {
    BusArrivalWidget()
} timeline: {
    BusWidgetEntry.placeholder
}

#Preview(as: .accessoryRectangular) {
    BusArrivalWidget()
} timeline: {
    BusWidgetEntry.placeholder
}

#Preview(as: .accessoryCircular) {
    BusArrivalWidget()
} timeline: {
    BusWidgetEntry.placeholder
}

#Preview(as: .accessoryInline) {
    BusArrivalWidget()
} timeline: {
    BusWidgetEntry.placeholder
}
