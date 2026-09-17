import ActivityKit
import SwiftUI
import WidgetKit

struct BusWaitingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BusWaitingAttributes.self) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: "bus.fill")
                        .font(.title2)
                        .foregroundStyle(.mint)
                        .padding(10)
                        .background(.mint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.attributes.stationName)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Text(context.attributes.routeName)
                            .font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 8)
                    Text(context.state.isEnded ? "대기 종료" : "버스 기다리는 중")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    WaitingCountdown(state: context.state, isStale: context.isStale)
                        .font(.title2.bold())
                    Spacer(minLength: 4)
                    if !context.isStale, !context.state.isEnded, context.state.status == "waiting",
                       let stops = context.state.remainingStops {
                        Text(stops == 0 ? "정류소 근처" : "\(stops)정류장 전")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("도착 정보는 교통 상황에 따라 달라질 수 있습니다.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Link("대기 관리", destination: URL(string: "buswidget://waiting")!)
                        .font(.caption.bold()).foregroundStyle(.mint)
                }
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.10, green: 0.14, blue: 0.16))
            .activitySystemActionForegroundColor(.white)
            .foregroundStyle(.white)
            .widgetURL(URL(string: "buswidget://waiting"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.routeName, systemImage: "bus.fill")
                        .font(.headline).foregroundStyle(.mint).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.isStale, context.state.status == "waiting", let stops = context.state.remainingStops {
                        Text(stops == 0 ? "정류소 근처" : "\(stops)정류장 전").font(.caption)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.attributes.stationName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        WaitingCountdown(state: context.state, isStale: context.isStale).font(.title3.bold())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "bus.fill").foregroundStyle(.mint)
            } compactTrailing: {
                WaitingCountdown(state: context.state, isStale: context.isStale, compact: true)
                    .font(.caption.monospacedDigit()).frame(maxWidth: 64)
            } minimal: {
                Image(systemName: context.isStale ? "arrow.clockwise" : "bus.fill").foregroundStyle(.mint)
            }
            .widgetURL(URL(string: "buswidget://waiting"))
            .keylineTint(.mint)
        }
    }
}

private struct WaitingCountdown: View {
    let state: BusWaitingAttributes.ContentState
    let isStale: Bool
    var compact = false

    var body: some View {
        if !isStale, state.status == "waiting", let arrival = state.arrivalDate, arrival > .now {
            HStack(spacing: 5) {
                if !compact { Text("도착까지") }
                // WidgetKit's timer needs the proposed width. fixedSize() can
                // produce unbounded frames and blank the entire Live Activity.
                Text(timerInterval: Date.now...arrival, countsDown: true)
                    .monospacedDigit()
            }
        } else {
            Text(compact ? compactMessage : state.message(isStale: isStale))
                .lineLimit(1).minimumScaleFactor(0.65)
        }
    }

    private var compactMessage: String {
        if state.isEnded { return "종료" }
        if isStale || state.status == "unavailable" { return "갱신 중" }
        return "곧 도착"
    }
}

#Preview("버스 대기", as: .content, using: BusWaitingAttributes(
    stationId: "01234", stationName: "혜화초등학교", routeId: "100", routeName: "종로07",
    expiresAt: Date.now.addingTimeInterval(3600).timeIntervalSince1970
)) {
    BusWaitingLiveActivity()
} contentStates: {
    BusWaitingAttributes.ContentState(status: "waiting", arrivalAt: Date.now.addingTimeInterval(180).timeIntervalSince1970, remainingStops: 2, updatedAt: Date.now.timeIntervalSince1970)
    BusWaitingAttributes.ContentState(status: "unavailable", arrivalAt: nil, remainingStops: nil, updatedAt: Date.now.timeIntervalSince1970)
    BusWaitingAttributes.ContentState(status: "arrived", arrivalAt: nil, remainingStops: nil, updatedAt: Date.now.timeIntervalSince1970)
}
