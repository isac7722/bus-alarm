import ActivityKit
import Foundation

@MainActor
final class BusWaitingManager: ObservableObject {
    @Published private(set) var activity: Activity<BusWaitingAttributes>?
    @Published private(set) var content: BusWaitingAttributes.ContentState?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published private(set) var isStarting = false
    @Published private(set) var pendingConfiguration: WidgetConfigurationData?
    @Published private(set) var pendingRoutes: [RouteSummary] = []
    @Published private(set) var preview: ArrivalsResponse?
    private var startTask: Task<Void, Never>?
    private var needsRegistration = false
    private(set) var retryAfter: Double?

    private var observations: [Task<Void, Never>] = []
    private var isRestoring = false

    func start(configuration: WidgetConfigurationData, routes: [RouteSummary]) async {
        guard startTask == nil, !isBusy, activity == nil else { return }
        pendingConfiguration = configuration.selecting(Set(routes.map(\.routeId)))
        pendingRoutes = routes
        preview = pendingConfiguration.flatMap { ArrivalRepository.shared.cached($0) }
        isStarting = true
        let task = Task { await performStart(configuration: configuration, routes: routes) }
        startTask = task
        await task.value
        startTask = nil
        isStarting = false
    }

    func cancelStart() { startTask?.cancel() }
    func retryStart() async {
        guard let pendingConfiguration else { return }
        await start(configuration: pendingConfiguration, routes: pendingRoutes)
    }

    private func performStart(configuration: WidgetConfigurationData, routes: [RouteSummary]) async {
        guard !isBusy, !isRestoring, activity == nil, (1...4).contains(routes.count),
              Set(routes.map(\.routeId)).count == routes.count else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        var created: Activity<BusWaitingAttributes>?
        do {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw LiveWaitError.disabled }
            async let available = ArrivalRepository.shared.liveAvailable()
            async let arrivalRequest = ArrivalRepository.shared.fetch(configuration.selecting(Set(routes.map(\.routeId))))
            guard try await available else { throw LiveWaitError.unavailable }
            let response = try await arrivalRequest
            try Task.checkCancellation()
            preview = response
            let now = Date()
            let selected = routes.map { route in
                BusWaitingAttributes.Route(
                    routeId: route.routeId, routeName: route.routeName,
                    boarding: configuration.selections?.first { $0.routeRef == route.routeId }
                )
            }
            let states = selected.map { route in
                let prediction = response.arrivals.first { $0.routeId == route.routeId }?.predictions.first {
                    $0.order == 1 && $0.vehicleStatus == .running && ($0.arrivalAt ?? .distantPast) > now
                }
                let updatedAt = response.routeUpdatedAt?[route.routeId] ?? response.updatedAt
                let fresh = now.timeIntervalSince(updatedAt) <= 90 && updatedAt <= now.addingTimeInterval(30)
                return BusWaitingAttributes.RouteState(routeId: route.routeId, content: .init(
                    status: fresh && prediction != nil ? "waiting" : "unavailable",
                    arrivalAt: fresh ? prediction?.arrivalAt?.timeIntervalSince1970 : nil,
                    remainingStops: fresh ? prediction?.remainingStops : nil,
                    updatedAt: updatedAt.timeIntervalSince1970
                ))
            }
            guard let nearest = states.filter({ $0.content.arrivalAt != nil }).min(by: {
                $0.content.arrivalAt! < $1.content.arrivalAt!
            }) else { throw LiveWaitError.noPrediction }
            let secret = try LiveWaitStore.newSecret()
            let expiresAt = now.addingTimeInterval(3600).timeIntervalSince1970
            let attributes = BusWaitingAttributes(
                stationId: configuration.stationId, stationName: configuration.stationName,
                routeId: selected[0].routeId, routeName: selected[0].routeName, expiresAt: expiresAt,
                routes: selected
            )
            var initial = nearest.content
            initial.routes = states
            let wait = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initial, staleDate: initial.nextTransition()),
                pushType: .token
            )
            created = wait
            var records = try LiveWaitStore.load()
            records.append(LiveWaitRecord(activityId: wait.id, secret: secret, expiresAt: expiresAt))
            try LiveWaitStore.save(records)
            activity = wait
            content = initial
            let token = try await firstToken(wait)
            try Task.checkCancellation()
            let registration = try await register(wait, token: token)
            try Task.checkCancellation()
            await apply(registration.content, to: wait)
            needsRegistration = false

            if activity?.id == wait.id { observe(wait) }
            pendingConfiguration = nil; pendingRoutes = []; preview = nil
        } catch {
            if let created {
                await created.end(nil, dismissalPolicy: .immediate)
                await removeRegistration(activityId: created.id)
            }
            activity = nil
            content = nil
            if error is CancellationError { pendingConfiguration = nil; pendingRoutes = []; preview = nil }
            else { errorMessage = error.localizedDescription }
        }
    }

    private func firstToken(_ wait: Activity<BusWaitingAttributes>) async throws -> Data {
        if let token = wait.pushToken { return token }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                for await token in wait.pushTokenUpdates { try Task.checkCancellation(); return token }
                throw LiveWaitError.tokenUnavailable
            }
            group.addTask { try await Task.sleep(for: .seconds(15)); throw LiveWaitError.tokenUnavailable }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func apply(_ value: BusWaitingAttributes.ContentState, to wait: Activity<BusWaitingAttributes>) async {
        guard activity?.id == wait.id, !Task.isCancelled else { return }
        if let content, !value.supersedes(content) { return }
        content = value
        if value.isEnded {
            await wait.end(ActivityContent(state: value, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(60)))
            guard activity?.id == wait.id else { return }
            activity = nil
            cancelObservations()
            await removeRegistration(activityId: wait.id)
        } else {
            await wait.update(ActivityContent(state: value, staleDate: value.nextTransition()))
        }
    }

    /// Foreground reconciliation reads the tracked session, never the next bus on the route.
    @discardableResult
    func refresh() async -> Bool {
        guard !isBusy, !isRestoring, let wait = activity else { return true }
        do {
            guard let record = try LiveWaitStore.load().first(where: { $0.activityId == wait.id && !$0.needsDelete }) else { return true }
            retryAfter = nil
            let result: LiveWaitRegistration
            if needsRegistration, let token = wait.pushToken {
                result = try await register(wait, token: token)
                needsRegistration = false
            } else { result = try await APIClient().liveWait(secret: record.secret) }
            guard !Task.isCancelled, !isBusy, activity?.id == wait.id else { return true }
            await apply(result.content, to: wait)
            if activity?.id == wait.id { errorMessage = nil }
            return true
        } catch {
            if case APIClientError.server(code: "LIVE_ACTIVITY_ENDED", message: _) = error, activity?.id == wait.id {
                await wait.end(nil, dismissalPolicy: .immediate)
                activity = nil; content = nil; cancelObservations()
                await removeRegistration(activityId: wait.id)
                return true
            }
            if case APIClientError.rateLimited(let delay) = error { retryAfter = delay }
            // A transient fetch error leaves the existing ETA on screen.
            return false
        }
    }

    func stop() async {
        guard !isBusy, let wait = activity else { return }
        isBusy = true
        defer { isBusy = false }
        cancelObservations()
        let final = BusWaitingAttributes.ContentState(
            status: "cancelled", arrivalAt: nil, remainingStops: nil, updatedAt: Date().timeIntervalSince1970
        )
        content = final
        await wait.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .immediate)
        activity = nil
        content = nil
        pendingConfiguration = nil; pendingRoutes = []; preview = nil
        await removeRegistration(activityId: wait.id)
    }

    func restore() async {
        guard !isBusy, !isRestoring else { return }
        isRestoring = true
        isBusy = true
        defer { isRestoring = false; isBusy = false }
        do {
            let now = Date().timeIntervalSince1970
            let records = try LiveWaitStore.load()
            for wait in Activity<BusWaitingAttributes>.activities {
                if wait.attributes.expiresAt <= now {
                    let final = BusWaitingAttributes.ContentState(status: "expired", arrivalAt: nil, remainingStops: nil, updatedAt: now)
                    await wait.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .immediate)
                } else if !records.contains(where: { $0.activityId == wait.id && !$0.needsDelete }) {
                    // A failed keychain save must not leave an unmanaged activity.
                    await wait.end(nil, dismissalPolicy: .immediate)
                }
            }
            let active = Activity<BusWaitingAttributes>.activities.filter {
                ($0.activityState == .active || $0.activityState == .stale) && $0.attributes.expiresAt > now
            }
            for record in records where record.needsDelete || !active.contains(where: { $0.id == record.activityId }) {
                await removeRegistration(activityId: record.activityId)
            }
            if let wait = active.first {
                if activity?.id != wait.id { activity = wait; content = wait.content.state; observe(wait) }
                if let token = wait.pushToken {
                    do {
                        let result = try await register(wait, token: token)
                        await apply(result.content, to: wait)
                        needsRegistration = false
                        errorMessage = nil
                    }
                    catch {
                        if case APIClientError.server(code: "LIVE_ACTIVITY_ENDED", message: _) = error {
                            await wait.end(nil, dismissalPolicy: .immediate)
                            activity = nil
                            content = nil
                            cancelObservations()
                            await removeRegistration(activityId: wait.id)
                        }
                        needsRegistration = true
                    }
                }
            } else { activity = nil; content = nil; cancelObservations() }
        } catch { errorMessage = error.localizedDescription }
    }

    private func register(_ wait: Activity<BusWaitingAttributes>, token: Data) async throws -> LiveWaitRegistration {
        guard let record = try LiveWaitStore.load().first(where: { $0.activityId == wait.id && !$0.needsDelete }) else {
            throw LiveWaitError.storage
        }
        if let routes = wait.attributes.routes {
            return try await APIClient().registerLiveWaitGroup(
                secret: record.secret, stationId: wait.attributes.stationId, routes: routes,
                pushToken: token.map { String(format: "%02x", $0) }.joined(), environment: PushEnvironment.current
            )
        }
        if let boarding = wait.attributes.boarding {
            return try await APIClient().registerBoardingWait(
                secret: record.secret, stationRef: wait.attributes.stationId, boarding: boarding,
                pushToken: token.map { String(format: "%02x", $0) }.joined(), environment: PushEnvironment.current)
        }
        return try await APIClient().registerLiveWait(
            secret: record.secret, stationId: wait.attributes.stationId, routeId: wait.attributes.routeId,
            pushToken: token.map { String(format: "%02x", $0) }.joined(), environment: PushEnvironment.current
        )
    }

    private func observe(_ wait: Activity<BusWaitingAttributes>) {
        cancelObservations()
        observations.append(Task { [weak self] in
            for await token in wait.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                // Retry transient registration failures while the app has runtime.
                self?.needsRegistration = true
                for attempt in 0..<4 {
                    do {
                        if let result = try await self?.register(wait, token: token) { await self?.apply(result.content, to: wait) }
                        self?.needsRegistration = false
                        break
                    }
                    catch {
                        guard !Task.isCancelled else { return }
                        if attempt == 3 { break }
                        do { try await Task.sleep(for: .seconds([1, 3, 5][attempt])) } catch { return }
                    }
                }
            }
        })
        observations.append(Task { [weak self] in
            for await value in wait.contentUpdates {
                guard !Task.isCancelled else { return }
                guard self?.activity?.id == wait.id else { return }
                if let current = self?.content, !value.state.supersedes(current) { continue }
                self?.content = value.state
            }
        })
        observations.append(Task { [weak self] in
            for await state in wait.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .ended || state == .dismissed {
                    self?.observations.prefix(2).forEach { $0.cancel() }
                    if self?.activity?.id == wait.id {
                        self?.activity = nil
                        self?.content = nil
                    }
                    await self?.removeRegistration(activityId: wait.id)
                    return
                }
            }
        })
    }

    private func removeRegistration(activityId: String) async {
        do {
            var records = try LiveWaitStore.load()
            guard let index = records.firstIndex(where: { $0.activityId == activityId }) else { return }
            records[index].needsDelete = true
            let record = records[index]
            try LiveWaitStore.save(records)
            if record.expiresAt + 300 > Date().timeIntervalSince1970 {
                do { try await APIClient().endLiveWait(secret: record.secret) }
                catch {
                    // Persist the cancellation; restore retries after a network outage.
                    errorMessage = "화면의 대기는 종료했습니다. 서버 연결이 복구되면 갱신도 중지합니다."
                    return
                }
            }
            var latest = try LiveWaitStore.load()
            latest.removeAll { $0.activityId == activityId }
            try LiveWaitStore.save(latest)
        } catch { errorMessage = error.localizedDescription }
    }

    private func cancelObservations() {
        observations.forEach { $0.cancel() }
        observations.removeAll()
    }
}
