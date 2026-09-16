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
        XCTAssertEqual(state.message(relativeTo: Date(timeIntervalSince1970: 1_789_426_981)), "도착 정보 확인 중")
        XCTAssertEqual(state.message(isStale: true), "도착 정보 갱신 지연")
        XCTAssertFalse(state.isEnded)
    }

    func testRegistrationDecodesAPIEnvelopeAndActivityContent() throws {
        let json = """
        {"expires_at":1789430400,"content":{"status":"unavailable","arrivalAt":null,"remainingStops":null,"updatedAt":1789426800}}
        """
        let response = try JSONDecoder.busWidget.decode(LiveWaitRegistration.self, from: Data(json.utf8))
        XCTAssertEqual(response.expiresAt, 1_789_430_400)
        XCTAssertNil(response.content.arrivalDate)
        XCTAssertEqual(response.content.message(), "도착 정보 갱신 지연")
    }

    func testFinalStatesStayFinalWhenStale() {
        for status in ["arrived", "passed", "expired", "cancelled"] {
            let state = BusWaitingAttributes.ContentState(status: status, arrivalAt: nil, remainingStops: nil, updatedAt: 1)
            XCTAssertTrue(state.isEnded)
            XCTAssertEqual(state.message(), state.message(isStale: true))
            XCTAssertNotEqual(state.message(isStale: true), "버스에 탑승했습니다")
        }
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
