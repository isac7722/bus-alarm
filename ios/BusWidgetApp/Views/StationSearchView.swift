import SwiftUI

struct StationSearchView: View {
    @StateObject private var viewModel = StationSearchViewModel()
    let onSave: (WidgetConfigurationData) -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .idle:
                    ContentUnavailableView(
                        "정류소를 검색하세요",
                        systemImage: "magnifyingglass",
                        description: Text("정류소 이름이나 번호를 입력해 주세요.")
                    )
                case .loading:
                    ProgressView("정류소를 찾는 중…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message):
                    ContentUnavailableView {
                        Label("정류소를 불러오지 못했습니다", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("다시 시도", action: viewModel.retry)
                            .buttonStyle(.borderedProminent)
                    }
                case .loaded where viewModel.stations.isEmpty:
                    ContentUnavailableView(
                        "검색 결과가 없습니다",
                        systemImage: "bus",
                        description: Text("정류소 이름을 줄이거나 다른 표기로 검색해 보세요.")
                    )
                case .loaded:
                    stationList
                }
            }
            .navigationTitle("정류소 선택")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PrivacyPolicyButton()
                }
            }
            .searchable(text: $viewModel.query, prompt: "예: 강남역")
            .onChange(of: viewModel.query) { _, _ in viewModel.queryDidChange() }
        }
    }

    private var stationList: some View {
        List(viewModel.stations) { station in
            NavigationLink {
                RouteSelectionView(station: station, onSave: onSave)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(station.name)
                        .font(.headline)
                    Text(station.direction ?? "정류소 번호 \(station.arsId)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            .accessibilityLabel("\(station.name), 정류소 번호 \(station.arsId)")
        }
        .listStyle(.insetGrouped)
    }
}
