import SwiftUI

struct RouteSelectionView: View {
    @StateObject private var viewModel: RouteSelectionViewModel
    let onSave: (WidgetConfigurationData) -> Void

    init(station: StationSummary, onSave: @escaping (WidgetConfigurationData) -> Void) {
        _viewModel = StateObject(wrappedValue: RouteSelectionViewModel(station: station))
        self.onSave = onSave
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView("노선을 불러오는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label("노선을 불러오지 못했습니다", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("다시 시도") { Task { await viewModel.load() } }
                        .buttonStyle(.borderedProminent)
                }
            case .loaded:
                routeList
            }
        }
        .navigationTitle(viewModel.station.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .safeAreaInset(edge: .bottom) { saveBar }
        .alert("저장할 수 없습니다", isPresented: Binding(
            get: { viewModel.saveError != nil },
            set: { isPresented in
                if !isPresented { viewModel.dismissSaveError() }
            }
        )) {
            Button("확인", role: .cancel) { viewModel.dismissSaveError() }
        } message: {
            Text(viewModel.saveError ?? "")
        }
    }

    private var routeList: some View {
        List {
            Section {
                ForEach(viewModel.routes) { route in
                    Button {
                        viewModel.toggle(route)
                    } label: {
                        HStack {
                            Text(route.routeName)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: viewModel.isSelected(route) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(viewModel.isSelected(route) ? AppTheme.primary : .secondary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(viewModel.isDisabled(route))
                    .accessibilityLabel("\(route.routeName)번 노선")
                    .accessibilityValue(viewModel.isSelected(route) ? "선택됨" : "선택 안 됨")
                    .accessibilityAddTraits(viewModel.isSelected(route) ? .isSelected : [])
                }
            } header: {
                Text("최대 4개 노선")
            } footer: {
                Text("선택한 순서와 관계없이 정류소 노선 순서로 저장됩니다.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var saveBar: some View {
        HStack(spacing: AppTheme.spacingMedium) {
            Text(viewModel.selectionCountText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button("저장") {
                if let configuration = viewModel.save() {
                    onSave(configuration)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canSave)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, AppTheme.spacingMedium)
        .padding(.vertical, AppTheme.spacingSmall)
        .background(.bar)
    }
}
