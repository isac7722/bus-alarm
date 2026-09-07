import SwiftUI

struct SavedConfigurationView: View {
    let configuration: WidgetConfigurationData
    let onEdit: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.spacingLarge) {
                    Image(systemName: "bus.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(AppTheme.primary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: AppTheme.spacingSmall) {
                        Text(configuration.stationName)
                            .font(.largeTitle.bold())
                        Text("정류소 \(displayARSId(configuration.stationId))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: AppTheme.spacingSmall) {
                        Text("위젯 노선")
                            .font(.headline)
                        Text("\(configuration.routeIds.count)개 노선이 홈 화면 위젯에 표시됩니다.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(AppTheme.spacingMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))

                    Button("설정 변경", action: onEdit)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(minHeight: 44)

                    VStack(alignment: .leading, spacing: AppTheme.spacingSmall) {
                        Label("홈 화면을 길게 눌러 버스 도착 위젯을 추가하세요.", systemImage: "square.grid.2x2")
                        Text("도착 시간은 위젯에서 자동으로 줄어듭니다.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                .padding(AppTheme.spacingLarge)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("버스 위젯")
        }
    }

    private func displayARSId(_ value: String) -> String {
        guard value.count == 5 else { return value }
        return "\(value.prefix(2))-\(value.suffix(3))"
    }
}

