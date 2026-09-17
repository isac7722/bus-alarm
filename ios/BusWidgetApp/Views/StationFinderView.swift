import SwiftUI
import MapKit

struct StationFinderView: View {
    var replacing: SavedStop? = nil
    @StateObject private var model = StationFinderViewModel()
    @StateObject private var location = StationLocationService()
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSize
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.978),
        span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)))
    @State private var listOnly = false
    @State private var mapMoved = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    if verticalSize == .compact {
                        Label("정류장 목록", systemImage: "list.bullet").foregroundStyle(.secondary)
                    } else {
                        Button(listOnly ? "지도로 보기" : "목록으로 보기", systemImage: listOnly ? "map" : "list.bullet") { listOnly.toggle() }
                    }
                    Spacer()
                    Button("내 위치", systemImage: "location") { location.request() }
                }.font(.callout).frame(minHeight: 44).padding(.horizontal)
                if let message = location.message { Text(message).font(.callout).padding(.horizontal) }
                if !listOnly && verticalSize != .compact && model.query.isEmpty {
                    stationMap.frame(minHeight: 160, maxHeight: .infinity)
                }
                stationList
                    .frame(maxHeight: listOnly || verticalSize == .compact || !model.query.isEmpty ? .infinity : 260)
            }
            .toolbar { if replacing != nil { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } } }
            .navigationTitle("정류장 찾기")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.query, prompt: "정류장 이름 또는 번호")
            .onChange(of: model.query) { _, _ in model.search() }
            .onChange(of: typeSize) { _, value in if value.isAccessibilitySize { listOnly = true } }
            .onChange(of: location.coordinate?.latitude) { _, _ in
                if let point = location.coordinate {
                    let area = MKCoordinateRegion(center: point, span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015))
                    model.region = area; position = .region(area); model.query = ""; model.search()
                }
            }
            .task {
                if typeSize.isAccessibilitySize { listOnly = true }
                if let replacing, let station = try? await APIClient().resolveStation(id: replacing.configuration.version == 1 ? replacing.configuration.stationId : replacing.configuration.stationId.hasPrefix("gg:") ? replacing.configuration.stationId : replacing.configuration.displayNumber ?? ""),
                   let lat = station.latitude, let lon = station.longitude {
                    let area = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015))
                    model.region = area; position = .region(area)
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

    private var stationMap: some View {
        Map(position: $position) {
            ForEach(model.stations) { station in
                if let lat = station.latitude, let lon = station.longitude {
                    Annotation(station.name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
                        Button { Task { await model.select(station) } } label: {
                            Image(systemName: "bus.fill").foregroundStyle(.white).padding(10)
                                .background(AppTheme.primary, in: Circle()).frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("\(station.name), 정류장 \(station.displayNumber)")
                        .accessibilityIdentifier("station-pin.\(station.id)")
                        .disabled(model.resolving)
                    }
                }
            }
        }
        .mapControls { MapCompass(); MapScaleView() }
        .onMapCameraChange(frequency: .onEnd) { context in model.region = context.region; mapMoved = true }
        .overlay(alignment: .top) {
            if mapMoved {
                Button("이 지역 다시 찾기", systemImage: "arrow.clockwise") { model.search(); mapMoved = false }
                    .buttonStyle(.borderedProminent).padding(8)
            }
        }
    }
    private var stationList: some View {
        List {
            if model.loading || model.resolving { ProgressView(model.resolving ? "정류장을 확인하는 중…" : "정류장을 찾는 중…") }
            if let error = model.error {
                Section {
                    Text(error).font(.callout)
                    Button("다시 시도") { model.search() }
                }
            } else if !model.loading && model.stations.isEmpty {
                ContentUnavailableView("정류장이 없습니다.", systemImage: "magnifyingglass",
                    description: Text(model.query.isEmpty ? "지도를 옮기거나 정류장 이름으로 검색해 주세요." : "다른 정류장 이름이나 번호로 검색해 주세요."))
            }
            if model.truncated { Text("정류장이 많습니다. 지도를 확대해 주세요.").font(.callout) }
            ForEach(model.stations) { station in
                Button { Task { await model.select(station) } } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(station.name).font(.headline).foregroundStyle(.primary)
                        Text("정류장 \(station.displayNumber)").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }.disabled(model.resolving).accessibilityIdentifier("station-row.\(station.id)")
            }
            if !model.stations.isEmpty {
                Text("길 건너편 정류장과 번호를 구분해 주세요. 버스의 방면은 정류장을 선택한 뒤 확인할 수 있습니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.listStyle(.plain)
    }
}
