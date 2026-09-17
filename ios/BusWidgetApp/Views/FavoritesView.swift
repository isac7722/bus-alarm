import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var favorites: FavoritesStore
    let findStation: () -> Void
    var body: some View {
        NavigationStack {
            List {
                if let error = favorites.error {
                    Section { Text(error); Button("다시 시도") { favorites.reload() } }
                }
                if favorites.items.isEmpty && favorites.error == nil {
                    ContentUnavailableView {
                        Label("자주 타는 정류장을 저장해 보세요", systemImage: "star")
                    } description: {
                        Text("정류장과 탈 수 있는 버스들을 함께 저장하면 다음에는 바로 기다릴 수 있어요.")
                    } actions: {
                        Button("지도에서 정류장 찾기", action: findStation).buttonStyle(.borderedProminent)
                    }
                }
                ForEach(favorites.items) { favorite in
                    Section {
                        NavigationLink {
                            FavoriteDetailView(favorite: favorite)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                if !favorite.nickname.isEmpty { Text(favorite.nickname).font(.subheadline).foregroundStyle(.secondary) }
                                Text(favorite.configuration.stationName).font(.title3.bold())
                                if let number = favorite.configuration.displayNumber { Text("정류장 \(number)").font(.subheadline).foregroundStyle(.secondary) }
                                Text(favorite.routeDescription).font(.headline).foregroundStyle(AppTheme.primary)
                                if favorites.isPinned(favorite) { Label("위젯에 표시 중", systemImage: "square.grid.2x2").font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 8)
                        }.accessibilityIdentifier("favorite.\(favorite.id)")
                        NavigationLink {
                            FavoriteDetailView(favorite: favorite, autoStart: true)
                        } label: { Label("기다리기", systemImage: "play.fill").frame(minHeight: 44) }
                    }
                }
            }
            .navigationTitle("즐겨찾기")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("정류장 추가", systemImage: "plus", action: findStation) }
                ToolbarItem(placement: .topBarLeading) { PrivacyPolicyButton() }
            }
            .task { await favorites.hydrateLegacyNames() }
        }
    }
}

struct FavoriteDetailView: View {
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var waiting: BusWaitingManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var arrivals = CommuteArrivalsModel()
    let favorite: SavedStop
    var autoStart = false
    @State private var selected: Set<String>
    @State private var routes: [RouteSummary]
    @State private var edit = false
    @State private var rename = false
    @State private var name = ""
    @State private var delete = false
    @State private var widgetNotice = false
    @State private var didStart = false
    @State private var routeError: String?
    @State private var showWaiting = false

    init(favorite: SavedStop, autoStart: Bool = false) {
        self.favorite = favorite; self.autoStart = autoStart
        _selected = State(initialValue: Set(favorite.configuration.routeIds))
        _routes = State(initialValue: favorite.routes)
    }
    private var stored: SavedStop? {
        favorites.items.first { $0.id == favorite.id } ?? favorites.items.first { $0.combinationID == favorite.combinationID }
    }
    private var value: SavedStop { stored ?? favorite }
    private var configuration: WidgetConfigurationData { value.configuration }

    var body: some View {
        List {
            Section {
                if !value.nickname.isEmpty { Text(value.nickname).font(.subheadline).foregroundStyle(.secondary) }
                Text(configuration.stationName).font(.title2.bold())
                Text("정류장 \(configuration.displayNumber ?? configuration.stationId)").foregroundStyle(.secondary)
            }
            Section("오늘 기다릴 버스 · \(selected.count)개") {
                if let routeError { Text(routeError); Button("다시 시도") { Task { await loadRoutes() } } }
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    let fastest = routes.filter { selected.contains($0.routeId) }.compactMap { route -> (String, Date)? in
                        arrivals.upcoming(route.routeId, at: context.date).map { (route.routeId, $0) }
                    }.min { $0.1 < $1.1 }?.0
                    ForEach(routes) { route in
                        Button {
                            if selected.contains(route.routeId) { selected.remove(route.routeId) } else { selected.insert(route.routeId) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: selected.contains(route.routeId) ? "checkmark.circle.fill" : "circle").foregroundStyle(AppTheme.primary)
                                    Text(route.routeName).font(.headline)
                                    Spacer(minLength: 8)
                                    Text(arrivals.label(route.routeId, at: context.date)).monospacedDigit()
                                }
                                if let direction = configuration.selections?.first(where: { $0.routeRef == route.routeId })?.direction {
                                    Text(direction).font(.subheadline).foregroundStyle(.secondary)
                                }
                                if fastest == route.routeId { Label("선택한 버스 중 가장 먼저 도착", systemImage: "timer").font(.caption).foregroundStyle(AppTheme.primary) }
                            }.padding(.vertical, 6).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(waiting.isBusy)
                         .accessibilityIdentifier("waiting-route.\(route.routeId)")
                         .accessibilityAddTraits(selected.contains(route.routeId) ? .isSelected : [])
                    }
                }
                Text("오늘의 선택은 즐겨찾기에 저장된 버스를 바꾸지 않습니다.").font(.footnote).foregroundStyle(.secondary)
                if let response = arrivals.response {
                    Text("마지막 확인 \(response.updatedAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
                if let error = arrivals.error { Text(error).font(.callout); Button("도착정보 다시 확인") { Task { await arrivals.refresh(configuration) } } }
            }
            Section {
                if waiting.activity != nil {
                    Button("현재 대기 보기", systemImage: "bus.fill") { showWaiting = true }
                    Text("다른 조합을 기다리려면 현재 대기를 먼저 종료해 주세요.").font(.footnote).foregroundStyle(.secondary)
                }
                if let error = waiting.errorMessage { Text(error).font(.callout).foregroundStyle(.secondary) }
                Button {
                    var current = value; current.routes = routes
                    _ = favorites.save(current)
                } label: { Label(stored == nil ? "이 조합 즐겨찾기" : "즐겨찾기에 저장됨", systemImage: stored == nil ? "star" : "star.fill") }
                    .disabled(stored != nil).accessibilityIdentifier("detail-save-favorite")
                if stored != nil {
                    Button("정류장·버스 변경", systemImage: "pencil") { edit = true }
                    Button(favorites.isPinned(value) ? "위젯에 표시 중" : "위젯에 표시", systemImage: "square.grid.2x2") {
                        favorites.pin(value); widgetNotice = favorites.error == nil
                    }
                }
                if let error = favorites.error { Text(error); Button("저장 상태 다시 확인") { favorites.reload() } }
            }
        }
        .navigationTitle("버스 기다리기")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if stored != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("이름 변경") { name = value.nickname; rename = true }
                        Button("즐겨찾기 삭제", role: .destructive) { delete = true }
                    } label: { Label("즐겨찾기 관리", systemImage: "ellipsis.circle") }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { Task { await start() } } label: {
                Group {
                    if waiting.isBusy { ProgressView("대기 시작 중…") }
                    else { Text(selected.isEmpty ? "기다릴 버스를 선택하세요" : "\(selected.count)개 버스 기다리기") }
                }.frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || routes.isEmpty || waiting.isBusy || waiting.activity != nil)
             .padding().background(.regularMaterial).accessibilityIdentifier("waiting-start")
        }
        .alert("즐겨찾기 이름", isPresented: $rename) {
            TextField("퇴근길, 학교에서 집", text: $name)
            Button("저장") { var current = value; current.nickname = name.trimmingCharacters(in: .whitespacesAndNewlines); favorites.save(current) }
            Button("취소", role: .cancel) {}
        }
        .alert("위젯에 표시할 정류장을 저장했습니다", isPresented: $widgetNotice) {
            Button("확인", role: .cancel) {}
        } message: { Text("홈 화면에 버스 위젯을 추가하면 이 조합이 표시됩니다. 지금 기다리는 버스는 바뀌지 않습니다.") }
        .confirmationDialog("즐겨찾기를 삭제할까요?", isPresented: $delete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { favorites.delete(value); if favorites.error == nil { dismiss() } }
        } message: { Text(favorites.isPinned(value) ? "이 조합의 위젯 표시도 해제됩니다. 현재 대기는 유지됩니다." : "현재 대기는 유지됩니다.") }
        .sheet(isPresented: $edit) { StationFinderView(replacing: value) }
        .sheet(isPresented: $showWaiting) { NavigationStack { ActiveCommuteView() } }
        .onChange(of: configuration.cacheIdentity) { _, _ in
            selected = Set(configuration.routeIds); routes = value.routes
        }
        .task(id: configuration.cacheIdentity) {
            await loadRoutes()
            if autoStart && !didStart { didStart = true; await start() }
            while !Task.isCancelled {
                if scenePhase == .active { await arrivals.refresh(configuration) }
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }
    private func loadRoutes() async {
        routeError = nil
        if !value.routes.isEmpty { routes = value.routes; return }
        do {
            let result = try await APIClient().stationDetail(stationId: configuration.stationId)
            routes = result.routes.filter { configuration.routeIds.contains($0.routeId) }
            if routes.isEmpty { routeError = "저장한 버스를 확인할 수 없습니다. 정류장·버스를 다시 선택해 주세요." }
        } catch { routeError = error.localizedDescription }
    }
    private func start() async {
        await waiting.start(configuration: configuration.selecting(selected), routes: routes.filter { selected.contains($0.routeId) })
        if waiting.activity != nil { showWaiting = true }
    }
}

struct ActiveCommuteView: View {
    @EnvironmentObject private var waiting: BusWaitingManager
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            if let activity = waiting.activity {
                let attributes = activity.attributes
                BusWaitingView(configuration: WidgetConfigurationData(stationId: attributes.stationId, stationName: attributes.stationName, routeIds: attributes.selectedRoutes.map(\.routeId)))
                    .padding()
            } else {
                ContentUnavailableView("대기가 종료되었습니다", systemImage: "checkmark.circle", description: Text("즐겨찾기에서 다시 기다릴 수 있습니다."))
            }
        }.navigationTitle("지금 기다리는 버스").navigationBarTitleDisplayMode(.inline)
         .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
    }
}
