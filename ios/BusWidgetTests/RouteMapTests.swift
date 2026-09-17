import Foundation
import XCTest
@testable import BusWidgetApp

private let testMapStation = MapStation(stationRef: "gg:104000069", name: "강변역", displayNumber: "05267", latitude: 37.535, longitude: 127.094)
private func boarding(_ sequence: Int = 1, route: String = "gg:227000040") -> BoardingSelection {
    BoardingSelection(boardingId: "\(route):104000069:\(sequence)", routeRef: route, routeRevision: "revision-a",
                      routeName: "9304", stationRef: testMapStation.stationRef, sequence: sequence,
                      directionId: sequence == 1 ? "outbound" : "inbound", direction: sequence == 1 ? "하남 방면" : "강변역 방면")
}
private func occurrence(_ sequence: Int = 1, route: String = "gg:227000040") -> RouteStopOccurrence {
    let b = boarding(sequence, route: route)
    return RouteStopOccurrence(boardingId: b.boardingId, routeRef: b.routeRef, routeRevision: b.routeRevision, routeName: b.routeName,
                               stationRef: b.stationRef, sequence: b.sequence, directionId: b.directionId, direction: b.direction,
                               station: testMapStation, nextStop: "다음 정류장", selectable: true, reason: nil)
}
private let testCatalogRoute = CatalogRoute(routeRef: "gg:227000040", name: "9304", region: "하남", kind: "직행좌석", start: "하남", end: "강변역")

final class RouteMapTests: XCTestCase {
    private func api(_ host: String = "routes.test") throws -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouteTestProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel() }
        return try APIClient(baseURL: URL(string: "https://\(host)"), session: session)
    }
    private func store() throws -> AppGroupStore {
        let suite = "route-map-test.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return try XCTUnwrap(AppGroupStore(suiteName: suite))
    }
    func testLegacyAndV2ConfigurationRoundTrip() throws {
        let legacy = Data(#"{"station_id":"05267","station_name":"강변역","route_ids":["227000040"]}"#.utf8)
        let old = try JSONDecoder.busWidget.decode(WidgetConfigurationData.self, from: legacy)
        XCTAssertEqual(old.version, 1)
        XCTAssertNil(old.selections)
        let modern = WidgetConfigurationData(validated: ValidatedSelection(station: testMapStation, selections: [boarding(4)]))
        let data = try JSONEncoder.busWidget.encode(modern)
        let decoded = try JSONDecoder.busWidget.decode(WidgetConfigurationData.self, from: data)
        XCTAssertEqual(decoded, modern)
        XCTAssertEqual(decoded.selections?.first?.sequence, 4)
    }
    func testUnsupportedOrIncompleteConfigurationDoesNotBecomeLegacy() throws {
        for version in [2, 3] {
            let data = Data("{\"version\":\(version),\"station_id\":\"05267\",\"station_name\":\"강변역\",\"route_ids\":[\"227000040\"]}".utf8)
            XCTAssertThrowsError(try JSONDecoder.busWidget.decode(WidgetConfigurationData.self, from: data))
        }
    }
    func testArrivalCacheCannotCrossDirectionsOrRevisions() throws {
        let store = try store()
        let first = WidgetConfigurationData(validated: ValidatedSelection(station: testMapStation, selections: [boarding()]))
        let opposite = WidgetConfigurationData(validated: ValidatedSelection(station: testMapStation, selections: [boarding(4)]))
        let response = ArrivalsResponse(station: ArrivalStation(stationId: testMapStation.id, name: "강변역"), updatedAt: Date(timeIntervalSince1970: 1000), fetchedAt: Date(timeIntervalSince1970: 1000), arrivals: [])
        try store.saveCachedArrivals(response, for: first)
        XCTAssertEqual(store.loadCachedArrivals(for: first), response)
        XCTAssertNil(store.loadCachedArrivals(for: opposite))
    }
    @MainActor
    func testDirectionMustBeSelectedAndChangingItClearsStop() async throws {
        let model = RouteMapViewModel(route: testCatalogRoute, client: try api())
        await model.load()
        XCTAssertNotNil(model.detail)
        model.select(occurrence())
        XCTAssertNil(model.selected)
        model.changeDirection("outbound")
        model.select(occurrence())
        XCTAssertEqual(model.selected?.sequence, 1)
        model.changeDirection("inbound")
        XCTAssertNil(model.selected)
        XCTAssertEqual(model.stops.map(\.sequence), [4])
    }
    @MainActor
    func testFourRoutesLimitAndDirectionReplacement() {
        let model = BoardingReviewViewModel(station: testMapStation, initial: boarding(), client: nil, store: nil)
        for n in 1...4 { model.toggle(occurrence(route: "gg:20000000\(n)")) }
        XCTAssertEqual(model.selections.count, 4)
        model.toggle(occurrence(4))
        XCTAssertEqual(model.selections.count, 4)
        XCTAssertEqual(model.selections.first?.sequence, 4)
        model.toggle(occurrence(4))
        XCTAssertEqual(model.selections.count, 3)
    }
    @MainActor
    func testFailedValidationPreservesExistingConfiguration() async throws {
        let store = try store()
        let old = WidgetConfigurationData(stationId: "22001", stationName: "강남역", routeIds: ["100100341"])
        try store.saveConfiguration(old)
        let model = BoardingReviewViewModel(station: testMapStation, initial: boarding(), client: try api("changed.test"), store: store)
        let result = await model.save()
        XCTAssertNil(result)
        XCTAssertEqual(store.loadConfiguration(), old)
        XCTAssertEqual(model.selections, [boarding()])
        XCTAssertNotNil(model.error)
    }
    @MainActor
    func testSuccessfulSaveUsesServerValidatedSelection() async throws {
        let store = try store()
        let model = BoardingReviewViewModel(station: testMapStation, initial: boarding(), client: try api(), store: store)
        let result = await model.save()
        XCTAssertEqual(result?.version, 2)
        XCTAssertEqual(store.loadConfiguration()?.selections, [boarding()])
    }
    func testV2ArrivalRequestCarriesSequenceAndProvider() async throws {
        let config = WidgetConfigurationData(validated: ValidatedSelection(station: testMapStation, selections: [boarding(4)]))
        let response = try await api().arrivals(configuration: config)
        XCTAssertEqual(response.station.stationId, testMapStation.stationRef)
    }
    func testOldLiveAttributesStillDecode() throws {
        let value = Data(#"{"station_id":"05267","station_name":"강변역","route_id":"227000040","route_name":"9304","expires_at":12345}"#.utf8)
        let attributes = try JSONDecoder.busWidget.decode(BusWaitingAttributes.self, from: value)
        XCTAssertNil(attributes.boarding)
    }
}

private final class RouteTestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var status = 200
        let data: Data
        switch request.url?.path {
        case "/api/v2/routes/gg:227000040":
            data = try! JSONEncoder.busWidget.encode(CatalogDetail(route: testCatalogRoute, revision: "revision-a", directions: [RouteDirection(id: "outbound", name: "하남 방면"), RouteDirection(id: "inbound", name: "강변역 방면")], stops: [occurrence(), occurrence(4)]))
        case "/api/v2/routes/gg:227000040/geometry":
            data = Data(#"{"coordinates":[],"source":"stops"}"#.utf8)
        case "/api/v2/selections/validate":
            if request.url?.host == "changed.test" {
                status = 409
                data = Data(#"{"error":{"code":"ROUTE_CHANGED","message":"노선 정보가 변경되었습니다."}}"#.utf8)
            } else { data = try! JSONEncoder.busWidget.encode(ValidatedSelection(station: testMapStation, selections: [boarding()])) }
        case "/api/v2/arrivals":
            XCTAssertEqual(request.httpMethod, "POST")
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            }
            let sent = try? JSONDecoder.busWidget.decode(SelectionRequest.self, from: body)
            XCTAssertEqual(sent?.selections.first?.sequence, 4)
            XCTAssertEqual(sent?.selections.first?.routeRef, "gg:227000040")
            data = try! JSONEncoder.busWidget.encode(ArrivalsResponse(station: ArrivalStation(stationId: testMapStation.id, name: "강변역"), updatedAt: Date(timeIntervalSince1970: 1000), fetchedAt: Date(timeIntervalSince1970: 1000), arrivals: []))
        default:
            XCTFail("Unexpected API: \(request.url?.path ?? "")")
            data = Data("{}".utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
