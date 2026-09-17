import SwiftUI

enum StationSelectionIntent {
    case explore, addFavorite
}

struct StationBusSelectionView: View {
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: StationBusViewModel
    @StateObject private var arrivals = CommuteArrivalsModel()
    @State private var nickname: String
    @State private var prepared: SavedStop?
    @State private var saved = false
    @State private var discard = false
    private let editing: SavedStop?
    private let intent: StationSelectionIntent
    private var savingFavorite: Bool { editing != nil || intent == .addFavorite }
    init(station: MapStation, favorite: SavedStop? = nil, intent: StationSelectionIntent = .explore) {
        self.intent = intent
        let sameStation = favorite.map { value in
            if value.configuration.stationId.contains(":") {
                return value.configuration.stationId.split(separator: ":").last == station.stationRef.split(separator: ":").last
            }
            return value.configuration.stationId == station.displayNumber.replacingOccurrences(of: "-", with: "")
        } ?? false
        _model = StateObject(wrappedValue: StationBusViewModel(station: station, favorite: sameStation ? favorite : nil))
        _nickname = State(initialValue: favorite?.nickname ?? "")
        editing = favorite
    }
    private var changed: Bool {
        !saved && (model.selections != (editing?.configuration.selections ?? []) || nickname != (editing?.nickname ?? ""))
    }
    var body: some View {
        List {
            Section {
                StationSummaryView(name: model.station.name, number: model.station.displayNumber)
                Label("정류장 번호와 버스 방면을 확인해 주세요.", systemImage: "info.circle")
                    .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
            }.listRowBackground(AppTheme.surface)
            Section("탈 수 있는 버스 · \(model.selections.count)/4 선택") {
                if model.loading { ProgressView("경유 버스를 불러오는 중…") }
                if let message = model.error ?? model.warning {
                    Text(message).font(.callout)
                    Button("다시 시도") { Task { await model.load() } }.foregroundStyle(AppTheme.action)
                }
                if !model.loading && model.options.isEmpty && model.error == nil && model.warning == nil {
                    Text("이 정류장의 버스가 없습니다.").foregroundStyle(AppTheme.secondaryText)
                }
                ForEach(model.options) { stop in
                    TimelineView(.periodic(from: .now, by: 10)) { context in
                        Button { model.toggle(stop); saved = false } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(stop.routeName).font(.headline).monospacedDigit()
                                    Text(stop.direction).font(.subheadline)
                                    if model.selections.contains(where: { $0.id == stop.id }) {
                                        Text(arrivals.label(stop.routeRef, at: context.date))
                                            .font(.subheadline.weight(.medium)).monospacedDigit()
                                            .foregroundStyle(AppTheme.action)
                                    }
                                    Text(stop.reason ?? (stop.nextStop.isEmpty ? "마지막 정류장" : "다음: \(stop.nextStop)"))
                                        .font(.callout).foregroundStyle(AppTheme.secondaryText)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: model.selections.contains(where: { $0.id == stop.id }) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(AppTheme.action).font(.title3).accessibilityHidden(true)
                            }.frame(minHeight: 44).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.disabled(stop))
                         .accessibilityIdentifier("boarding-option.\(stop.id)")
                         .accessibilityAddTraits(model.selections.contains(where: { $0.id == stop.id }) ? .isSelected : [])
                         .accessibilityValue(model.selections.contains(where: { $0.id == stop.id }) ? "선택됨" : "선택 안 됨")
                    }
                    .listRowBackground(model.selections.contains(where: { $0.id == stop.id }) ? AppTheme.selection : AppTheme.surface)
                }
            }.listRowBackground(AppTheme.surface)
            if !model.selections.isEmpty {
                Section("즐겨찾기") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("별명 (선택)").font(.callout)
                        TextField("예: 퇴근길, 학교에서 집", text: $nickname)
                            .onChange(of: nickname) { _, _ in saved = false }
                    }
                    if let error = arrivals.error {
                        Text(error).font(.footnote).foregroundStyle(AppTheme.secondaryText)
                    }
                    Text("도착정보가 없어도 즐겨찾기에 저장할 수 있습니다.")
                        .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                    if let error = favorites.error { Text(error).foregroundStyle(AppTheme.secondaryText) }
                }.listRowBackground(AppTheme.surface)
            }
        }
        .transitList()
        .navigationTitle(editing != nil ? "즐겨찾기 수정" : savingFavorite ? "저장할 버스 선택" : "기다릴 버스 선택")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("닫기") { if changed { discard = true } else { dismiss() } } }
        }
        .interactiveDismissDisabled(changed || model.busy)
        .confirmationDialog("선택한 내용을 저장하지 않고 닫을까요?", isPresented: $discard, titleVisibility: .visible) {
            Button("닫기", role: .destructive) { dismiss() }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let error = model.error, !model.selections.isEmpty {
                    Text(error).font(.footnote).foregroundStyle(AppTheme.secondaryText)
                }
                if !savingFavorite && !model.selections.isEmpty {
                    Button { Task { await save() } } label: {
                        Label("즐겨찾기에 추가", systemImage: "bookmark")
                            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.foregroundStyle(AppTheme.action).disabled(!model.canContinue)
                     .accessibilityIdentifier("save-favorite")
                }
                Button {
                    Task {
                        if savingFavorite { await save() }
                        else if let configuration = await model.validate() {
                            prepared = SavedStop(configuration: configuration, nickname: nickname)
                        }
                    }
                } label: {
                    Group {
                        if model.busy { ProgressView("확인 중…") }
                        else if savingFavorite { Text(editing == nil ? "즐겨찾기에 추가" : "변경 저장") }
                        else { Text(model.selections.isEmpty ? "기다릴 버스를 선택하세요" : "\(model.selections.count)개 버스 기다리기") }
                    }
                        .frame(maxWidth: .infinity)
                }.buttonStyle(TransitButtonStyle()).disabled(!model.canContinue)
                 .accessibilityIdentifier(savingFavorite ? "save-favorite" : "selection-wait")
            }.transitActionBar()
        }
        .navigationDestination(item: $prepared) { value in FavoriteDetailView(favorite: value, autoStart: true) }
        .task { await model.load() }
        .task(id: model.draft.cacheIdentity) { await arrivals.refresh(model.draft) }
    }
    private func save() async {
        guard let configuration = await model.validate() else { return }
        var value = SavedStop(configuration: configuration, nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines))
        if let editing { value.id = editing.id }
        saved = favorites.save(value)
        if saved { favorites.announceSave(value); dismiss() }
    }
}
