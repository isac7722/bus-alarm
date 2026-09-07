import SwiftUI
import WidgetKit

struct BusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BusWidgetEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular, .accessoryCircular, .accessoryInline:
                LockScreenBusWidgetView(entry: entry, family: family)
            default:
                homeScreenWidget
            }
        }
        .containerBackground(for: .widget) {
            widgetBackground
        }
    }

    private var homeScreenWidget: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if let response = entry.response {
                if DataFreshness.status(updatedAt: response.updatedAt, relativeTo: entry.date) == .needsRefresh {
                    refreshRequired
                } else {
                    routeRows(response)
                    Spacer(minLength: 0)
                    if family == .systemMedium { footer(response) }
                }
            } else if entry.configuration == nil {
                unconfigured
            } else {
                unavailable
            }
        }
    }

    @ViewBuilder
    private var widgetBackground: some View {
        switch family {
        case .accessoryRectangular, .accessoryCircular, .accessoryInline:
            Color.clear
        default:
            Color(uiColor: .systemBackground)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bus.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text(entry.configuration?.stationName ?? "버스 도착")
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
            if entry.updateFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("업데이트 실패")
            }
        }
    }

    @ViewBuilder
    private func routeRows(_ response: ArrivalsResponse) -> some View {
        let maximum = family == .systemSmall ? 2 : 4
        ForEach(Array(response.arrivals.prefix(maximum))) { arrival in
            RouteArrivalRow(arrival: arrival, referenceDate: entry.date)
        }
        if response.arrivals.isEmpty {
            Text("선택한 노선의 도착 정보가 없습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func footer(_ response: ArrivalsResponse) -> some View {
        HStack(spacing: 5) {
            Text("업데이트 \(response.updatedAt, format: .dateTime.hour().minute())")
            switch DataFreshness.status(updatedAt: response.updatedAt, relativeTo: entry.date) {
            case .fresh:
                EmptyView()
            case .slightlyStale:
                Label("지연", systemImage: "clock")
            case .delayed:
                Label("업데이트 지연", systemImage: "exclamationmark.circle")
            case .needsRefresh:
                EmptyView()
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var unconfigured: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text("앱에서 정류소와 노선을 선택해 주세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text("정보를 가져올 수 없습니다.")
                .font(.caption.weight(.semibold))
            Text("앱에서 연결을 확인해 주세요.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var refreshRequired: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Label("정보 갱신 필요", systemImage: "arrow.clockwise")
                .font(.caption.weight(.semibold))
            Text("최근 도착 정보가 5분 이상 지났습니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
