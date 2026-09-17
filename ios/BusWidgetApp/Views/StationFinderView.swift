import SwiftUI
import MapKit

struct StationFinderView: View {
    var replacing: SavedStop? = nil
    var intent: StationSelectionIntent = .explore
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = StationFinderViewModel()
    @StateObject private var location = StationLocationService()
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSize
    @Environment(\.dismiss) private var dismiss
    @State private var position = TransitMapCamera(region: MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.978),
        span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)))
    @State private var detent: StationPanelDetent = .medium
    @State private var beforeSearch: StationPanelDetent = .medium
    @State private var searching = false
    @State private var dragHeight: CGFloat?
    @State private var dragOrigin: CGFloat?
    @State private var listAtTop = true
    @State private var listDragCanResize: Bool?
    private var fullList: Bool { verticalSize == .compact || typeSize.isAccessibilitySize }
    @State private var mapMoved = false
    @State private var selectedStationID: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapControls
                    .font(.subheadline.weight(.medium)).padding(.horizontal, 20)
                    .background(AppTheme.surface)
                Divider().overlay(AppTheme.separator)
                if let message = location.message { Text(message).font(.callout).padding(.horizontal) }
                GeometryReader { geometry in
                    let height = max(1, geometry.size.height)
                    let panelHeight = fullList ? height : dragHeight ?? detent.height(in: height)
                    VStack(spacing: 0) {
                        stationMap
                            .frame(height: max(0, height - panelHeight)).clipped()
                            .contentShape(Rectangle())
                            .allowsHitTesting(height - panelHeight >= 44)
                            .accessibilityHidden(height - panelHeight < 44)
                        VStack(spacing: 0) {
                            panelHandle(height: height)
                            stationList
                                .scrollDisabled(!fullList && detent != .expanded)
                                .simultaneousGesture(panelDrag(height: height, fromHandle: false), including: fullList ? .subviews : .all)
                        }
                        .frame(height: panelHeight).background(AppTheme.surface)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
                        .overlay(alignment: .top) { Divider().overlay(AppTheme.separator).padding(.horizontal, 16) }
                    }
                }
            }.background(AppTheme.background).foregroundStyle(AppTheme.text).tint(AppTheme.action)
            .toolbar { if replacing != nil { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } } }
            .navigationTitle("정류장 찾기")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.query, isPresented: $searching, prompt: "정류장 이름 또는 번호")
            .onChange(of: model.query) { _, _ in model.search() }
            .onChange(of: searching) { _, active in
                if active { beforeSearch = detent; setDetent(.expanded) }
                else { setDetent(beforeSearch) }
            }
            .onChange(of: favorites.saveNotice?.id) { _, notice in
                guard notice != nil else { return }
                model.selected = nil
                if replacing != nil { dismiss() }
            }
            .onChange(of: location.updateID) { _, _ in
                if let point = location.coordinate {
                    let area = TransitMapCamera.locationRegion(center: point)
                    model.region = area; position = TransitMapCamera(region: area); model.query = ""
                    beforeSearch = .collapsed; searching = false; setDetent(.collapsed)
                    model.search()
                }
            }
            .task {
                if let replacing, let station = try? await APIClient().resolveStation(id: replacing.configuration.version == 1 ? replacing.configuration.stationId : replacing.configuration.stationId.hasPrefix("gg:") ? replacing.configuration.stationId : replacing.configuration.displayNumber ?? ""),
                   let lat = station.latitude, let lon = station.longitude {
                    let area = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015))
                    model.region = area; position = TransitMapCamera(region: area)
                }
                model.search()
            }
            .onDisappear { model.cancel() }
            .sheet(item: $model.selected) { station in
                NavigationStack { StationBusSelectionView(station: station, favorite: replacing, intent: intent) }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder private var mapControls: some View {
        if typeSize.isAccessibilitySize && verticalSize != .compact {
            VStack(alignment: .leading, spacing: 4) {
                mapDisplayControl
                myLocationButton
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack {
                mapDisplayControl
                Spacer()
                myLocationButton
            }
        }
    }
    @ViewBuilder private var mapDisplayControl: some View {
        if searching {
            Button("검색 취소") { model.query = ""; searching = false }
                .frame(minHeight: 44).accessibilityIdentifier("station-search-cancel")
        } else if fullList {
            Label("정류장 목록", systemImage: "list.bullet").foregroundStyle(AppTheme.secondaryText)
        } else {
            Text("지도에서 찾거나 목록을 올려보세요")
                .font(.footnote).foregroundStyle(AppTheme.secondaryText)
        }
    }

    private func setDetent(_ value: StationPanelDetent) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            detent = value; dragHeight = nil; dragOrigin = nil; listDragCanResize = nil
        }
    }

    private func panelHandle(height: CGFloat) -> some View {
        Button {
            if !fullList { setDetent(detent.next) }
        } label: {
            VStack(spacing: 6) {
                if !fullList {
                    Capsule().fill(AppTheme.separator).frame(width: 36, height: 4).accessibilityHidden(true)
                }
                HStack {
                    Text("\(model.query.isEmpty ? "주변 정류장" : "검색 결과") · \(model.stations.count)개")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !fullList { Image(systemName: detent == .expanded ? "chevron.down" : "chevron.up") }
                }
            }.foregroundStyle(AppTheme.text).padding(.horizontal, 20).padding(.vertical, 10)
             .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(fullList)
        .accessibilityIdentifier("station-panel-handle")
        .accessibilityLabel("정류장 목록 크기")
        .accessibilityValue(fullList ? "펼침" : detent.label)
        .accessibilityHint("위아래로 밀거나 두 번 탭하여 크기를 조절합니다.")
        .accessibilityAdjustableAction { direction in
            guard !fullList else { return }
            switch direction {
            case .increment: setDetent(detent == .collapsed ? .medium : .expanded)
            case .decrement: setDetent(detent == .expanded ? .medium : .collapsed)
            @unknown default: break
            }
        }
        .highPriorityGesture(panelDrag(height: height, fromHandle: true), including: fullList ? .subviews : .all)
    }

    private func panelDrag(height: CGFloat, fromHandle: Bool) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                guard !fullList, abs(value.translation.height) > abs(value.translation.width) else { return }
                if !fromHandle && listDragCanResize == nil {
                    listDragCanResize = detent != .expanded || (listAtTop && value.translation.height > 0)
                }
                guard fromHandle || listDragCanResize == true else { return }
                if dragOrigin == nil { dragOrigin = detent.height(in: height) }
                guard let origin = dragOrigin else { return }
                dragHeight = min(height, max(StationPanelDetent.collapsed.height(in: height), origin - value.translation.height))
            }
            .onEnded { value in
                listDragCanResize = nil
                guard let origin = dragOrigin else { return }
                let projected = origin - value.predictedEndTranslation.height
                let nearest = StationPanelDetent.allCases.min { abs($0.height(in: height) - projected) < abs($1.height(in: height) - projected) } ?? detent
                setDetent(nearest)
            }
    }

    private var myLocationButton: some View {
        Button { location.request() } label: {
            HStack(spacing: 6) {
                if location.isLocating { ProgressView().controlSize(.small) }
                else { Image(systemName: "location") }
                Text("내 위치")
            }.frame(minHeight: 44).contentShape(Rectangle())
        }
        .foregroundStyle(AppTheme.action)
        .disabled(location.isLocating)
        .accessibilityIdentifier("my-location")
        .accessibilityValue(location.isLocating ? "위치 확인 중" : "")
    }

    private var stationMap: some View {
        NaverTransitMap(camera: position, pins: model.stations.compactMap { station in
            guard let lat = station.latitude, let lon = station.longitude else { return nil }
            return TransitMapPin(id: "station-pin.\(station.id)",
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                label: "\(station.name), 정류장 \(station.displayNumber)", title: station.name,
                enabled: !model.resolving, selected: selectedStationID == station.id,
                action: { selectedStationID = station.id; Task { await model.select(station) } })
        }, userLocation: location.coordinate, onMove: { region in
            model.region = region
            position.region = region
            mapMoved = true
        }, onCameraChange: { position.snapshot = $0 })
        .overlay(alignment: .top) {
            if mapMoved {
                Button("이 지역 다시 찾기", systemImage: "arrow.clockwise") { model.search(); mapMoved = false }
                    .buttonStyle(TransitMapButtonStyle()).padding(.horizontal, 8).padding(.top, 4)
            }
        }
    }
    private var stationList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GeometryReader { geometry in
                    Color.clear.preference(key: StationListOffsetKey.self, value: geometry.frame(in: .named("station-list")).minY)
                }.frame(height: 0)
                if model.loading || model.resolving {
                    ProgressView(model.resolving ? "정류장을 확인하는 중…" : "정류장을 찾는 중…").padding(20)
                }
                if let error = model.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.callout)
                        Button("다시 시도") { model.search() }.frame(minHeight: 44)
                    }.padding(.horizontal, 20)
                } else if !model.loading && model.stations.isEmpty {
                    TransitEmptyState(title: "정류장이 없습니다.", symbol: "magnifyingglass",
                        message: model.query.isEmpty ? "지도를 옮기거나 정류장 이름으로 검색해 주세요." : "다른 정류장 이름이나 번호로 검색해 주세요.")
                }
                if model.truncated { Text("정류장이 많습니다. 지도를 확대해 주세요.").font(.callout).padding(20) }
                LazyVStack(spacing: 0) {
                    ForEach(model.stations) { station in
                        Button { selectedStationID = station.id; Task { await model.select(station) } } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(station.name).font(.headline).foregroundStyle(AppTheme.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("정류장 \(station.displayNumber)").font(.subheadline).monospacedDigit()
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.secondaryText).accessibilityHidden(true)
                            }.frame(minHeight: 44).padding(.horizontal, 20).padding(.vertical, 12).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.resolving || dragOrigin != nil)
                         .accessibilityIdentifier("station-row.\(station.id)")
                         .background(selectedStationID == station.id ? AppTheme.selection : AppTheme.surface)
                        Divider().padding(.horizontal, 20)
                    }
                }
                if !model.stations.isEmpty {
                    Text("길 건너편 정류장과 번호를 구분해 주세요. 버스의 방면은 정류장을 선택한 뒤 확인할 수 있습니다.")
                        .font(.footnote).foregroundStyle(AppTheme.secondaryText).padding(20)
                }
            }
        }
        .coordinateSpace(name: "station-list")
        .modifier(StationListPositionObserver(atTop: $listAtTop))
        .accessibilityIdentifier("station-results")
        .background(AppTheme.surface)
    }
}

private enum StationPanelDetent: CaseIterable {
    case collapsed, medium, expanded
    var label: String {
        switch self { case .collapsed: "접힘"; case .medium: "중간"; case .expanded: "펼침" }
    }
    var next: Self {
        switch self { case .collapsed: .medium; case .medium: .expanded; case .expanded: .collapsed }
    }
    func height(in available: CGFloat) -> CGFloat {
        switch self {
        case .collapsed: min(148, available * 0.3)
        case .medium: max(min(148, available * 0.3), available * 0.4)
        case .expanded: available
        }
    }
}

private struct StationListOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

private struct StationListPositionObserver: ViewModifier {
    @Binding var atTop: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y <= geometry.contentInsets.top + 1
            } action: { _, value in atTop = value }
        } else {
            content.onPreferenceChange(StationListOffsetKey.self) { atTop = $0 >= -1 }
        }
    }
}
