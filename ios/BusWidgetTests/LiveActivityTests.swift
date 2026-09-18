import ActivityKit
import Foundation
import XCTest
@testable import BusWidgetApp

final class LiveActivityTests: XCTestCase {
    func testAPNsContentUsesDefaultDecoderAndUnixEpoch() throws {
        let json = """
        {"status":"waiting","arrivalAt":1789426980,"remainingStops":2,"updatedAt":1789426800}
        """
        let state = try JSONDecoder().decode(BusWaitingAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertEqual(state.arrivalDate?.timeIntervalSince1970, 1_789_426_980)
        XCTAssertEqual(state.remainingStops, 2)
        XCTAssertEqual(state.message(relativeTo: Date(timeIntervalSince1970: state.updatedAt)), "도착까지")
        XCTAssertEqual(state.message(relativeTo: Date(timeIntervalSince1970: 1_789_426_981)), "다시 연결 중")
        XCTAssertEqual(state.message(isStale: true), "다시 연결 중")
        XCTAssertFalse(state.isEnded)
    }

    func testRegistrationDecodesAPIEnvelopeAndActivityContent() throws {
        let json = """
        {"expires_at":1789430400,"content":{"status":"unavailable","arrivalAt":null,"remainingStops":null,"updatedAt":1789426800}}
        """
        let response = try JSONDecoder.busWidget.decode(LiveWaitRegistration.self, from: Data(json.utf8))
        XCTAssertEqual(response.expiresAt, 1_789_430_400)
        XCTAssertNil(response.content.arrivalDate)
        XCTAssertEqual(response.content.message(), "다시 연결 중")
    }

    func testFinalStatesStayFinalWhenStale() {
        for status in ["arrived", "passed", "expired", "cancelled"] {
            let state = BusWaitingAttributes.ContentState(status: status, arrivalAt: nil, remainingStops: nil, updatedAt: 1)
            XCTAssertTrue(state.isEnded)
            XCTAssertEqual(state.message(), state.message(isStale: true))
            XCTAssertNotEqual(state.message(isStale: true), "버스에 탑승했습니다")
        }
    }

    func testGroupChoosesEarliestValidRouteAndKeepsEveryRow() throws {
        let now = Date(timeIntervalSince1970: 1_789_426_800)
        let json = """
        {"status":"waiting","arrivalAt":1789426801,"remainingStops":1,"updatedAt":1789426800,"routes":[
          {"routeId":"later","content":{"status":"waiting","arrivalAt":1789427100,"remainingStops":4,"updatedAt":1789426800}},
          {"routeId":"nearest","content":{"status":"waiting","arrivalAt":1789426920,"remainingStops":2,"updatedAt":1789426800}},
          {"routeId":"stale","content":{"status":"waiting","arrivalAt":1789426801,"remainingStops":1,"updatedAt":1789426600}},
          {"routeId":"arrived","content":{"status":"arrived","arrivalAt":1789426800,"remainingStops":0,"updatedAt":1789426800}}
        ]}
        """
        for decoder in [JSONDecoder(), JSONDecoder.busWidget] {
            let state = try decoder.decode(BusWaitingAttributes.ContentState.self, from: Data(json.utf8))
            XCTAssertEqual(state.routes?.count, 4)
            XCTAssertEqual(state.nearestRoute(relativeTo: now)?.routeId, "stale")
            XCTAssertEqual(state.summary(relativeTo: now).arrivalAt, 1_789_426_801)
            XCTAssertEqual(state.state(for: "arrived").status, "arrived")
            XCTAssertEqual(state.summary(relativeTo: now.addingTimeInterval(301)).status, "unavailable")
            let ended = BusWaitingAttributes.ContentState(status: "cancelled", arrivalAt: nil, remainingStops: nil, updatedAt: now.timeIntervalSince1970, routes: state.routes)
            XCTAssertEqual(ended.state(for: "nearest").status, "cancelled")
        }
    }

    func testGroupSkipsPastETAAndFallsBackWithoutClaimingArrival() {
        let now = Date(timeIntervalSince1970: 1000)
        let state = BusWaitingAttributes.ContentState(status: "waiting", arrivalAt: 999, remainingStops: 0, updatedAt: 1000, routes: [
            .init(routeId: "past", content: .init(status: "waiting", arrivalAt: 999, remainingStops: 0, updatedAt: 1000)),
            .init(routeId: "next", content: .init(status: "waiting", arrivalAt: 1010, remainingStops: 1, updatedAt: 1000))
        ])
        XCTAssertEqual(state.nearestRoute(relativeTo: now)?.routeId, "next")
        XCTAssertEqual(state.summary(relativeTo: now.addingTimeInterval(11)).status, "unavailable")
        XCTAssertFalse(state.isEnded)
    }

    func testLegacyAttributesRemainRestorable() throws {
        let json = """
        {"stationId":"22001","stationName":"강남역","routeId":"100","routeName":"341","expiresAt":1789430400}
        """
        let attributes = try JSONDecoder().decode(BusWaitingAttributes.self, from: Data(json.utf8))
        XCTAssertEqual(attributes.selectedRoutes.map(\.routeName), ["341"])
    }

    func testFourRouteActivityFitsActivityKitPayloadBudget() throws {
        let selections = (1...4).map { index in
            BusWaitingAttributes.Route(routeId: "gg:22700004\(index)", routeName: "1113-\(index)", boarding: BoardingSelection(
                boardingId: "gg:22700004\(index):104000069:1", routeRef: "gg:22700004\(index)",
                routeRevision: String(repeating: "a", count: 64), routeName: "1113-\(index)",
                stationRef: "gg:104000069", sequence: 1, directionId: "outbound", direction: "하남 방면"
            ))
        }
        let attributes = BusWaitingAttributes(stationId: "gg:104000069", stationName: "테크노마트앞.강변역 D",
            routeId: selections[0].routeId, routeName: selections[0].routeName, expiresAt: 1789430400, routes: selections)
        let content = BusWaitingAttributes.ContentState(status: "waiting", arrivalAt: 1789426980, remainingStops: 2,
            updatedAt: 1789426800, routes: selections.map { .init(routeId: $0.routeId, content: .init(
                status: "waiting", arrivalAt: 1789426980, remainingStops: 2, updatedAt: 1789426800)) })
        let size = try JSONEncoder().encode(attributes).count + JSONEncoder().encode(content).count
        XCTAssertLessThan(size, 4096)
    }

    func testSigningEnvironmentComesFromProvisioningProfile() {
        for (value, expected) in [("development", "sandbox"), ("production", "production")] {
            let profile = """
            binary-prefix<plist version="1.0"><dict><key>Entitlements</key><dict>
            <key>aps-environment</key><string>\(value)</string></dict></dict></plist>binary-suffix
            """
            XCTAssertEqual(PushEnvironment.provisioningEnvironment(Data(profile.utf8)), expected)
        }
        XCTAssertNil(PushEnvironment.provisioningEnvironment(Data("invalid".utf8)))
    }

    func testSessionCapabilityUsesSecureRandom256Bits() throws {
        let first = try LiveWaitStore.newSecret()
        let second = try LiveWaitStore.newSecret()
        XCTAssertEqual(first.count, 64)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })
    }

    func testGroupAPIEncodesLegacyAndBoardingRoutes() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GroupLiveAPIProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = try APIClient(baseURL: URL(string: "https://bus.example.test"), session: session)
        for boarding in [false, true] {
            let routes = (1...2).map { index in
                BusWaitingAttributes.Route(routeId: "route-\(index)", routeName: "\(index)", boarding: boarding ? BoardingSelection(
                    boardingId: "boarding-\(index)", routeRef: "route-\(index)", routeRevision: "rev",
                    routeName: "\(index)", stationRef: "gg:104000069", sequence: index,
                    directionId: "outbound", direction: "하남 방면"
                ) : nil)
            }
            let response = try await api.registerLiveWaitGroup(secret: String(repeating: "a", count: 64),
                stationId: "22001", routes: routes, pushToken: "token", environment: "production")
            XCTAssertEqual(response.content.routes?.count, 2)
        }
    }

    func testLiveWaitAPIRegistrationAndDeletion() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [LiveAPIProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let api = try APIClient(baseURL: URL(string: "https://bus.example.test"), session: session)
        let registration = try await api.registerLiveWait(
            secret: String(repeating: "a", count: 64), stationId: "22001", routeId: "100100341",
            pushToken: "token", environment: "production"
        )
        XCTAssertEqual(registration.expiresAt, 1_789_430_400)
        try await api.endLiveWait(secret: String(repeating: "a", count: 64))
    }
}

private final class LiveAPIProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.path, "/api/v1/live-activities")
        XCTAssertTrue(request.url?.query?.isEmpty ?? true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "a", count: 64))
        XCTAssertTrue(["POST", "DELETE"].contains(request.httpMethod ?? ""))
        if request.httpMethod == "POST" {
            // URLSession may move httpBody into a stream before URLProtocol sees it.
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
            }
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            XCTAssertEqual(body?["station_id"], "22001")
            XCTAssertEqual(body?["route_id"], "100100341")
            XCTAssertEqual(body?["environment"], "production")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"expires_at\":1789430400,\"content\":{\"status\":\"waiting\",\"arrivalAt\":null,\"remainingStops\":null,\"updatedAt\":1789426800}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class GroupLiveAPIProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let routes = body?["routes"] as? [[String: Any]]
        XCTAssertEqual(routes?.count, 2)
        XCTAssertNil(body?["route_id"])
        XCTAssertEqual(routes?.first?["route_id"] as? String, "route-1")
        XCTAssertEqual(body?["station_id"] as? String, "22001")
        let boarding = routes?.first?["boarding"] as? [String: Any]
        XCTAssertEqual(request.url?.path, boarding == nil ? "/api/v1/live-activities" : "/api/v2/live-activities")
        if let boarding {
            XCTAssertEqual(boarding["boarding_id"] as? String, "boarding-1")
            XCTAssertEqual(boarding["route_ref"] as? String, "route-1")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let json = """
        {"expires_at":1789430400,"content":{"status":"waiting","arrivalAt":1789426980,"remainingStops":2,"updatedAt":1789426800,"routes":[
          {"routeId":"route-1","content":{"status":"waiting","arrivalAt":1789426980,"remainingStops":2,"updatedAt":1789426800}},
          {"routeId":"route-2","content":{"status":"unavailable","arrivalAt":null,"remainingStops":null,"updatedAt":1789426800}}
        ]}}
        """
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
