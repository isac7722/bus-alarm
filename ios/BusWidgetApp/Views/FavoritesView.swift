import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var favorites: FavoritesStore
    @State private var showPrivacy = false
    let findStation: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if !favorites.items.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("저장한 정류장 \(favorites.items.count)개")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.text)
                            Text("정류장을 고른 뒤 오늘 기다릴 버스를 선택하세요.")
                                .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                    if let error = favorites.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error)
                            Button("다시 시도") {
                                favorites.reload()
                                Task { await favorites.hydrateLegacyNames() }
                            }.frame(minHeight: 44).foregroundStyle(AppTheme.action)
                        }
                    }
                    if favorites.items.isEmpty && favorites.error == nil {
                        TransitEmptyState(title: "저장한 정류장이 없습니다", symbol: "bookmark",
                            message: "자주 타는 정류장과 버스를 저장하면\n다음에는 바로 기다릴 수 있어요.")
                    }
                    ForEach(favorites.items) { favorite in
                        FavoriteCard(favorite: favorite)
                    }
                    Button(action: findStation) {
                        Label("자주 타는 정류장 추가", systemImage: "plus")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TransitButtonStyle(prominent: favorites.items.isEmpty))
                    .accessibilityIdentifier("favorite-add-station")
                }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            }
            .background(AppTheme.background).foregroundStyle(AppTheme.text)
            .tint(AppTheme.action)
            .navigationTitle("즐겨찾기")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("개인정보처리방침") { showPrivacy = true }
                    } label: { Label("더보기", systemImage: "ellipsis") }
                }
            }
            .sheet(isPresented: $showPrivacy) { PrivacyPolicyView() }
            .task { await favorites.hydrateLegacyNames() }
        }
    }
}

private struct FavoriteCard: View {
    @EnvironmentObject private var favorites: FavoritesStore
    let favorite: SavedStop

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if !favorite.nickname.isEmpty {
                    Text(favorite.nickname).font(.subheadline.weight(.medium)).foregroundStyle(AppTheme.secondaryText)
                }
                Text(favorite.configuration.stationName).font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let number = favorite.displayNumber {
                    Text("정류장 \(number)").font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                }
                if !favorite.directions.isEmpty {
                    Text(favorite.directions.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            RouteBadgeLayout {
                ForEach(favorite.displayRoutes) { route in
                    Text(route.routeName)
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .foregroundStyle(AppTheme.text)
                        .background(AppTheme.background, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("\(route.routeName)번 버스")
                }
            }
            if favorite.hasMissingRouteNames {
                if favorites.loadingNames.contains(favorite.id) {
                    ProgressView("버스 번호 확인 중…").font(.subheadline)
                } else {
                    Button("버스 번호 다시 확인") {
                        Task { await favorites.hydrateLegacyNames() }
                    }.font(.subheadline).frame(minHeight: 44).foregroundStyle(AppTheme.action)
                    Text("저장한 버스 정보를 불러오지 못했어요.")
                        .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                }
            }
            NavigationLink {
                FavoriteDetailView(favorite: favorite)
            } label: {
                Text("버스 기다리기").frame(maxWidth: .infinity)
            }
            .buttonStyle(TransitButtonStyle(prominent: false))
            .accessibilityLabel("\(favorite.configuration.stationName)에서 버스 기다리기")
            .accessibilityHint("오늘 기다릴 버스를 고르고 도착 정보를 확인합니다.")
            .accessibilityIdentifier("favorite.\(favorite.id)")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transitCard()
    }
}

// Wrap badges at their natural width, including at accessibility text sizes.
private struct RouteBadgeLayout: Layout {
    private func positions(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + 8; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + 8
            rowHeight = max(rowHeight, size.height)
        }
        return (points, CGSize(width: usedWidth, height: y + rowHeight))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(subviews, width: proposal.width ?? .infinity).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = positions(subviews, width: bounds.width)
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + layout.points[index].x, y: bounds.minY + layout.points[index].y),
                       proposal: ProposedViewSize(width: bounds.width, height: nil))
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
    @State private var didStart = false
    @State private var routeError: String?
    @State private var showWaiting = false

    init(favorite: SavedStop, autoStart: Bool = false) {
        self.favorite = favorite; self.autoStart = autoStart
        _selected = State(initialValue: Set(favorite.configuration.routeIds))
        _routes = State(initialValue: favorite.displayRoutes)
    }
    private var stored: SavedStop? {
        favorites.items.first { $0.id == favorite.id } ?? favorites.items.first { $0.combinationID == favorite.combinationID }
    }
    private var value: SavedStop { stored ?? favorite }
    private var configuration: WidgetConfigurationData { value.configuration }

    var body: some View {
        List {
            Section {
                StationSummaryView(name: configuration.stationName,
                    number: configuration.displayNumber ?? configuration.stationId, nickname: value.nickname)
            }.listRowBackground(AppTheme.surface)
            Section("오늘 기다릴 버스 · \(selected.count)개") {
                if let routeError { Text(routeError); Button("다시 시도") { Task { await loadRoutes() } }.foregroundStyle(AppTheme.action) }
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    let fastest = routes.filter { selected.contains($0.routeId) }.compactMap { route -> (String, Date)? in
                        arrivals.upcoming(route.routeId, at: context.date).map { (route.routeId, $0) }
                    }.min { $0.1 < $1.1 }?.0
                    ForEach(routes) { route in
                        Button {
                            if selected.contains(route.routeId) { selected.remove(route.routeId) } else { selected.insert(route.routeId) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 12) {
                                        routeSelectionLabel(route)
                                        Spacer(minLength: 8)
                                        Text(arrivals.label(route.routeId, at: context.date)).monospacedDigit()
                                            .font(.body.weight(.medium)).fixedSize()
                                    }
                                    VStack(alignment: .leading, spacing: 8) {
                                        routeSelectionLabel(route)
                                        Text(arrivals.label(route.routeId, at: context.date)).monospacedDigit()
                                            .font(.body.weight(.medium))
                                    }
                                }
                                if let direction = configuration.selections?.first(where: { $0.routeRef == route.routeId })?.direction {
                                    Text(direction).font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                                }
                                if fastest == route.routeId { Label("선택한 버스 중 가장 먼저 도착", systemImage: "timer").font(.caption).foregroundStyle(AppTheme.primary) }
                            }.padding(.vertical, 6).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(waiting.isBusy)
                         .accessibilityIdentifier("waiting-route.\(route.routeId)")
                         .accessibilityAddTraits(selected.contains(route.routeId) ? .isSelected : [])
                         .accessibilityValue(selected.contains(route.routeId) ? "선택됨" : "선택 안 됨")
                    }
                }
                Text("오늘의 선택은 즐겨찾기에 저장된 버스를 바꾸지 않습니다.").font(.footnote).foregroundStyle(AppTheme.secondaryText)
                if let response = arrivals.response {
                    Text("마지막 확인 \(response.updatedAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
                if let error = arrivals.error { Text(error).font(.callout); Button("도착정보 다시 확인") { Task { await arrivals.refresh(configuration) } }.foregroundStyle(AppTheme.action) }
            }.listRowBackground(AppTheme.surface)
            Section {
                if waiting.activity != nil {
                    Button("현재 대기 보기", systemImage: "bus.fill") { showWaiting = true }
                        .foregroundStyle(AppTheme.action)
                    Text("다른 조합을 기다리려면 현재 대기를 먼저 종료해 주세요.").font(.footnote).foregroundStyle(AppTheme.secondaryText)
                }
                if let error = waiting.errorMessage { Text(error).font(.callout).foregroundStyle(AppTheme.secondaryText) }
                Button {
                    var current = value; current.routes = routes
                    _ = favorites.save(current)
                } label: { Label(stored == nil ? "이 조합 즐겨찾기" : "즐겨찾기에 저장됨", systemImage: stored == nil ? "bookmark" : "bookmark.fill") }
                    .foregroundStyle(AppTheme.action).disabled(stored != nil).accessibilityIdentifier("detail-save-favorite")
                if stored != nil {
                    Button("정류장·버스 변경", systemImage: "pencil") { edit = true }.foregroundStyle(AppTheme.action)
                }
                if let error = favorites.error { Text(error); Button("저장 상태 다시 확인") { favorites.reload() }.foregroundStyle(AppTheme.action) }
            }.listRowBackground(AppTheme.surface)
        }
        .transitList()
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
                }.frame(maxWidth: .infinity)
            }.buttonStyle(TransitButtonStyle()).disabled(selected.isEmpty || routes.isEmpty || waiting.isBusy || waiting.activity != nil)
             .transitActionBar().accessibilityIdentifier("waiting-start")
        }
        .alert("즐겨찾기 이름", isPresented: $rename) {
            TextField("퇴근길, 학교에서 집", text: $name)
            Button("저장") { var current = value; current.nickname = name.trimmingCharacters(in: .whitespacesAndNewlines); favorites.save(current) }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog("즐겨찾기를 삭제할까요?", isPresented: $delete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { favorites.delete(value); if favorites.error == nil { dismiss() } }
        } message: { Text("현재 대기는 유지됩니다.") }
        .sheet(isPresented: $edit) { StationFinderView(replacing: value) }
        .sheet(isPresented: $showWaiting) { NavigationStack { ActiveCommuteView() } }
        .onChange(of: configuration.cacheIdentity) { _, _ in
            selected = Set(configuration.routeIds); routes = value.displayRoutes
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
    private func routeSelectionLabel(_ route: RouteSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selected.contains(route.routeId) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(AppTheme.action).accessibilityHidden(true)
            Text(route.routeName).font(.headline).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadRoutes() async {
        routeError = nil
        if !value.hasMissingRouteNames { routes = value.displayRoutes; return }
        let requested = value
        do {
            let result = try await APIClient().stationDetail(stationId: requested.configuration.stationId)
            guard !Task.isCancelled, configuration == requested.configuration else { return }
            routes = result.routes.filter { configuration.routeIds.contains($0.routeId) }
            if !routes.isEmpty { favorites.updateRouteNames(routes, for: requested) }
            if routes.isEmpty { routeError = "저장한 버스를 확인할 수 없습니다. 정류장·버스를 다시 선택해 주세요." }
        } catch {
            guard !Task.isCancelled, configuration == requested.configuration else { return }
            routeError = error.localizedDescription
        }
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
                TransitEmptyState(title: "대기가 종료되었습니다", symbol: "checkmark.circle",
                    message: "즐겨찾기에서 다시 기다릴 수 있습니다.")
            }
        }.background(AppTheme.background).foregroundStyle(AppTheme.text).tint(AppTheme.action)
         .navigationTitle("지금 기다리는 버스").navigationBarTitleDisplayMode(.inline)
         .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
    }
}
