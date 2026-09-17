import SwiftUI

struct BusSearchView: View {
    @StateObject private var model = BusSearchViewModel()
    @State private var confirmCancel = false
    let previous: WidgetConfigurationData?
    let onSave: (WidgetConfigurationData) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("검색 방법", selection: $model.searchStops) {
                        Text("버스 번호로 찾기").tag(false)
                        Text("정류장으로 찾기").tag(true)
                    }.pickerStyle(.segmented)
                    Text(model.searchStops ? "정류장을 고른 뒤 버스와 방향을 확인하세요." : "버스를 고르면 지도에서 탈 정류장을 찾을 수 있어요.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.loading { ProgressView("찾는 중…") }
                if let message = model.error ?? model.warning {
                    Section { Text(message).foregroundStyle(.secondary); Button("다시 시도", action: model.search) }
                }
                if model.query.isEmpty {
                    Section("최근 검색") {
                        ForEach(model.recent, id: \.self) { text in Button(text) { model.query = text } }
                        if model.recent.isEmpty { Text("예: 9304, 370, M5107").foregroundStyle(.secondary) }
                    }
                } else if !model.loading && model.routes.isEmpty && model.stations.isEmpty && model.error == nil {
                    ContentUnavailableView.search(text: model.query)
                }
                if model.searchStops {
                    ForEach(model.stations) { station in
                        NavigationLink {
                            StationBoardingEntry(station: station, previous: previous, onSave: onSave)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(station.name).font(.headline)
                                Text(station.arsId).font(.subheadline).foregroundStyle(.secondary)
                            }.padding(.vertical, 8)
                        }
                    }
                } else {
                    ForEach(model.routes) { route in
                        NavigationLink {
                            RouteMapSelectionView(route: route, previous: previous, onSave: onSave)
                                .onAppear { model.remember() }
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "bus.fill").font(.title2).foregroundStyle(AppTheme.primary)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(route.name).font(.title2.bold())
                                    Text("\(route.region) · \(route.kind)").font(.subheadline).foregroundStyle(.secondary)
                                    Text("\(route.start) ↔ \(route.end)").font(.callout)
                                }
                            }.padding(.vertical, 8)
                        }.accessibilityIdentifier("catalog-route.\(route.routeRef)")
                    }
                }
                Section { Text("노선·정류장 정보: 서울특별시, 경기도").font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle(model.searchStops ? "정류장 찾기" : "어떤 버스를 타시나요?")
            .searchable(text: $model.query, prompt: model.searchStops ? "정류장 이름 또는 번호" : "버스 번호")
            .onChange(of: model.query) { _, _ in model.search() }
            .onChange(of: model.searchStops) { _, _ in model.search() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { PrivacyPolicyButton() }
                if previous != nil {
                    ToolbarItem(placement: .topBarLeading) { Button("취소") { confirmCancel = true } }
                }
            }
            .confirmationDialog("설정 변경을 취소할까요? 기존 위젯 설정은 유지됩니다.", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("변경 취소", role: .destructive, action: onCancel)
            }
        }
    }
}

private struct StationBoardingEntry: View {
    let station: StationSummary
    let previous: WidgetConfigurationData?
    let onSave: (WidgetConfigurationData) -> Void
    @State private var resolved: MapStation?
    @State private var error: String?
    var body: some View {
        Group {
            if let resolved { BoardingReviewView(station: resolved, initial: nil, previous: previous, onSave: onSave) }
            else if let error {
                ContentUnavailableView {
                    Label("정류장을 확인하지 못했어요", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("다시 시도") { Task { await load() } }
                    NavigationLink("기존 방식으로 설정") { RouteSelectionView(station: station, onSave: onSave) }
                }
            } else { ProgressView("정류장을 확인하는 중…") }
        }.task { await load() }
    }
    private func load() async {
        error = nil
        do { resolved = try await APIClient().resolveStation(id: station.stationId) }
        catch { self.error = error.localizedDescription }
    }
}
