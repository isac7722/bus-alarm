import Foundation
import XCTest
@testable import BusWidgetApp

final class TimelineBuilderTests: XCTestCase {
    func testEventDatesIncludeArrivalsAndFreshnessTransitionsBeforeRefresh() {
        let now = Date(timeIntervalSince1970: 1_000)
        let response = ArrivalsResponse(
            station: ArrivalStation(stationId: "22001", name: "강남역"),
            updatedAt: now,
            fetchedAt: now,
            arrivals: [
                RouteArrival(
                    routeId: "1",
                    routeName: "341",
                    predictions: [
                        ArrivalPrediction(
                            order: 1,
                            arrivalAt: now.addingTimeInterval(120),
                            remainingSeconds: 120,
                            remainingStops: 1,
                            vehicleStatus: .running
                        )
                    ]
                )
            ]
        )

        let dates = WidgetTimelineBuilder.eventDates(
            response: response,
            now: now,
            refreshDate: now.addingTimeInterval(240)
        )

        XCTAssertEqual(dates, [now, now.addingTimeInterval(60), now.addingTimeInterval(120), now.addingTimeInterval(180)])
    }

    func testEventDatesIncludeMinuteTicksForCompactCountdown() {
        let now = Date(timeIntervalSince1970: 1_000)
        let response = ArrivalsResponse(
            station: ArrivalStation(stationId: "22001", name: "강남역"),
            updatedAt: now,
            fetchedAt: now,
            arrivals: []
        )

        let dates = WidgetTimelineBuilder.eventDates(
            response: response,
            now: now,
            refreshDate: now.addingTimeInterval(170)
        )

        XCTAssertEqual(dates, [now, now.addingTimeInterval(60), now.addingTimeInterval(120)])
    }
}
