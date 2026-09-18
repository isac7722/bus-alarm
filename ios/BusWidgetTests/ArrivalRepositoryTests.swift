import Foundation
import XCTest
@testable import BusWidgetApp

final class ArrivalRepositoryTests: XCTestCase {
    private let configuration = WidgetConfigurationData(stationId: "test", stationName: "정류장", routeIds: ["a", "b"])
    private func response(_ routes: [String], at date: Date, eta: TimeInterval = 600) -> ArrivalsResponse {
        ArrivalsResponse(station: .init(stationId: "test", name: "정류장"), updatedAt: date, fetchedAt: date,
            arrivals: routes.map { RouteArrival(routeId: $0, routeName: $0, predictions: [
                .init(order: 1, arrivalAt: date.addingTimeInterval(eta), remainingSeconds: Int(eta), remainingStops: 3, vehicleStatus: .running)
            ]) })
    }
    @MainActor
    func testDiskRestoreSubsetAndOlderResponseCannotRegressETA() throws {
        let suite = "arrival-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let repository = ArrivalRepository(api: nil, storage: defaults, namespace: "test")
        repository.save(response(["a", "b"], at: now), for: configuration)
        repository.save(response(["a"], at: now.addingTimeInterval(-20), eta: 1), for: configuration)
        let restored = ArrivalRepository(api: nil, storage: defaults, namespace: "test")
        let subset = try XCTUnwrap(restored.cached(configuration.selecting(["a"])))
        XCTAssertEqual(subset.arrivals.map(\.routeId), ["a"])
        XCTAssertEqual(subset.updatedAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertGreaterThan(try XCTUnwrap(subset.arrivals[0].predictions[0].arrivalAt).timeIntervalSince(now), 599)
        XCTAssertNil(ArrivalRepository(api: nil, storage: defaults, namespace: "another-server").cached(configuration))
    }
    @MainActor
    func testPartialSuccessKeepsFailedRouteAndConfirmedEmptyClearsOnlySuccessfulRoute() throws {
        let repo = ArrivalRepository(api: nil, storage: nil)
        let now = Date()
        repo.save(response(["a", "b"], at: now), for: configuration)
        var partial = response(["a"], at: now.addingTimeInterval(1), eta: 900)
        partial.failedRouteIds = ["b"]
        repo.save(partial, for: configuration)
        let cached = try XCTUnwrap(repo.cached(configuration))
        XCTAssertEqual(cached.arrivals.count, 2)
        XCTAssertEqual(cached.routeUpdatedAt?["b"], now)
        let empty = ArrivalsResponse(station: cached.station, updatedAt: now.addingTimeInterval(2), fetchedAt: now,
            arrivals: [.init(routeId: "a", routeName: "a", predictions: [])])
        repo.save(empty, for: configuration)
        XCTAssertEqual(repo.cached(configuration)?.arrivals.first?.predictions.count, 0)
        XCTAssertEqual(repo.cached(configuration)?.arrivals.last?.predictions.count, 1)
    }
    @MainActor
    func testFailureKeepsSixMinuteOldCountdownUntilActualETA() async throws {
        let repo = ArrivalRepository(api: nil, storage: nil)
        let now = Date()
        repo.save(response(["a"], at: now.addingTimeInterval(-360)), for: configuration)
        let model = CommuteArrivalsModel(repository: repo)
        await model.refresh(configuration)
        XCTAssertNotNil(model.error)
        XCTAssertNotNil(model.upcoming("a", at: now))
        XCTAssertEqual(model.label("a", at: now.addingTimeInterval(241)), "다시 연결 중")
    }
    func testLiveRevisionAndExpiryPolicy() {
        let old = BusWaitingAttributes.ContentState(status: "waiting", arrivalAt: 1800, remainingStops: 2, updatedAt: 900, revision: 10)
        XCTAssertEqual(old.message(isStale: true, relativeTo: Date(timeIntervalSince1970: 1500)), "도착까지")
        XCTAssertEqual(old.message(relativeTo: Date(timeIntervalSince1970: 1801)), "다시 연결 중")
        XCTAssertEqual(old.nextTransition(after: Date(timeIntervalSince1970: 1500)), Date(timeIntervalSince1970: 1800))
        var newer = old; newer.revision = 11
        XCTAssertTrue(newer.supersedes(old))
        XCTAssertFalse(old.supersedes(newer))
        let ended = BusWaitingAttributes.ContentState(status: "cancelled", arrivalAt: nil, remainingStops: nil, updatedAt: 1500, revision: 12)
        XCTAssertFalse(newer.supersedes(ended))
        XCTAssertTrue(ended.supersedes(newer))
        let preview = BusWaitingAttributes.ContentState(status: "waiting", arrivalAt: 1900, remainingStops: 2, updatedAt: 1000)
        XCTAssertTrue(old.supersedes(preview), "Tracked server state takes precedence over the unregistered preview")
    }
    @MainActor
    func testConcurrentFetchesCoalesceAndFailureRetainsCache() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ArrivalTestProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        ArrivalTestProtocol.reset()
        let api = try APIClient(baseURL: URL(string: "https://arrival-cache.test"), session: session)
        let repo = ArrivalRepository(api: api, storage: nil)
        async let first = repo.fetch(configuration)
        async let second = repo.fetch(configuration)
        let (all, duplicate) = try await (first, second)
        XCTAssertEqual(all.arrivals, duplicate.arrivals)
        let subset = try await repo.fetch(configuration.selecting(["a"]))
        XCTAssertEqual(all.arrivals.count, 2)
        XCTAssertEqual(subset.arrivals.map(\.routeId), ["a"])
        XCTAssertEqual(ArrivalTestProtocol.requestCount, 1)
        ArrivalTestProtocol.fail()
        do { _ = try await repo.fetch(configuration, force: true); XCTFail("Expected transport failure") } catch {}
        XCTAssertEqual(repo.cached(configuration)?.arrivals, all.arrivals)
    }
}

private final class ArrivalTestProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    private static var failed = false
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset() { lock.lock(); defer { lock.unlock() }; count = 0; failed = false }
    static func fail() { lock.lock(); defer { lock.unlock() }; failed = true }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; let fail = Self.failed; Self.lock.unlock()
        if fail { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let now = Date()
        let response = ArrivalsResponse(station: .init(stationId: "test", name: "정류장"), updatedAt: now, fetchedAt: now,
            arrivals: ["a", "b"].map { RouteArrival(routeId: $0, routeName: $0, predictions: [
                .init(order: 1, arrivalAt: now.addingTimeInterval(600), remainingSeconds: 600, remainingStops: 3, vehicleStatus: .running)
            ]) })
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder.busWidget.encode(response))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
