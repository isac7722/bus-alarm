import SwiftUI
import WidgetKit

struct LockScreenBusWidgetView: View {
    let entry: BusWidgetEntry
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryRectangular:
            rectangular
        case .accessoryCircular:
            circular
        case .accessoryInline:
            inline
        default:
            EmptyView()
        }
    }

    private var rectangular: some View {
        HStack(spacing: 7) {
            rectangularIconTile

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(stationName)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(0.72)
                    Spacer(minLength: 2)
                    if entry.updateFailed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .accessibilityLabel("업데이트 실패")
                    }
                }

                if let routes = availableRoutes, !routes.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(routes.prefix(2))) { route in
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(route.routeName)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Spacer(minLength: 3)
                                LockScreenArrivalText(
                                    prediction: route.nearestPrediction(relativeTo: entry.date),
                                    referenceDate: entry.date
                                )
                                .font(.system(.headline, design: .rounded, weight: .bold))
                                .frame(minWidth: 30, alignment: .trailing)
                                .layoutPriority(1)
                            }
                        }
                    }
                } else {
                    Label(stateMessage, systemImage: stateSymbol)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var rectangularIconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.16))
            Image(systemName: "bus.fill")
                .font(.system(size: 21, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .widgetAccentable()
        }
        .frame(width: 42, height: 52)
        .accessibilityHidden(true)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let route = availableRoutes?.first {
                VStack(spacing: -1) {
                    LockScreenArrivalText(
                        prediction: route.nearestPrediction(relativeTo: entry.date),
                        referenceDate: entry.date
                    )
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    Text(route.routeName)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .opacity(0.72)
                }
                .padding(4)
            } else {
                Image(systemName: stateSymbol)
                    .font(.title3)
                    .widgetAccentable()
                    .accessibilityLabel(stateMessage)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var inline: some View {
        if let route = availableRoutes?.first {
            HStack(spacing: 3) {
                Text(route.routeName)
                    .fontWeight(.semibold)
                Text("·")
                    .opacity(0.7)
                    .accessibilityHidden(true)
                LockScreenArrivalText(
                    prediction: route.nearestPrediction(relativeTo: entry.date),
                    referenceDate: entry.date
                )
            }
            .accessibilityElement(children: .combine)
        } else {
            Label(stateMessage, systemImage: stateSymbol)
        }
    }

    private var availableRoutes: [RouteArrival]? {
        guard let response = entry.response else { return nil }
        guard DataFreshness.status(updatedAt: response.updatedAt, relativeTo: entry.date) != .needsRefresh else {
            return nil
        }
        return response.arrivals
    }

    private var stationName: String {
        entry.configuration?.stationName ?? entry.response?.station.name ?? "버스 도착"
    }

    private var stateMessage: String {
        if entry.configuration == nil {
            return "앱에서 노선을 선택하세요"
        }
        if let response = entry.response,
           DataFreshness.status(updatedAt: response.updatedAt, relativeTo: entry.date) == .needsRefresh
        {
            return "정보 갱신 필요"
        }
        return "도착 정보 없음"
    }

    private var stateSymbol: String {
        if entry.configuration == nil {
            return "bus.fill"
        }
        if let response = entry.response,
           DataFreshness.status(updatedAt: response.updatedAt, relativeTo: entry.date) == .needsRefresh
        {
            return "arrow.clockwise"
        }
        return "exclamationmark.triangle"
    }
}

private struct LockScreenArrivalText: View {
    let prediction: ArrivalPrediction?
    let referenceDate: Date

    var body: some View {
        Text(ArrivalCountdownFormatter.text(for: prediction, relativeTo: referenceDate))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
