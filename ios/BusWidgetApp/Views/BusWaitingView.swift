import SwiftUI

struct BusWaitingView: View {
    @EnvironmentObject private var waiting: BusWaitingManager
    let configuration: WidgetConfigurationData
    @State private var routes: [RouteSummary] = []
    @State private var selectedRouteId = ""
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("버스 기다리기", systemImage: "bus.fill")
                .font(.headline)
            if let activity = waiting.activity {
                Text("\(activity.attributes.stationName) · \(activity.attributes.routeName)")
                    .font(.title3.bold())
                if let content = waiting.content {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let stale = context.date.timeIntervalSince1970 - content.updatedAt > 90
                        if !stale, content.status == "waiting", let date = content.arrivalDate, date > context.date {
                            HStack {
                                Text("도착까지")
                                Text(timerInterval: context.date...date, countsDown: true)
                                    .monospacedDigit().fixedSize()
                            }
                        } else { Text(content.message(isStale: stale)).foregroundStyle(.secondary) }
                    }
                }
                Text("잠금 화면에서 도착 상황을 확인할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("대기 종료", role: .destructive) { Task { await waiting.stop() } }
                    .buttonStyle(.bordered)
                    .disabled(waiting.isBusy)
            } else if isLoading {
                ProgressView("노선을 확인하는 중…")
            } else if let loadError {
                Text(loadError).font(.callout).foregroundStyle(.secondary)
                Button("다시 시도") { Task { await loadRoutes() } }
            } else if routes.isEmpty {
                Text("설정 변경에서 기다릴 노선을 선택해 주세요.")
                    .foregroundStyle(.secondary)
            } else {
                Text("기다릴 버스 한 대의 도착 상황을 잠금 화면에 표시합니다.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("기다릴 노선", selection: $selectedRouteId) {
                    ForEach(routes) { route in Text(route.routeName).tag(route.routeId) }
                }
                .pickerStyle(.menu)
                Button {
                    guard let route = routes.first(where: { $0.routeId == selectedRouteId }) else { return }
                    Task { await waiting.start(configuration: configuration, route: route) }
                } label: {
                    if waiting.isBusy { ProgressView("대기 시작 중…") }
                    else { Label("버스 기다리기", systemImage: "play.fill") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(waiting.isBusy || selectedRouteId.isEmpty)
            }
            if let message = waiting.errorMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .task(id: configuration.cacheIdentity) { await loadRoutes() }
    }

    private func loadRoutes() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        if let selections = configuration.selections, configuration.version == 2 {
            routes = selections.map { RouteSummary(routeId: $0.routeRef, routeName: "\($0.routeName) · \($0.direction)") }
            selectedRouteId = routes.first?.routeId ?? ""
            return
        }
        do {
            let response = try await APIClient().stationDetail(stationId: configuration.stationId)
            routes = response.routes.filter { configuration.routeIds.contains($0.routeId) }
            selectedRouteId = routes.first?.routeId ?? ""
        } catch { loadError = error.localizedDescription }
    }
}
