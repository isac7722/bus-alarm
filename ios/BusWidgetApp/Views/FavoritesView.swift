import SwiftUI

private struct FavoriteDestination: Hashable {
    let favorite: SavedStop
    var autoStart = false
}

struct FavoritesView: View {
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPrivacy = false
    @State private var path: [FavoriteDestination] = []
    let findStation: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                List {
                    if !favorites.items.isEmpty {
                        Text("저장한 정류장 \(favorites.items.count)개")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.secondaryText)
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    if let error = favorites.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error)
                            Button("다시 시도") {
                                favorites.reload()
                                Task { await favorites.hydrateLegacyNames() }
                            }.frame(minHeight: 44)
                        }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    if favorites.items.isEmpty && favorites.error == nil {
                        TransitEmptyState(title: "저장한 정류장이 없습니다", symbol: "bookmark",
                            message: "자주 타는 정류장과 버스를 저장하면\n다음에는 바로 기다릴 수 있어요.")
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    ForEach(favorites.items) { favorite in
                        FavoriteCard(favorite: favorite,
                            highlighted: favorites.saveNotice?.favoriteID == favorite.id,
                            refreshEnabled: path.isEmpty,
                            showDetail: { path.append(FavoriteDestination(favorite: favorite)) },
                            start: { path.append(FavoriteDestination(favorite: favorite, autoStart: true)) })
                            .id(favorite.id)
                            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { favorites.delete(favorite) } label: { Label("삭제", systemImage: "trash") }
                                    .tint(.red).accessibilityIdentifier("favorite-delete.\(favorite.id)")
                            }
                    }
                    Button(action: findStation) {
                        Label("자주 타는 정류장 추가", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TransitButtonStyle(prominent: favorites.items.isEmpty))
                    .accessibilityIdentifier("favorite-add-station")
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .task(id: favorites.saveNotice?.id) {
                    guard let notice = favorites.saveNotice else { return }
                    await Task.yield()
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        proxy.scrollTo(notice.favoriteID, anchor: .top)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if favorites.deletedFavorite != nil {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            Text("즐겨찾기를 삭제했어요").fixedSize()
                            Spacer(minLength: 0)
                            undoButton.fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("즐겨찾기를 삭제했어요")
                            undoButton
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.subheadline).padding(.horizontal, 20).background(AppTheme.selection)
                } else if favorites.saveNotice != nil {
                    Label("즐겨찾기에 저장했어요", systemImage: "checkmark.circle")
                        .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                        .background(AppTheme.selection).accessibilityIdentifier("favorite-save-notice")
                }
            }
            .background(AppTheme.background).foregroundStyle(AppTheme.text).tint(AppTheme.action)
            .navigationTitle("즐겨찾기")
            .navigationDestination(for: FavoriteDestination.self) { destination in
                FavoriteDetailView(favorite: destination.favorite, autoStart: destination.autoStart)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu { Button("개인정보처리방침") { showPrivacy = true } }
                    label: { Label("더보기", systemImage: "ellipsis") }
                }
            }
            .sheet(isPresented: $showPrivacy) { PrivacyPolicyView() }
            .task { await favorites.hydrateLegacyNames() }
        }
        .onChange(of: favorites.saveNotice?.id) { _, notice in
            if notice != nil { path.removeAll() }
        }
    }
    private var undoButton: some View {
        Button("실행 취소") { favorites.undoDelete() }
            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            .accessibilityIdentifier("favorite-undo-delete")
    }
}

private struct FavoriteCard: View {
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var waiting: BusWaitingManager
    let favorite: SavedStop
    @StateObject private var arrivals = CommuteArrivalsModel()
    @State private var visible = false
    let highlighted: Bool
    let refreshEnabled: Bool
    let showDetail: () -> Void
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: showDetail) {
                VStack(alignment: .leading, spacing: 6) {
                    if !favorite.nickname.isEmpty {
                        Text(favorite.nickname).font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                    }
                    Text(favorite.configuration.stationName).font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.text).fixedSize(horizontal: false, vertical: true)
                    if let number = favorite.displayNumber {
                        Text("정류장 \(number)").font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                    }
                    if !favorite.directions.isEmpty {
                        Text(favorite.directions.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    RouteBadgeLayout {
                        ForEach(favorite.displayRoutes) { route in
                            Text(route.routeName).font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .foregroundStyle(AppTheme.text)
                                .background(AppTheme.background, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }.padding(.top, 4)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
             .accessibilityIdentifier("favorite.\(favorite.id)")
             .accessibilityHint("등록된 버스의 도착정보를 확인하고 전체 대기를 시작할 수 있습니다.")
            if favorite.hasMissingRouteNames {
                if favorites.loadingNames.contains(favorite.id) {
                    ProgressView("버스 번호 확인 중…").font(.subheadline)
                } else {
                    Button("버스 번호 다시 확인") { Task { await favorites.hydrateLegacyNames() } }
                        .font(.subheadline).frame(minHeight: 44)
                    Text("저장한 버스 정보를 불러오지 못했어요.").font(.footnote).foregroundStyle(AppTheme.secondaryText)
                }
            }
            Button(action: start) { Text("바로 기다리기").frame(maxWidth: .infinity) }
                .buttonStyle(TransitButtonStyle(prominent: false))
                .disabled(waiting.isBusy || waiting.activity != nil || favorite.hasMissingRouteNames)
                .accessibilityLabel("\(favorite.configuration.stationName)에서 바로 기다리기")
                .accessibilityHint("저장한 \(favorite.configuration.routeIds.count)개 버스 전체로 대기를 시작합니다.")
                .accessibilityIdentifier("favorite-start.\(favorite.id)")
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).transitCard()
        .overlay(RoundedRectangle(cornerRadius: AppTheme.cardRadius)
            .strokeBorder(highlighted ? AppTheme.action : Color.clear, lineWidth: 2))
        .onAppear { visible = true }.onDisappear { visible = false }
        .arrivalPolling(arrivals, configuration: favorite.configuration, visible: visible && refreshEnabled)
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
    @State private var routes: [RouteSummary]
    @State private var edit = false
    @State private var rename = false
    @State private var name = ""
    @State private var didStart = false
    @State private var routeError: String?
    @State private var showWaiting = false

    init(favorite: SavedStop, autoStart: Bool = false) {
        self.favorite = favorite; self.autoStart = autoStart
        _routes = State(initialValue: favorite.displayRoutes)
    }
    private var stored: SavedStop? {
        favorites.items.first { $0.id == favorite.id } ?? favorites.items.first { $0.combinationID == favorite.combinationID }
    }
    private var value: SavedStop { stored ?? favorite }
    private var configuration: WidgetConfigurationData { value.configuration }
    private var allRoutesLoaded: Bool {
        !configuration.routeIds.isEmpty && Set(routes.map(\.routeId)) == Set(configuration.routeIds)
    }

    var body: some View {
        List {
            Section {
                StationSummaryView(name: configuration.stationName,
                    number: configuration.displayNumber ?? configuration.stationId, nickname: value.nickname)
            }.listRowBackground(AppTheme.surface)
            Section("기다릴 버스 · \(configuration.routeIds.count)개") {
                if let routeError { Text(routeError); Button("다시 시도") { Task { await loadRoutes() } }.foregroundStyle(AppTheme.action) }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ForEach(routes) { route in
                        VStack(alignment: .leading, spacing: 6) {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) {
                                    routeLabel(route)
                                    Spacer(minLength: 8)
                                    arrivalCountdown(route.routeId, at: context.date).monospacedDigit()
                                        .font(.body.weight(.medium)).fixedSize()
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    routeLabel(route)
                                    arrivalCountdown(route.routeId, at: context.date).monospacedDigit()
                                        .font(.body.weight(.medium))
                                }
                            }
                            if let direction = configuration.selections?.first(where: { $0.routeRef == route.routeId })?.direction {
                                Text(direction).font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                            }
                        }.padding(.vertical, 6).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                         .accessibilityElement(children: .combine)
                         .accessibilityIdentifier("waiting-route.\(route.routeId)")
                    }
                }
                if let error = arrivals.error, arrivals.response == nil { Text(error).font(.callout); Button("도착정보 다시 확인") { Task { await arrivals.refresh(configuration) } }.foregroundStyle(AppTheme.action) }
            }.listRowBackground(AppTheme.surface)
            Section {
                if waiting.activity != nil {
                    Button("현재 대기 보기", systemImage: "bus.fill") { showWaiting = true }
                        .foregroundStyle(AppTheme.action)
                }
                Button {
                    var current = value; current.routes = routes
                    if favorites.save(current) { favorites.announceSave(current) }
                } label: { Label(stored == nil ? "이 조합 즐겨찾기" : "즐겨찾기에 저장됨", systemImage: stored == nil ? "bookmark" : "bookmark.fill") }
                    .foregroundStyle(AppTheme.action).disabled(stored != nil).accessibilityIdentifier("detail-save-favorite")
                if stored != nil {
                    Button("정류장·버스 변경", systemImage: "pencil") { edit = true }.foregroundStyle(AppTheme.action)
                }
            }.listRowBackground(AppTheme.surface)
            if let error = favorites.error {
                Section {
                    Text(error)
                    Button("저장 상태 다시 확인") { favorites.reload() }.foregroundStyle(AppTheme.action)
                }.listRowBackground(AppTheme.surface)
            }
            if let error = waiting.errorMessage {
                Section { Text(error).font(.callout).foregroundStyle(AppTheme.secondaryText) }
                    .listRowBackground(AppTheme.surface)
            }
        }
        .transitList()
        .navigationTitle("버스 기다리기")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Label("뒤로", systemImage: "chevron.left") }
                    .accessibilityLabel("뒤로 가기")
                    .accessibilityIdentifier("favorite-detail-back")
            }
            if stored != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("이름 변경") { name = value.nickname; rename = true }
                        Button("즐겨찾기 삭제", role: .destructive) { if favorites.delete(value) { dismiss() } }
                    } label: { Label("즐겨찾기 관리", systemImage: "ellipsis.circle") }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { Task { await start() } } label: {
                Group {
                    if waiting.isBusy { ProgressView("대기 시작 중…") }
                    else { Text("\(configuration.routeIds.count)개 버스 기다리기") }
                }.frame(maxWidth: .infinity)
            }.buttonStyle(TransitButtonStyle()).disabled(!allRoutesLoaded || waiting.isBusy || waiting.activity != nil)
             .transitActionBar().accessibilityIdentifier("waiting-start")
        }
        .alert("즐겨찾기 이름", isPresented: $rename) {
            TextField("퇴근길, 학교에서 집", text: $name)
            Button("저장") { var current = value; current.nickname = name.trimmingCharacters(in: .whitespacesAndNewlines); favorites.save(current) }
            Button("취소", role: .cancel) {}
        }
        .sheet(isPresented: $edit) { StationFinderView(replacing: value) }
        .sheet(isPresented: $showWaiting) { NavigationStack { ActiveCommuteView() } }
        .onChange(of: configuration.cacheIdentity) { _, _ in
            routes = value.displayRoutes
        }
        .task(id: configuration.cacheIdentity) {
            await loadRoutes()
            if autoStart && !didStart { didStart = true; await start() }
        }
        .arrivalPolling(arrivals, configuration: configuration, visible: !showWaiting && !edit)
    }
    private func arrivalCountdown(_ routeID: String, at date: Date) -> Text {
        guard let arrival = arrivals.upcoming(routeID, at: date) else {
            return Text(arrivals.label(routeID, at: date))
        }
        let seconds = Int(ceil(arrival.timeIntervalSince(date)))
        return Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
            .accessibilityLabel(Text("\(seconds / 60)분 \(seconds % 60)초 남음"))
    }

    private func routeLabel(_ route: RouteSummary) -> some View {
        Text(route.routeName).font(.headline).fixedSize(horizontal: false, vertical: true)
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
            if !allRoutesLoaded { routeError = "저장한 버스를 확인할 수 없습니다. 정류장·버스를 다시 선택해 주세요." }
        } catch {
            guard !Task.isCancelled, configuration == requested.configuration else { return }
            routeError = error.localizedDescription
        }
    }
    private func start() async {
        guard allRoutesLoaded else { return }
        showWaiting = true
        await waiting.start(configuration: configuration, routes: routes)
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
            } else if let configuration = waiting.pendingConfiguration {
                VStack(alignment: .leading, spacing: 16) {
                    Text(configuration.stationName).font(.title3.weight(.semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        ForEach(waiting.pendingRoutes) { route in
                            HStack {
                                Text(route.routeName).font(.headline)
                                Spacer()
                                if let arrival = waiting.preview?.arrivals.first(where: { $0.routeId == route.routeId })?.nearestPrediction(relativeTo: context.date)?.arrivalAt,
                                   arrival > context.date {
                                    Text(timerInterval: context.date...arrival, countsDown: true).monospacedDigit().frame(width: 88)
                                } else { Text("확인 중").foregroundStyle(AppTheme.secondaryText) }
                            }
                        }
                    }
                    if waiting.isStarting { ProgressView("대기 시작 중…") }
                    if let message = waiting.errorMessage {
                        Text(message).font(.callout).foregroundStyle(AppTheme.secondaryText)
                        Button("다시 시도") { Task { await waiting.retryStart() } }
                            .buttonStyle(TransitButtonStyle()).disabled(waiting.isStarting)
                    }
                }.padding(20).transitCard().padding()
            } else {
                TransitEmptyState(title: "대기가 종료되었습니다", symbol: "checkmark.circle",
                    message: "즐겨찾기에서 다시 기다릴 수 있습니다.")
            }
        }.background(AppTheme.background).foregroundStyle(AppTheme.text).tint(AppTheme.action)
         .navigationTitle("지금 기다리는 버스").navigationBarTitleDisplayMode(.inline)
         .toolbar { ToolbarItem(placement: .confirmationAction) {
             Button(waiting.isStarting ? "시작 취소" : "닫기") { if waiting.isStarting { waiting.cancelStart() }; dismiss() }
         } }
    }
}
