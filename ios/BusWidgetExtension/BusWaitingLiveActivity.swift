import ActivityKit
import SwiftUI
import WidgetKit

struct BusWaitingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BusWaitingAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "bus.fill").foregroundStyle(Color(uiColor: TransitColors.liveAccent))
                    Text(context.attributes.stationName)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color(uiColor: TransitColors.liveSecondary))
                        .accessibilityLabel("대기 관리")
                }
                Divider().overlay(.white.opacity(0.2))
                WaitingRouteRows(attributes: context.attributes, state: context.state, isStale: context.isStale)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            // Four routes must remain inside ActivityKit's 160pt presentation.
            .dynamicTypeSize(...DynamicTypeSize.large)
            .activityBackgroundTint(Color(uiColor: TransitColors.liveBackground))
            .activitySystemActionForegroundColor(.white)
            .foregroundStyle(.white)
            .widgetURL(URL(string: "buswidget://waiting"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("버스 기다리기", systemImage: "bus.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color(uiColor: TransitColors.liveAccent))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.attributes.selectedRoutes.count)개 노선")
                        .font(.caption).foregroundStyle(Color(uiColor: TransitColors.liveSecondary))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    WaitingRouteRows(attributes: context.attributes, state: context.state, isStale: context.isStale)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                }
            } compactLeading: {
                Image(systemName: "bus.fill").foregroundStyle(Color(uiColor: TransitColors.liveAccent))
            } compactTrailing: {
                WaitingCountdown(state: context.state.summary(), isStale: context.isStale, compact: true)
                    .font(.caption.monospacedDigit()).frame(width: 48)
            } minimal: {
                WaitingCountdown(state: context.state.summary(), isStale: context.isStale, compact: true)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .frame(width: 36).foregroundStyle(Color(uiColor: TransitColors.liveAccent))
            }
            .widgetURL(URL(string: "buswidget://waiting"))
            .keylineTint(Color(uiColor: TransitColors.liveAccent))
        }
    }
}

private struct WaitingRouteRows: View {
    let attributes: BusWaitingAttributes
    let state: BusWaitingAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(spacing: 4) {
            ForEach(attributes.selectedRoutes) { route in
                let content = state.state(for: route.routeId)
                HStack(spacing: 8) {
                    Text(route.routeName).font(.subheadline.weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                    if content.status == "waiting", let stops = content.remainingStops {
                        Text(stops == 0 ? "정류소 근처" : "\(stops)정류장 전")
                            .font(.caption).foregroundStyle(Color(uiColor: TransitColors.liveSecondary)).lineLimit(1)
                    }
                    WaitingCountdown(state: content, isStale: isStale)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(content.isEnded ? .white : Color(uiColor: TransitColors.liveAccent))
                        .frame(width: 88, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct WaitingCountdown: View {
    let state: BusWaitingAttributes.ContentState
    let isStale: Bool
    var compact = false


    var body: some View {
        if state.status == "waiting", let arrival = state.arrivalDate {
            // ActivityKit redraws on app/APNs updates and the imminent stale-date.
            // TimelineView/custom format styles do not provide a background clock here.
            Text(ArrivalCountdownFormatter.text(arrivalAt: arrival, relativeTo: .now))
                .monospacedDigit().multilineTextAlignment(.trailing)
                .lineLimit(1).minimumScaleFactor(0.6)
        } else {
            Text(message).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private var message: String {
        switch state.status {
        case "arrived": return "도착"
        case "passed": return "통과 예상"
        case "expired", "cancelled", "finished": return "종료"
        default: return compact ? "연결 중" : "다시 연결 중"
        }
    }
}

#Preview("여러 버스 대기", as: .content, using: BusWaitingAttributes(
    stationId: "01234", stationName: "혜화초등학교", routeId: "100", routeName: "종로07",
    expiresAt: Date.now.addingTimeInterval(3600).timeIntervalSince1970,
    routes: [
        .init(routeId: "100", routeName: "종로07"), .init(routeId: "101", routeName: "102"),
        .init(routeId: "102", routeName: "143"), .init(routeId: "103", routeName: "160")
    ]
)) {
    BusWaitingLiveActivity()
} contentStates: {
    BusWaitingAttributes.ContentState(status: "waiting", arrivalAt: nil, remainingStops: nil, updatedAt: Date.now.timeIntervalSince1970, routes: [
        .init(routeId: "100", content: .init(status: "waiting", arrivalAt: Date.now.addingTimeInterval(180).timeIntervalSince1970, remainingStops: 2, updatedAt: Date.now.timeIntervalSince1970)),
        .init(routeId: "101", content: .init(status: "waiting", arrivalAt: Date.now.addingTimeInterval(300).timeIntervalSince1970, remainingStops: 4, updatedAt: Date.now.timeIntervalSince1970)),
        .init(routeId: "102", content: .init(status: "arrived", arrivalAt: nil, remainingStops: nil, updatedAt: Date.now.timeIntervalSince1970)),
        .init(routeId: "103", content: .init(status: "unavailable", arrivalAt: nil, remainingStops: nil, updatedAt: Date.now.timeIntervalSince1970))
    ])
}
