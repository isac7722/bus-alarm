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
                .font(.subheadline.weight(.medium)).foregroundStyle(AppTheme.secondaryText)
            if let activity = waiting.activity {
                Text(activity.attributes.stationName).font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let content = waiting.content {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 12) {
                            ForEach(activity.attributes.selectedRoutes) { route in
                                let state = content.state(for: route.routeId)
                                ViewThatFits(in: .horizontal) {
                                    HStack {
                                        Text(route.routeName).font(.body.weight(.semibold))
                                        Spacer(minLength: 12)
                                        arrivalLabel(state, date: context.date)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(route.routeName).font(.body.weight(.semibold))
                                        arrivalLabel(state, date: context.date)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                if waiting.isStarting { ProgressView("대기 시작 중…").font(.callout) }
                displayHelp
                Button("전체 대기 종료", role: .destructive) { Task { await waiting.stop() } }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(waiting.isBusy)
            } else if isLoading {
                ProgressView("노선을 확인하는 중…")
            } else if let loadError {
                Text(loadError).font(.callout).foregroundStyle(AppTheme.secondaryText)
                Button("다시 시도") { Task { await loadRoutes() } }
                    .frame(minHeight: 44).foregroundStyle(AppTheme.action)
            } else if routes.isEmpty {
                Text("설정 변경에서 기다릴 노선을 선택해 주세요.")
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("탈 수 있는 버스를 모두 선택하세요.").font(.subheadline)
                    Text("최대 4개 · 현재 \(selectedRouteIds.count)개 선택")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
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
                                    .foregroundStyle(selected ? AppTheme.action : AppTheme.secondaryText)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(route.routeName)
                                        .font(.body.weight(selected ? .semibold : .regular))
                                        .foregroundStyle(AppTheme.text)
                                    if let direction = configuration.selections?.first(where: { $0.routeRef == route.routeId })?.direction {
                                        Text(direction).font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                                    }
                                }
                                .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .background(selected ? AppTheme.selection : AppTheme.surface,
                                        in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(selected ? AppTheme.action : AppTheme.separator))
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
                        else { Text(selectedRouteIds.isEmpty ? "노선 선택 필요" : "\(selectedRouteIds.count)개 버스 기다리기") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TransitButtonStyle())
                .disabled(waiting.isBusy || selectedRouteIds.isEmpty)
                .accessibilityIdentifier("waiting-start")
            }
            if let message = waiting.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(AppTheme.text).tint(AppTheme.action)
        .transitCard()
        .task(id: configuration.cacheIdentity) { await loadRoutes() }
    }

    private var displayHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("잠금 화면에는 선택한 버스 모두", systemImage: "lock")
            Label("다이내믹 아일랜드에는 가장 빠른 도착 시간", systemImage: "timer")
        }
        .font(.footnote).foregroundStyle(AppTheme.secondaryText)
    }

    @ViewBuilder
    private func arrivalLabel(_ state: BusWaitingAttributes.ContentState, date: Date) -> some View {
        if state.status == "waiting", let arrival = state.arrivalDate {
            Text(ArrivalCountdownFormatter.text(arrivalAt: arrival, relativeTo: date))
                .monospacedDigit().foregroundStyle(AppTheme.primary)
                .frame(width: countdownWidth, alignment: .trailing)
        } else {
            Text(state.message(relativeTo: date))
                .font(.callout).foregroundStyle(AppTheme.secondaryText)
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
