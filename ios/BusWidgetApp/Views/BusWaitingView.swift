import SwiftUI

struct BusWaitingView: View {
    @EnvironmentObject private var waiting: BusWaitingManager
    let configuration: WidgetConfigurationData
    @ScaledMetric(relativeTo: .body) private var countdownWidth = 80.0
    @State private var routes: [RouteSummary] = []
    @State private var selectedRouteIds: Set<String> = []
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("버스 기다리기", systemImage: "bus.fill")
                .font(.headline)
            if let activity = waiting.activity {
                Text(activity.attributes.stationName).font(.title3.bold())
                if let content = waiting.content {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 12) {
                            ForEach(activity.attributes.selectedRoutes) { route in
                                let state = content.state(for: route.routeId)
                                let stale = context.date.timeIntervalSince1970 - state.updatedAt > 90
                                ViewThatFits(in: .horizontal) {
                                    HStack {
                                        Text(route.routeName).font(.body.weight(.semibold))
                                        Spacer(minLength: 12)
                                        arrivalLabel(state, stale: stale, date: context.date)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(route.routeName).font(.body.weight(.semibold))
                                        arrivalLabel(state, stale: stale, date: context.date)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                displayHelp
                Button("전체 대기 종료", role: .destructive) { Task { await waiting.stop() } }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(waiting.isBusy)
            } else if isLoading {
                ProgressView("노선을 확인하는 중…")
            } else if let loadError {
                Text(loadError).font(.callout).foregroundStyle(.secondary)
                Button("다시 시도") { Task { await loadRoutes() } }
                    .frame(minHeight: 44)
            } else if routes.isEmpty {
                Text("설정 변경에서 기다릴 노선을 선택해 주세요.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("탈 수 있는 버스를 모두 선택하세요.").font(.subheadline)
                    Text("최대 4개 · 현재 \(selectedRouteIds.count)개 선택")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 8) {
                    ForEach(routes) { route in
                        let selected = selectedRouteIds.contains(route.routeId)
                        Button {
                            if selected { selectedRouteIds.remove(route.routeId) }
                            else { selectedRouteIds.insert(route.routeId) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selected ? AppTheme.primary : .secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(route.routeName)
                                        .font(.body.weight(selected ? .semibold : .regular))
                                        .foregroundStyle(.primary)
                                    if let direction = configuration.selections?.first(where: { $0.routeRef == route.routeId })?.direction {
                                        Text(direction).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .background(selected ? AppTheme.primary.opacity(0.08) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(selected ? AppTheme.primary : Color.secondary.opacity(0.35)))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel([route.routeName, configuration.selections?.first(where: { $0.routeRef == route.routeId })?.direction].compactMap { $0 }.joined(separator: ", "))
                        .accessibilityValue(selected ? "선택됨" : "선택 안 됨")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("waiting-route.\(route.routeId)")
                        .disabled(waiting.isBusy)
                    }
                }
                displayHelp
                Button {
                    let selected = routes.filter { selectedRouteIds.contains($0.routeId) }
                    Task { await waiting.start(configuration: configuration, routes: selected) }
                } label: {
                    Group {
                        if waiting.isBusy { ProgressView("대기 시작 중…") }
                        else { Label(selectedRouteIds.isEmpty ? "노선 선택 필요" : "\(selectedRouteIds.count)개 버스 기다리기", systemImage: "play.fill") }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(waiting.isBusy || selectedRouteIds.isEmpty)
                .accessibilityIdentifier("waiting-start")
            }
            if let message = waiting.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .task(id: configuration.cacheIdentity) { await loadRoutes() }
    }

    private var displayHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("잠금 화면에는 선택한 버스 모두", systemImage: "lock")
            Label("다이내믹 아일랜드에는 가장 빠른 도착 시간", systemImage: "timer")
        }
        .font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func arrivalLabel(_ state: BusWaitingAttributes.ContentState, stale: Bool, date: Date) -> some View {
        if !stale, state.status == "waiting", let arrival = state.arrivalDate, arrival > date {
            Text(timerInterval: date...arrival, countsDown: true)
                .monospacedDigit().foregroundStyle(AppTheme.primary)
                .frame(width: countdownWidth, alignment: .trailing)
        } else {
            Text(state.message(isStale: stale, relativeTo: date))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func loadRoutes() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        if let selections = configuration.selections, configuration.version == 2 {
            routes = selections.map { RouteSummary(routeId: $0.routeRef, routeName: $0.routeName) }
        } else {
            do {
                let response = try await APIClient().stationDetail(stationId: configuration.stationId)
                guard !Task.isCancelled else { return }
                routes = response.routes.filter { configuration.routeIds.contains($0.routeId) }
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
        selectedRouteIds = Set(routes.map(\.routeId))
    }
}
