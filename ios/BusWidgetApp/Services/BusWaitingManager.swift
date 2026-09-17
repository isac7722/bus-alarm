import ActivityKit
import Foundation

@MainActor
final class BusWaitingManager: ObservableObject {
    @Published private(set) var activity: Activity<BusWaitingAttributes>?
    @Published private(set) var content: BusWaitingAttributes.ContentState?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    private var observations: [Task<Void, Never>] = []
    private var isRestoring = false

    func start(configuration: WidgetConfigurationData, route: RouteSummary) async {
        guard !isBusy, !isRestoring, activity == nil else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        var created: Activity<BusWaitingAttributes>?
        do {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw LiveWaitError.disabled }
            let api = try APIClient()
            guard try await api.liveActivitiesAvailable() else { throw LiveWaitError.unavailable }
            let response = try await api.arrivals(configuration: configuration, routeId: route.routeId)
            let now = Date()
            guard now.timeIntervalSince(response.updatedAt) <= 90,
                  let prediction = response.arrivals.first?.predictions.first(where: {
                      $0.order == 1 && $0.vehicleStatus == .running && ($0.arrivalAt ?? .distantPast) > now
                  }), let arrivalAt = prediction.arrivalAt else { throw LiveWaitError.noPrediction }
            let secret = try LiveWaitStore.newSecret()
            let expiresAt = now.addingTimeInterval(3600).timeIntervalSince1970
            let attributes = BusWaitingAttributes(
                stationId: configuration.stationId, stationName: configuration.stationName,
                routeId: route.routeId, routeName: route.routeName, expiresAt: expiresAt,
                boarding: configuration.selections?.first { $0.routeRef == route.routeId }
            )
            let initial = BusWaitingAttributes.ContentState(
                status: "waiting", arrivalAt: arrivalAt.timeIntervalSince1970,
                remainingStops: prediction.remainingStops, updatedAt: response.updatedAt.timeIntervalSince1970
            )
            let wait = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initial, staleDate: now.addingTimeInterval(90)),
                pushType: .token
            )
            created = wait
            var records = try LiveWaitStore.load()
            records.append(LiveWaitRecord(activityId: wait.id, secret: secret, expiresAt: expiresAt))
            try LiveWaitStore.save(records)
            activity = wait
            content = initial
            // Token delivery is asynchronous and can fail on unsupported signing/configurations.
            var token: Data?
            for _ in 0..<60 {
                token = wait.pushToken
                if token != nil { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard let token else { throw LiveWaitError.tokenUnavailable }
            let registration = try await register(wait, token: token)
            await wait.update(ActivityContent(
                state: registration.content,
                staleDate: Date(timeIntervalSince1970: registration.content.updatedAt + 90)
            ))
            content = registration.content
            observe(wait)
        } catch {
            if let created {
                await created.end(nil, dismissalPolicy: .immediate)
                await removeRegistration(activityId: created.id)
            }
            activity = nil
            content = nil
            errorMessage = error.localizedDescription
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
        await wait.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .immediate)
        activity = nil
        content = nil
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
                    do { _ = try await register(wait, token: token) }
                    catch {
                        if case APIClientError.server(code: "LIVE_ACTIVITY_ENDED", message: _) = error {
                            await wait.end(nil, dismissalPolicy: .immediate)
                            activity = nil
                            content = nil
                            cancelObservations()
                            await removeRegistration(activityId: wait.id)
                        }
                        errorMessage = error.localizedDescription
                    }
                }
            } else { activity = nil; content = nil; cancelObservations() }
        } catch { errorMessage = error.localizedDescription }
    }

    private func register(_ wait: Activity<BusWaitingAttributes>, token: Data) async throws -> LiveWaitRegistration {
        guard let record = try LiveWaitStore.load().first(where: { $0.activityId == wait.id && !$0.needsDelete }) else {
            throw LiveWaitError.storage
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
                for attempt in 0..<3 {
                    do { _ = try await self?.register(wait, token: token); break }
                    catch {
                        guard !Task.isCancelled else { return }
                        if attempt == 2 { self?.errorMessage = "실시간 현황 연결을 갱신하지 못했습니다. 앱을 다시 열어 연결을 확인해 주세요." }
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
            }
        })
        observations.append(Task { [weak self] in
            for await value in wait.contentUpdates {
                guard !Task.isCancelled else { return }
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
