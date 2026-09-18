import SwiftUI
import MapKit

struct RouteStopFinderView: View {
    @StateObject private var model: RouteStopFinderViewModel
    @ObservedObject var location: StationLocationService
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSize
    let replacing: SavedStop?
    let intent: StationSelectionIntent
    private var listOnly: Bool { typeSize.isAccessibilitySize || verticalSize == .compact }

    init(route: CatalogRoute, location: StationLocationService, replacing: SavedStop? = nil, intent: StationSelectionIntent = .explore) {
        _model = StateObject(wrappedValue: RouteStopFinderViewModel(route: route))
        self.location = location; self.replacing = replacing; self.intent = intent
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.selected == nil && !listOnly {
                controls
            }
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    if !listOnly {
                        routeMap.frame(height: geometry.size.height * (model.selected == nil ? 0.42 : 0.32)).clipped()
                    }
                    if let selected = model.selected {
                        RouteBoardingPanel(stop: selected, replacing: replacing, intent: intent) {
                            model.selected = nil
                        }.id(selected.id)
                    } else {
                        stopList
                    }
                }
            }
        }
        .background(AppTheme.background).foregroundStyle(AppTheme.text).tint(AppTheme.action)
        .navigationTitle("\(model.route.name)번")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.detail == nil { await model.load(coordinate: location.nearbyCoordinate) }
        }
        .task { await model.loadGeometry() }
        .onChange(of: model.selected?.id) { _, id in if let id { lastSelectedID = id } }
        .onChange(of: location.isLocating) { _, locating in
            if !locating { model.show(.nearby, coordinate: location.nearbyCoordinate) }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("어디서 타세요?").font(.headline)
                Spacer(minLength: 8)
                Button { location.request() } label: {
                    Label(location.isLocating ? "위치 확인 중" : "내 위치", systemImage: "location")
                        .frame(minHeight: 44)
                }.disabled(location.isLocating).accessibilityIdentifier("route-my-location")
            }
            if listOnly {
                HStack(alignment: .top) { scopeButton(.nearby); scopeButton(.all) }
            } else {
                Picker("정류장 보기", selection: Binding(get: { model.scope }, set: { model.show($0, coordinate: location.nearbyCoordinate) })) {
                    ForEach(RouteStopFinderViewModel.Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(minHeight: 44).accessibilityIdentifier("route-stop-scope")
            }
        }.padding(.horizontal, 20).padding(.bottom, 8).background(AppTheme.surface)
    }

    private func scopeButton(_ scope: RouteStopFinderViewModel.Scope) -> some View {
        Button { model.show(scope, coordinate: location.nearbyCoordinate) } label: {
            Text(scope.rawValue).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(TransitButtonStyle(prominent: model.scope == scope))
         .accessibilityAddTraits(model.scope == scope ? .isSelected : [])
    }

    private var routeMap: some View {
        NaverTransitMap(camera: model.camera, pins: model.mapStations.compactMap { station in
            guard let point = RouteStopFinderViewModel.point(station) else { return nil }
            return TransitMapPin(id: "route-station-pin.\(station.id)", coordinate: point,
                label: "\(station.name), 정류장 \(station.displayNumber)", title: station.name,
                selected: model.selected?.stationRef == station.id || model.focusedStationID == station.id,
                action: { model.focus(station) })
        }, line: model.line, dashed: model.approximateLine, userLocation: location.coordinate, onMove: { model.camera.region = $0 }, onCameraChange: { model.camera.snapshot = $0 })
    }

    private var stopList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if listOnly { controls }
                    if model.approximateLine && model.line.count > 1 && !listOnly {
                        Text("점선은 정류장 연결선입니다.").font(.footnote).foregroundStyle(AppTheme.secondaryText).padding(.horizontal, 20)
                    }
                    if model.loading { ProgressView("정류장을 불러오는 중…").padding(20) }
                    if let error = model.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).font(.callout)
                            Button("다시 시도") { Task { await model.load(coordinate: location.nearbyCoordinate) } }.frame(minHeight: 44)
                        }.padding(20)
                    }
                    if let message = location.message { Text(message).font(.callout).padding(20) }
                    if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(AppTheme.secondaryText).padding(20) }
                    if model.focusedStationID != nil {
                        Button("정류장 목록으로 돌아가기", systemImage: "arrow.left") { model.focusedStationID = nil }
                            .frame(minHeight: 44).padding(.horizontal, 20)
                    }
                    if model.detail != nil && model.visibleStops.isEmpty {
                        TransitEmptyState(title: "정류장 정보가 없습니다.", symbol: "bus", message: "다시 조회하거나 다른 버스를 검색해 주세요.")
                    }
                    ForEach(model.visibleStops) { stop in
                        Button { model.select(stop) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(stop.station.name).font(.headline).foregroundStyle(AppTheme.text)
                                    Text(stop.direction.isEmpty ? "방면 정보 없음" : stop.direction).font(.subheadline)
                                    if !stop.nextStop.isEmpty { Text("다음: \(stop.nextStop)").font(.subheadline) }
                                    Text(stop.station.displayNumber.isEmpty ? "정류장 번호 정보 없음" : "정류장 \(stop.station.displayNumber)")
                                        .font(.footnote).monospacedDigit()
                                    if let reason = stop.reason { Text(reason).font(.callout) }
                                }.fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").accessibilityHidden(true)
                            }.foregroundStyle(AppTheme.secondaryText)
                             .frame(minHeight: 44).padding(.horizontal, 20).padding(.vertical, 12).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!stop.selectable)
                         .accessibilityIdentifier("route-stop.\(stop.id)")
                         .id(stop.id)
                        Divider().padding(.horizontal, 20)
                    }
                }
            }.accessibilityIdentifier("route-stops")
             .onAppear { if let id = lastSelectedID { proxy.scrollTo(id, anchor: .center) } }
        }.background(AppTheme.surface)
    }

    // Keep the last chosen row visible when closing the summary panel.
    @State private var lastSelectedID: String?
}

private struct RouteBoardingPanel: View {
    @EnvironmentObject private var favorites: FavoritesStore
    @StateObject private var model: StationBusViewModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSize
    @State private var nickname: String
    @State private var expanded = false
    @State private var prepared: SavedStop?
    @State private var actionTask: Task<Void, Never>?
    let stop: RouteStopOccurrence
    let replacing: SavedStop?
    let intent: StationSelectionIntent
    let close: () -> Void
    private var saving: Bool { replacing != nil || intent == .addFavorite }
    private var flexibleActions: Bool { typeSize.isAccessibilitySize || verticalSize == .compact }

    init(stop: RouteStopOccurrence, replacing: SavedStop?, intent: StationSelectionIntent, close: @escaping () -> Void) {
        self.stop = stop; self.replacing = replacing; self.intent = intent; self.close = close
        let sameStation = replacing?.configuration.stationId == stop.stationRef
        _model = StateObject(wrappedValue: StationBusViewModel(station: stop.station, favorite: sameStation ? replacing : nil, preselected: stop))
        _nickname = State(initialValue: replacing?.nickname ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        StationSummaryView(name: stop.station.name, number: stop.station.displayNumber)
                        Spacer(minLength: 0)
                        Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel("정류장 다시 선택").accessibilityIdentifier("route-selection-close")
                            .disabled(model.busy)
                    }
                    if !expanded {
                        ForEach(model.selections) { selection in
                            VStack(alignment: .leading, spacing: 4) {
                                Label("\(selection.routeName)번 선택됨", systemImage: "checkmark.circle.fill").font(.headline)
                                Text(selection.direction).font(.subheadline)
                                if let next = model.options.first(where: { $0.id == selection.id })?.nextStop, !next.isEmpty {
                                    Text("다음: \(next)").font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                                }
                            }.accessibilityElement(children: .combine)
                        }
                    }
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("최대 4개 · \(model.selections.count)개 선택").font(.subheadline)
                            if model.loading { ProgressView("버스 목록을 불러오는 중…") }
                            if let warning = model.warning { Text(warning).font(.callout) }
                            Button("버스 목록 새로고침") { Task { await model.load() } }
                                .frame(minHeight: 44).disabled(model.loading || model.busy)
                            ForEach(model.options) { option in
                                StationArrivalOption(stop: option, station: stop.station,
                                    selected: model.selections.contains { $0.id == option.id },
                                    disabled: model.disabled(option), refreshEnabled: prepared == nil) { model.toggle(option) }
                            }
                        }
                    } label: { Text("다른 버스 함께 선택").frame(minHeight: 44) }
                    .accessibilityIdentifier("route-add-buses")
                    .onChange(of: expanded) { _, value in if value { Task { await model.load() } } }
                    DisclosureGroup {
                        TextField("예: 퇴근길", text: $nickname).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("즐겨찾기 별명").frame(minHeight: 44)
                    } label: { Text("별명 (선택)").frame(minHeight: 44) }
                    if let error = model.error { Text(error).font(.callout) }
                    if let error = favorites.error { Text(error).font(.callout) }
                    if flexibleActions { actions }
                }.padding(20)
            }
            if !flexibleActions { actions.transitActionBar() }
        }.background(AppTheme.surface)
         .onDisappear { actionTask?.cancel() }
         .navigationDestination(item: $prepared) { FavoriteDetailView(favorite: $0, autoStart: true) }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                actionTask = Task {
                    if saving { await save() }
                    else if let configuration = await model.validate(), !Task.isCancelled {
                        prepared = SavedStop(configuration: configuration, nickname: nickname)
                    }
                }
            } label: {
                Group {
                    if model.busy { ProgressView("확인 중…") }
                    else if saving { Text(replacing == nil ? "즐겨찾기에 추가" : "변경 저장") }
                    else if model.selections.count == 1 { Text("\(model.selections[0].routeName)번 기다리기") }
                    else { Text(model.selections.isEmpty ? "기다릴 버스를 선택하세요" : "\(model.selections.count)개 버스 기다리기") }
                }.frame(maxWidth: .infinity)
            }.buttonStyle(TransitButtonStyle()).disabled(!model.canContinue)
             .accessibilityIdentifier(saving ? "save-favorite" : "route-selection-wait")
            if !saving {
                Button { actionTask = Task { await save() } } label: {
                    Label("즐겨찾기에 추가", systemImage: "bookmark").frame(maxWidth: .infinity, minHeight: 44)
                }.disabled(!model.canContinue).accessibilityIdentifier("save-favorite")
            }
        }
    }
    private func save() async {
        guard let configuration = await model.validate(), !Task.isCancelled else { return }
        var value = SavedStop(configuration: configuration, nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines))
        if let replacing { value.id = replacing.id }
        if favorites.save(value) { favorites.announceSave(value) }
    }
}
