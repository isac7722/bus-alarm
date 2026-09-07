import XCTest
@testable import BusWidgetApp

final class ViewModelTests: XCTestCase {
    @MainActor
    func testBlankSearchReturnsToIdleWithoutNetworking() {
        let viewModel = StationSearchViewModel(client: nil)
        viewModel.query = "   "

        viewModel.queryDidChange()

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertEqual(viewModel.stations, [])
    }

    @MainActor
    func testRouteSelectionStopsAtFourAndAllowsDeselection() {
        let station = StationSummary(
            stationId: "22001",
            arsId: "22-001",
            name: "강남역",
            direction: nil,
            latitude: 37.5,
            longitude: 127.0
        )
        let viewModel = RouteSelectionViewModel(station: station, client: nil, store: nil)
        let routes = (1...5).map { RouteSummary(routeId: "\($0)", routeName: "노선 \($0)") }

        routes.forEach(viewModel.toggle)

        XCTAssertEqual(viewModel.selectedRouteIds.count, 4)
        XCTAssertTrue(viewModel.isDisabled(routes[4]))
        viewModel.toggle(routes[0])
        XCTAssertEqual(viewModel.selectedRouteIds.count, 3)
        XCTAssertFalse(viewModel.isDisabled(routes[4]))
    }
}
