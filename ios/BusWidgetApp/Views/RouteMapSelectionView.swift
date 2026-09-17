import SwiftUI
import MapKit
import WidgetKit

struct RouteMapSelectionView: View {
    @StateObject private var model: RouteMapViewModel
    @StateObject private var location = StationLocationService()
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var position: MapCameraPosition = .automatic
    @State private var showList = false
    @State private var sheetDetent: PresentationDetent = .height(340)
    let previous: WidgetConfigurationData?
    let onSave: (WidgetConfigurationData) -> Void

    init(route: CatalogRoute, previous: WidgetConfigurationData?, onSave: @escaping (WidgetConfigurationData) -> Void) {
        _model = StateObject(wrappedValue: RouteMapViewModel(route: route))
        self.previous = previous; self.onSave = onSave
    }
    var body: some View {
        VStack(spacing: 0) {
            if model.loading && model.detail == nil { ProgressView("노선을 불러오는 중…").frame(maxHeight: .infinity) }
            else if let error = model.error {
                ContentUnavailableView {
                    Label("노선을 불러오지 못했어요", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("다시 시도") { Task { await model.load() } }
                }
            } else if let detail = model.detail {
                directionHeader(detail)
                HStack {
                    Button(showList ? "지도로 보기" : "목록으로 보기", systemImage: showList ? "map" : "list.bullet") { showList.toggle() }
                    Spacer()
                    Button("노선 전체", systemImage: "arrow.up.left.and.arrow.down.right") { position = .automatic }
                    Button { location.request() } label: { Image(systemName: "location") }
                        .accessibilityLabel("내 위치").frame(minWidth: 44, minHeight: 44)
                }.font(.callout).padding(.horizontal)
                if let message = location.message { Text(message).font(.callout).foregroundStyle(.secondary).padding(.horizontal) }
                if showList { stopList }
                else { map }
            }
        }
        .navigationTitle("\(model.route.name) · 정류장 선택")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.detail == nil { await model.load() }; if typeSize.isAccessibilitySize { showList = true } }
        .onChange(of: typeSize) { _, value in if value.isAccessibilitySize { showList = true } }
        .onChange(of: location.coordinate?.latitude) { _, _ in
            if let coordinate = location.coordinate { position = .region(MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015))) }
        }
        .sheet(item: $model.selected) { stop in
            NavigationStack {
                StationSelectionSheet(sheetDetent: $sheetDetent, stop: stop, previous: previous, onSave: onSave)
            }
            .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(340), .large], selection: $sheetDetent)
            .onAppear { sheetDetent = typeSize.isAccessibilitySize ? .large : .height(340) }
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .height(340)))
        }
    }
    private func directionHeader(_ detail: CatalogDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("가는 방향").font(.caption).foregroundStyle(.secondary)
            Picker("가는 방향", selection: Binding(get: { model.directionId }, set: { model.changeDirection($0); position = .automatic })) {
                Text("방향을 선택하세요").tag("")
                ForEach(detail.directions) { direction in Text(direction.name).tag(direction.id) }
            }.pickerStyle(.menu).frame(minHeight: 44).accessibilityIdentifier("route-direction")
            if detail.directions.isEmpty {
                Text("운행 방향을 확인할 수 없어 이 노선은 아직 선택할 수 없습니다.").font(.callout)
            } else {
                Text(model.directionId.isEmpty ? "방향을 고른 뒤 정류장을 선택해 주세요." : "탈 위치를 누르고 다음 정류장을 확인하세요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding()
    }
    private var visibleCoordinates: [CLLocationCoordinate2D] {
        model.stops.compactMap { stop in
            guard let latitude = stop.station.latitude, let longitude = stop.station.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }
    private var map: some View {
        Map(position: $position) {
            if let geometry = model.geometry, geometry.source == "provider", model.directionId.isEmpty {
                MapPolyline(coordinates: geometry.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                    .stroke(.blue.opacity(0.65), lineWidth: 4)
            }
            if !model.directionId.isEmpty, visibleCoordinates.count > 1 {
                MapPolyline(coordinates: visibleCoordinates)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 3, dash: [6, 5]))
                if let first = visibleCoordinates.first, let second = visibleCoordinates.dropFirst().first {
                    Annotation("진행 방향", coordinate: CLLocationCoordinate2D(latitude: (first.latitude + second.latitude) / 2, longitude: (first.longitude + second.longitude) / 2)) {
                        Image(systemName: "arrowtriangle.up.fill").foregroundStyle(.blue)
                            .rotationEffect(.radians(atan2((second.longitude - first.longitude) * cos(first.latitude * .pi / 180), second.latitude - first.latitude)))
                            .accessibilityHidden(true)
                    }
                }
            }
            ForEach(model.stops) { stop in
                if let lat = stop.station.latitude, let lon = stop.station.longitude {
                    Annotation(stop.station.name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
                        Button {
                            if model.stops.filter({ $0.stationRef == stop.stationRef }).count > 1 {
                                showList = true
                                return
                            }
                            model.select(stop)
                            position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)))
                        } label: {
                            Image(systemName: model.selected?.id == stop.id ? "checkmark.circle.fill" : "bus.fill")
                                .font(.headline).foregroundStyle(.white)
                                .padding(10).background(AppTheme.primary, in: Circle())
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .disabled(model.directionId.isEmpty || !stop.selectable)
                        .accessibilityLabel("\(stop.station.name), \(stop.station.displayNumber), \(stop.direction), 순번 \(stop.sequence)")
                        .accessibilityIdentifier("route-pin.\(stop.id)")
                    }
                }
            }
        }
        .mapControls { MapCompass(); MapScaleView() }
        .safeAreaInset(edge: .bottom) {
            Text("서울특별시·경기도 제공 · 점선은 실제 도로가 아닌 정류장 연결선입니다.")
                .font(.caption).padding(10).frame(maxWidth: .infinity).background(.regularMaterial)
        }
    }
    private var stopList: some View {
        List(model.stops) { stop in
            Button { model.select(stop) } label: {
                HStack(spacing: 16) {
                    Text(String(stop.sequence)).monospacedDigit().foregroundStyle(AppTheme.primary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(stop.station.name).font(.headline).foregroundStyle(.primary)
                        Text("\(stop.station.displayNumber) · \(stop.direction)").font(.subheadline).foregroundStyle(.secondary)
                        if let reason = stop.reason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                    }
                }.padding(.vertical, 8)
            }.disabled(model.directionId.isEmpty || !stop.selectable)
             .accessibilityIdentifier("route-stop.\(stop.id)")
        }.listStyle(.plain)
    }
}

private struct StationSelectionSheet: View {
    @Binding var sheetDetent: PresentationDetent
    let stop: RouteStopOccurrence
    let previous: WidgetConfigurationData?
    let onSave: (WidgetConfigurationData) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("선택한 정류장").font(.subheadline).foregroundStyle(AppTheme.primary)
                Text(stop.station.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                Text("\(stop.station.displayNumber) · \(stop.direction)").foregroundStyle(.secondary)
                Divider()
                Label(stop.nextStop.isEmpty ? "이 방향의 마지막 정류장" : "다음: \(stop.nextStop)", systemImage: "arrow.right")
                NavigationLink {
                    BoardingReviewView(station: stop.station, initial: stop.selection, previous: previous, onSave: onSave)
                        .onAppear { sheetDetent = .large }
                } label: {
                    Text("이 정류장에서 탈게요").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent)
            }.padding(24)
        }.navigationBarTitleDisplayMode(.inline)
    }
}

struct BoardingReviewView: View {
    @StateObject private var model: BoardingReviewViewModel
    let previous: WidgetConfigurationData?
    let onSave: (WidgetConfigurationData) -> Void
    init(station: MapStation, initial: BoardingSelection?, previous: WidgetConfigurationData?, onSave: @escaping (WidgetConfigurationData) -> Void) {
        _model = StateObject(wrappedValue: BoardingReviewViewModel(station: station, initial: initial))
        self.previous = previous; self.onSave = onSave
    }
    var body: some View {
        List {
            Section {
                Text(model.station.name).font(.title2.bold())
                Text(model.station.displayNumber).foregroundStyle(.secondary)
            }
            Section("선택한 버스 · \(model.selections.count)/4") {
                ForEach(model.selections) { selection in
                    Label("\(selection.routeName) · \(selection.direction)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.primary)
                }
                if model.selections.isEmpty { Text("버스와 가는 방향을 선택해 주세요.").foregroundStyle(.secondary) }
            }
            Section("이 정류장의 버스") {
                if model.loading { ProgressView("경유 노선을 확인하는 중…") }
                if let message = model.error ?? model.warning {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                    Button("목록 다시 불러오기") { Task { await model.load() } }
                }
                ForEach(model.options) { stop in
                    Button { model.toggle(stop) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: model.selections.contains(where: { $0.id == stop.id }) ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: 6) {
                                Text(stop.routeName).font(.headline)
                                Text(stop.direction).font(.subheadline)
                                Text(stop.reason ?? (stop.nextStop.isEmpty ? "마지막 정류장" : "다음: \(stop.nextStop)"))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.disabled(stop))
                    .accessibilityAddTraits(model.selections.contains(where: { $0.id == stop.id }) ? .isSelected : [])
                }
            }
            if let previous {
                Section { Text("기존 ‘\(previous.stationName)’ 위젯 설정을 이 설정으로 바꿉니다.").font(.callout).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("위젯 설정 확인")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                Task {
                    if let configuration = await model.save() {
                        WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind)
                        onSave(configuration)
                    }
                }
            } label: {
                Group { if model.saving { ProgressView("저장 중…") } else { Text("위젯에 저장") } }
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent).disabled(!model.canSave)
            .padding().background(.regularMaterial)
        }
        .task { if model.options.isEmpty { await model.load() } }
    }
}
