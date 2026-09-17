import SwiftUI
import MapKit

struct StationFinderView: View {
    var replacing: SavedStop? = nil
    @StateObject private var model = StationFinderViewModel()
    @StateObject private var location = StationLocationService()
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSize
    @Environment(\.dismiss) private var dismiss
    @State private var position = TransitMapCamera(region: MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.978),
        span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)))
    @State private var listOnly = false
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
                if !listOnly && verticalSize != .compact && model.query.isEmpty {
                    stationMap.frame(minHeight: 160, maxHeight: .infinity)
                }
                stationList
                    .frame(maxHeight: listOnly || verticalSize == .compact || !model.query.isEmpty ? .infinity : 260)
            }.background(AppTheme.background).foregroundStyle(AppTheme.text).tint(AppTheme.action)
            .toolbar { if replacing != nil { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } } }
            .navigationTitle("정류장 찾기")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.query, prompt: "정류장 이름 또는 번호")
            .onChange(of: model.query) { _, _ in model.search() }
            .onChange(of: typeSize) { _, value in if value.isAccessibilitySize { listOnly = true } }
            .onChange(of: location.updateID) { _, _ in
                if let point = location.coordinate {
                    let area = TransitMapCamera.locationRegion(center: point)
                    model.region = area; position = TransitMapCamera(region: area); model.query = ""
                    if !typeSize.isAccessibilitySize { listOnly = false }
                    model.search()
                }
            }
            .task {
                if typeSize.isAccessibilitySize { listOnly = true }
                if let replacing, let station = try? await APIClient().resolveStation(id: replacing.configuration.version == 1 ? replacing.configuration.stationId : replacing.configuration.stationId.hasPrefix("gg:") ? replacing.configuration.stationId : replacing.configuration.displayNumber ?? ""),
                   let lat = station.latitude, let lon = station.longitude {
                    let area = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015))
                    model.region = area; position = TransitMapCamera(region: area)
                }
                model.search()
            }
            .onDisappear { model.cancel() }
            .sheet(item: $model.selected) { station in
                NavigationStack { StationBusSelectionView(station: station, favorite: replacing) }
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
        if verticalSize == .compact {
            Label("정류장 목록", systemImage: "list.bullet").foregroundStyle(AppTheme.secondaryText)
        } else {
            Button { listOnly.toggle() } label: {
                Label(listOnly ? "지도로 보기" : "목록으로 보기", systemImage: listOnly ? "map" : "list.bullet")
                    .frame(minHeight: 44).contentShape(Rectangle())
            }.foregroundStyle(AppTheme.action)
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
        List {
            if model.loading || model.resolving { ProgressView(model.resolving ? "정류장을 확인하는 중…" : "정류장을 찾는 중…") }
            if let error = model.error {
                Section {
                    Text(error).font(.callout)
                    Button("다시 시도") { model.search() }.foregroundStyle(AppTheme.action)
                }
            } else if !model.loading && model.stations.isEmpty {
                TransitEmptyState(title: "정류장이 없습니다.", symbol: "magnifyingglass",
                    message: model.query.isEmpty ? "지도를 옮기거나 정류장 이름으로 검색해 주세요." : "다른 정류장 이름이나 번호로 검색해 주세요.")
                    .listRowSeparator(.hidden).listRowBackground(AppTheme.surface)
            }
            if model.truncated { Text("정류장이 많습니다. 지도를 확대해 주세요.").font(.callout) }
            if !model.stations.isEmpty {
                Section {
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
                            }.frame(minHeight: 44).padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.resolving)
                         .accessibilityIdentifier("station-row.\(station.id)")
                         .listRowBackground(selectedStationID == station.id ? AppTheme.selection : AppTheme.surface)
                    }
                } header: {
                    Text("\(model.query.isEmpty ? "주변 정류장" : "검색 결과") · \(model.stations.count)개")
                        .font(.subheadline.weight(.medium)).foregroundStyle(AppTheme.secondaryText)
                        .textCase(nil)
                }
            }
            if !model.stations.isEmpty {
                Text("길 건너편 정류장과 번호를 구분해 주세요. 버스의 방면은 정류장을 선택한 뒤 확인할 수 있습니다.")
                    .font(.footnote).foregroundStyle(AppTheme.secondaryText)
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(AppTheme.surface)
    }
}
