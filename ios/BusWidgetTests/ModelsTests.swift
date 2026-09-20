import Foundation
import XCTest
@testable import BusWidgetApp

final class ModelsTests: XCTestCase {
    func testArrivalResponseDecodesSnakeCaseAndISO8601() throws {
        let json = """
        {
          "station": {"station_id":"22001","name":"강남역"},
          "updated_at":"2026-08-12T09:27:00+09:00",
          "fetched_at":"2026-08-12T00:27:01Z",
          "arrivals":[{
            "route_id":"100100341","route_name":"341",
            "predictions":[{
              "order":1,"arrival_at":"2026-08-12T09:30:00+09:00",
              "remaining_seconds":180,"remaining_stops":2,"vehicle_status":"RUNNING"
            }]
          }]
        }
        """

        let response = try JSONDecoder.busWidget.decode(ArrivalsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.station.stationId, "22001")
        XCTAssertEqual(response.arrivals.first?.predictions.first?.remainingSeconds, 180)
    }

    func testConfigurationLimitsRoutesToFour() {
        let configuration = WidgetConfigurationData(
            stationId: "22001",
            stationName: "강남역",
            routeIds: ["1", "2", "3", "4", "5"]
        )
        XCTAssertEqual(configuration.routeIds, ["1", "2", "3", "4"])
    }

    func testFreshnessBoundaries() {
        let updatedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(DataFreshness.status(updatedAt: updatedAt, relativeTo: updatedAt.addingTimeInterval(60)), .fresh)
        XCTAssertEqual(
            DataFreshness.status(updatedAt: updatedAt, relativeTo: updatedAt.addingTimeInterval(180)),
            .slightlyStale
        )
        XCTAssertEqual(
            DataFreshness.status(updatedAt: updatedAt, relativeTo: updatedAt.addingTimeInterval(299)),
            .delayed
        )
        XCTAssertEqual(
            DataFreshness.status(updatedAt: updatedAt, relativeTo: updatedAt.addingTimeInterval(300)),
            .needsRefresh
        )
    }

    func testArrivalCountdownUsesSecondsAndKeepsImminentAfterZero() {
        let now = Date(timeIntervalSince1970: 1_000)
        let cases: [(TimeInterval, String)] = [
            (3601, "60:01"), (601, "10:01"), (222, "3:42"), (180, "3:00"),
            (60.001, "1:01"), (60, "1:00"), (31, "0:31"), (30, "0:30"),
            (1, "0:01"), (0.001, "0:01"), (0, "곧 도착"), (-300, "곧 도착")
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(ArrivalCountdownFormatter.text(for: prediction(at: now.addingTimeInterval(seconds)), relativeTo: now),
                           expected, "Remaining seconds: \(seconds)")
        }
    }

    func testArrivalCountdownHandlesNonRunningStates() {
        let now = Date(timeIntervalSince1970: 1_000)
        let waiting = ArrivalPrediction(
            order: 1,
            arrivalAt: nil,
            remainingSeconds: nil,
            remainingStops: nil,
            vehicleStatus: .waiting
        )

        XCTAssertEqual(ArrivalCountdownFormatter.text(for: waiting, relativeTo: now), "운행 전")
        XCTAssertEqual(ArrivalCountdownFormatter.text(for: nil, relativeTo: now), "정보 없음")
    }

    func testNearestPredictionUsesEarliestArrivalRegardlessOfAPIRank() {
        let now = Date(timeIntervalSince1970: 1_000)
        let route = RouteArrival(
            routeId: "100900005",
            routeName: "종로08",
            predictions: [
                prediction(order: 1, at: now.addingTimeInterval(300)),
                prediction(order: 2, at: now.addingTimeInterval(240)),
            ]
        )

        XCTAssertEqual(route.nearestPrediction(relativeTo: now)?.order, 2)
        XCTAssertEqual(route.nearestPrediction(relativeTo: now.addingTimeInterval(250))?.order, 1)
    }

    func testNearestPredictionPrefersRunningBusAndFallsBackToWaiting() {
        let now = Date(timeIntervalSince1970: 1_000)
        let waiting = ArrivalPrediction(
            order: 1,
            arrivalAt: nil,
            remainingSeconds: nil,
            remainingStops: nil,
            vehicleStatus: .waiting
        )
        let running = prediction(order: 2, at: now.addingTimeInterval(180))

        XCTAssertEqual(
            RouteArrival(routeId: "1", routeName: "종로07", predictions: [waiting, running])
                .nearestPrediction(relativeTo: now),
            running
        )
        XCTAssertEqual(
            RouteArrival(routeId: "1", routeName: "종로07", predictions: [waiting])
                .nearestPrediction(relativeTo: now),
            waiting
        )
    }

    private func prediction(at arrivalAt: Date) -> ArrivalPrediction {
        prediction(order: 1, at: arrivalAt)
    }

    private func prediction(order: Int, at arrivalAt: Date) -> ArrivalPrediction {
        ArrivalPrediction(
            order: order,
            arrivalAt: arrivalAt,
            remainingSeconds: nil,
            remainingStops: nil,
            vehicleStatus: .running
        )
    }
}
