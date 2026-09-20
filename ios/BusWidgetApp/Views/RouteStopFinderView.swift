import SwiftUI
import MapKit

struct RouteStopFinderView: View {
    @StateObject private var model: RouteStopFinderViewModel
    @ObservedObject var location: StationLocationService
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detent: RoutePanelDetent = .medium
    @State private var dragHeight: CGFloat?
    @State private var dragOrigin: CGFloat?
    @State private var showingMap = false
    let replacing: SavedStop?
    let intent: StationSelectionIntent
    private var separateMapAndList: Bool { typeSize.isAccessibilitySize || verticalSize == .compact }
    private var mapOnly: Bool { separateMapAndList && showingMap && model.selected == nil }
    private var listOnly: Bool { separateMapAndList && !mapOnly }

    init(route: CatalogRoute, location: StationLocationService, replacing: SavedStop? = nil, intent: StationSelectionIntent = .explore) {
        _model = StateObject(wrappedValue: RouteStopFinderViewModel(route: route))
        self.location = location; self.replacing = replacing; self.intent = intent
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.selected == nil && !separateMapAndList {
                controls
            }
            GeometryReader { geometry in
                let height = max(1, geometry.size.height)
                let panelHeight = mapOnly ? 0 : listOnly ? height : dragHeight ?? detent.height(in: height)
                VStack(spacing: 0) {
                    if !listOnly {
                        routeMap.frame(height: max(0, height - panelHeight)).clipped()
                            .allowsHitTesting(height - panelHeight >= 44)
                            .accessibilityHidden(height - panelHeight < 44)
                    }
                    if !mapOnly {
                        VStack(spacing: 0) {
                            if !listOnly { panelHandle(height: height) }
                            if let selected = model.selected {
                                RouteBoardingPanel(stop: selected, replacing: replacing, intent: intent,
                                                   compactPanel: listOnly || detent == .collapsed || dragHeight != nil) {
                                    model.selected = nil
                                }.id(selected.id)
                            } else {
                                stopList
                            }
                        }
                        .frame(height: panelHeight).background(AppTheme.surface)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
                        .overlay(alignment: .top) { Divider().overlay(AppTheme.separator).padding(.horizontal, 16) }
                    }
                }
            }
        }
        .background(AppTheme.background).foregroundStyle(AppTheme.text).tint(AppTheme.action)
        .navigationTitle("\(model.route.name)번")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if separateMapAndList && model.selected == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(showingMap ? "목록" : "지도", systemImage: showingMap ? "list.bullet" : "map") {
                        showingMap.toggle()
                    }.accessibilityIdentifier("route-map-list-toggle")
                }
            }
        }
        .task {
            if model.detail == nil { await model.load(coordinate: location.nearbyCoordinate) }
        }
        .task { await model.loadGeometry() }
        .onChange(of: model.selected?.id) { _, id in
            if let id {
                lastSelectedID = id
                showingMap = false
                if detent == .collapsed { setDetent(.medium) }
            }
        }
        .onChange(of: location.updateID) { _, _ in
            guard let coordinate = location.nearbyCoordinate else { return }
            model.show(.nearby, coordinate: coordinate)
            showingMap = true
            setDetent(.collapsed)
        }
    }

    private func showWholeRoute() {
        model.show(.all, coordinate: location.nearbyCoordinate)
        showingMap = true
        setDetent(.collapsed)
    }

    private func setDetent(_ value: RoutePanelDetent) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            detent = value; dragHeight = nil; dragOrigin = nil
        }
    }

    private func panelHandle(height: CGFloat) -> some View {
        Button { setDetent(detent.next) } label: {
            VStack(spacing: 6) {
                Capsule().fill(AppTheme.separator).frame(width: 36, height: 4).accessibilityHidden(true)
                HStack {
                    Text(model.selected == nil ? "\(model.scope.rawValue) · \(model.visibleStops.count)개" : "선택한 정류장")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: detent == .expanded ? "chevron.down" : "chevron.up")
                }
            }.foregroundStyle(AppTheme.text).padding(.horizontal, 20).padding(.vertical, 10)
             .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("route-panel-handle")
        .accessibilityLabel("노선 정류장 영역 크기")
        .accessibilityValue(detent.label)
        .accessibilityHint("위아래로 밀거나 두 번 탭하여 크기를 조절합니다.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setDetent(detent == .collapsed ? .medium : .expanded)
            case .decrement: setDetent(detent == .expanded ? .medium : .collapsed)
            @unknown default: break
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .global)
                .onChanged { value in
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    if dragOrigin == nil { dragOrigin = detent.height(in: height) }
                    guard let origin = dragOrigin else { return }
                    dragHeight = min(height, max(RoutePanelDetent.collapsed.height(in: height), origin - value.translation.height))
                }
                .onEnded { value in
                    guard let origin = dragOrigin else { return }
                    let projected = origin - value.predictedEndTranslation.height
                    let nearest = RoutePanelDetent.allCases.min {
                        abs($0.height(in: height) - projected) < abs($1.height(in: height) - projected)
                    } ?? detent
                    setDetent(nearest)
                }
        )
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
                emphasized: model.selected == nil && model.focusedStationID == nil && model.nearestStationID == station.id,
                action: { model.focus(station) })
        }, line: model.line, dashed: model.approximateLine, userLocation: location.coordinate, onMove: { model.camera.region = $0 }, onCameraChange: { model.camera.snapshot = $0 })
        .overlay(alignment: separateMapAndList ? .topLeading : .topTrailing) {
            HStack(spacing: 8) {
                Button(action: showWholeRoute) { mapControlLabel("전체 경로", symbol: "map") }
                    .buttonStyle(TransitMapButtonStyle()).accessibilityIdentifier("route-whole-route")
                    .accessibilityLabel("전체 경로")
                    .accessibilityShowsLargeContentViewer { Label("전체 경로", systemImage: "map") }
                if separateMapAndList { mapLocationButton }
            }.padding(8)
        }
        .overlay(alignment: .bottomTrailing) {
            if !separateMapAndList && model.selected != nil {
                mapLocationButton.padding(.trailing, 8).padding(.bottom, 44)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !mapOnly && model.approximateLine && model.line.count > 1 {
                Text("점선 · 정류장 연결선").font(.caption).foregroundStyle(AppTheme.secondaryText)
                    .padding(6).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 8).padding(.bottom, 40).allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if mapOnly && model.approximateLine && model.line.count > 1 {
                Text("점선 · 정류장 연결선").font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(AppTheme.surface)
            }
        }
    }

    private var mapLocationButton: some View {
        Button { location.request() } label: {
            mapControlLabel(location.isLocating ? "위치 확인 중" : "내 위치", symbol: "location")
        }.buttonStyle(TransitMapButtonStyle()).disabled(location.isLocating)
         .accessibilityLabel(location.isLocating ? "위치 확인 중" : "내 위치")
         .accessibilityShowsLargeContentViewer { Label("내 위치", systemImage: "location") }
         .accessibilityIdentifier("route-my-location")
    }

    @ViewBuilder
    private func mapControlLabel(_ title: String, symbol: String) -> some View {
        if separateMapAndList {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).frame(width: 28, height: 28)
        } else {
            Label(title, systemImage: symbol)
        }
    }

    private var routeLineNotice: some View {
        Text("점선은 정류장 연결선입니다.").font(.footnote).foregroundStyle(AppTheme.secondaryText)
    }

    private var stopList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if listOnly { controls }
                    if listOnly && model.approximateLine && model.line.count > 1 {
                        routeLineNotice.padding(.horizontal, 20)
                    }
                    if model.loading { ProgressView("정류장을 불러오는 중…").padding(20) }
                    if let error = model.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).font(.callout)
                            Button("다시 시도") { Task { await model.load(coordinate: location.nearbyCoordinate) } }.frame(minHeight: 44)
                        }.padding(20)
                    }
                    if let message = location.message { Text(message).font(.callout).padding(20) }
                    if let notice = model.notice {
                        Text(notice).font(.callout).foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 20).padding(.vertical, 8)
                    }
                    if model.scope == .nearby && model.nearbyStops.isEmpty && !model.loading {
                        Button("전체 경로 보기", action: showWholeRoute)
                            .buttonStyle(TransitButtonStyle(prominent: false)).padding(.horizontal, 20)
                            .accessibilityIdentifier("route-empty-whole-route")
                    }
                    if model.focusedStationID != nil {
                        Button("정류장 목록으로 돌아가기", systemImage: "arrow.left") { model.focusedStationID = nil }
                            .frame(minHeight: 44).padding(.horizontal, 20)
                    }
                    if model.detail != nil && model.visibleStops.isEmpty && model.scope == .all {
                        TransitEmptyState(title: "정류장 정보가 없습니다.", symbol: "bus", message: "다시 조회하거나 다른 버스를 검색해 주세요.")
                    }
                    ForEach(model.visibleStops) { stop in
                        Button { model.select(stop) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(stop.station.name).font(.headline).foregroundStyle(AppTheme.text)
                                    Text(stop.direction.isEmpty ? "방면 정보 없음" : stop.direction).font(.subheadline)
                                    if model.scope == .nearby, let distance = model.distance(to: stop.station) {
                                        Text("직선 \(distance < 1_000 ? "\(Int(distance.rounded()))m" : String(format: "%.1fkm", distance / 1_000)) · \(stop.station.displayNumber.isEmpty ? "정류장 번호 정보 없음" : stop.station.displayNumber)")
                                            .font(.footnote).monospacedDigit()
                                    } else {
                                        if !stop.nextStop.isEmpty { Text("다음: \(stop.nextStop)").font(.subheadline) }
                                        Text(stop.station.displayNumber.isEmpty ? "정류장 번호 정보 없음" : "정류장 \(stop.station.displayNumber)")
                                            .font(.footnote).monospacedDigit()
                                    }
                                    if let reason = stop.reason { Text(reason).font(.callout) }
                                }.fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").accessibilityHidden(true)
                            }.foregroundStyle(AppTheme.secondaryText)
                             .frame(minHeight: 44).padding(.horizontal, 20).padding(.vertical, 12).contentShape(Rectangle())
                             .background(model.nearestStationID == stop.stationRef ? AppTheme.selection : Color.clear)
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

private enum RoutePanelDetent: CaseIterable {
    case collapsed, medium, expanded

    var label: String {
        switch self { case .collapsed: "접힘"; case .medium: "중간"; case .expanded: "펼침" }
    }

    var next: Self {
        switch self { case .collapsed: .medium; case .medium: .expanded; case .expanded: .collapsed }
    }

    func height(in available: CGFloat) -> CGFloat {
        switch self {
        case .collapsed: min(available * 0.45, max(160, available * 0.3))
        case .medium: available * 0.5
        case .expanded: available
        }
    }
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
    let compactPanel: Bool
    let close: () -> Void
    private var saving: Bool { replacing != nil || intent == .addFavorite }
    private var flexibleActions: Bool { compactPanel || typeSize.isAccessibilitySize || verticalSize == .compact }

    init(stop: RouteStopOccurrence, replacing: SavedStop?, intent: StationSelectionIntent, compactPanel: Bool, close: @escaping () -> Void) {
        self.stop = stop; self.replacing = replacing; self.intent = intent; self.close = close
        self.compactPanel = compactPanel
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
