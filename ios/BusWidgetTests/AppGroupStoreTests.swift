import Foundation
import XCTest
@testable import BusWidgetApp

final class AppGroupStoreTests: XCTestCase {
    func testConfigurationAndCachedArrivalsRoundTrip() throws {
        let suiteName = "BusWidgetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = try XCTUnwrap(AppGroupStore(suiteName: suiteName))
        let configuration = WidgetConfigurationData(
            stationId: "22001",
            stationName: "강남역",
            routeIds: ["100100341", "100100360"]
        )
        let updatedAt = Date(timeIntervalSince1970: 1_786_499_220)
        let arrivals = ArrivalsResponse(
            station: ArrivalStation(stationId: "22001", name: "강남역"),
            updatedAt: updatedAt,
            fetchedAt: updatedAt,
            arrivals: []
        )

        try store.saveConfiguration(configuration)
        try store.saveCachedArrivals(arrivals)

        XCTAssertEqual(store.loadConfiguration(), configuration)
        XCTAssertEqual(store.loadCachedArrivals(), arrivals)
    }
}
