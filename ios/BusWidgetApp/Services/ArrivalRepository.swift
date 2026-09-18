import Foundation
import Network

/// Shared last-success cache. Source timestamps and local receipt times have different jobs.
@MainActor
final class ArrivalRepository {
    static let shared = ArrivalRepository(api: try? APIClient(), storage: .standard)
    struct Entry: Codable {
        let arrival: RouteArrival
        let updatedAt: Date
        let fetchedAt: Date
        let receivedAt: Date
    }
    private struct Flight {
        let id: UUID
        let keys: Set<String>
        let task: Task<ArrivalsResponse, Error>
    }
    private let api: APIClient?
    private let storage: UserDefaults?
    private let storageKey: String
    private var entries: [String: Entry] = [:]
    private var flights: [String: Flight] = [:]
    private var availability: (Bool, Date)?
    private var availabilityTask: Task<Bool, Error>?

    init(api: APIClient?, storage: UserDefaults?, namespace: String = APIClient.configuredBaseURL?.absoluteString ?? "unconfigured") {
        self.api = api; self.storage = storage
        storageKey = "arrival-cache.v2." + namespace
        if let data = storage?.data(forKey: storageKey), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved.filter { Date().timeIntervalSince($0.value.receivedAt) < 86400 }
        }
    }
    private func key(_ configuration: WidgetConfigurationData, route: String) -> String {
        configuration.selecting([route]).cacheIdentity
    }
    func cached(_ configuration: WidgetConfigurationData) -> ArrivalsResponse? {
        let values = configuration.routeIds.compactMap { entries[key(configuration, route: $0)] }
        guard !values.isEmpty else { return nil }
        return ArrivalsResponse(station: .init(stationId: configuration.stationId, name: configuration.stationName),
            updatedAt: values.map(\.updatedAt).min()!, fetchedAt: values.map(\.fetchedAt).min()!, arrivals: values.map(\.arrival),
            routeUpdatedAt: Dictionary(uniqueKeysWithValues: values.map { ($0.arrival.routeId, $0.updatedAt) }))
    }
    func fetch(_ configuration: WidgetConfigurationData, force: Bool = false) async throws -> ArrivalsResponse {
        guard let api else { throw APIClientError.invalidBaseURL }
        let keys = Set(configuration.routeIds.map { key(configuration, route: $0) })
        if !force, !keys.isEmpty, keys.allSatisfy({ entries[$0].map { Date().timeIntervalSince($0.receivedAt) < 5 } == true }),
           let cached = cached(configuration) { return cached }
        if let flight = flights.values.first(where: { $0.keys.isSuperset(of: keys) }) {
            let result = try await flight.task.value
            save(result, for: configuration)
            if var cached = cached(configuration) {
                cached.failedRouteIds = result.failedRouteIds
                return cached
            }
        }
        let requestKey = keys.sorted().joined(separator: "\n")
        let id = UUID()
        let task = Task { try await api.arrivals(configuration: configuration) }
        flights[requestKey] = Flight(id: id, keys: keys, task: task)
        defer { if flights[requestKey]?.id == id { flights[requestKey] = nil } }
        let result = try await task.value
        save(result, for: configuration)
        guard let merged = cached(configuration) else { throw APIClientError.invalidResponse }
        var response = merged
        response.failedRouteIds = result.failedRouteIds
        return response
    }
    func save(_ response: ArrivalsResponse, for configuration: WidgetConfigurationData, now: Date = .now) {
        for arrival in response.arrivals where configuration.routeIds.contains(arrival.routeId) {
            let updated = response.routeUpdatedAt?[arrival.routeId] ?? response.updatedAt
            guard updated <= now.addingTimeInterval(30) else { continue }
            let cacheKey = key(configuration, route: arrival.routeId)
            guard entries[cacheKey].map({ $0.updatedAt <= updated }) ?? true else { continue }
            entries[cacheKey] = Entry(arrival: arrival, updatedAt: updated, fetchedAt: response.fetchedAt, receivedAt: now)
        }
        entries = entries.filter { now.timeIntervalSince($0.value.receivedAt) < 86400 }
        if entries.count > 128 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.receivedAt > $1.value.receivedAt }.prefix(128).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(entries) { storage?.set(data, forKey: storageKey) }
    }
    func liveAvailable() async throws -> Bool {
        if let availability, Date().timeIntervalSince(availability.1) < 60 { return availability.0 }
        if let availabilityTask { return try await availabilityTask.value }
        guard let api else { throw APIClientError.invalidBaseURL }
        let task = Task { try await api.liveActivitiesAvailable() }
        availabilityTask = task
        defer { availabilityTask = nil }
        let value = try await task.value
        availability = (value, .now)
        return value
    }
}

@MainActor
final class ConnectionRecovery: ObservableObject {
    static let shared = ConnectionRecovery()
    @Published private(set) var generation = 0
    private let monitor = NWPathMonitor()
    private var recovery: Task<Void, Never>?
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                self?.recovery?.cancel()
                self?.recovery = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    self?.generation += 1
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "bus.connection-recovery"))
    }
    deinit { monitor.cancel(); recovery?.cancel() }
}
