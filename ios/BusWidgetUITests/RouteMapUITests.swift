import XCTest

final class RouteMapUITests: XCTestCase {
    private let ids = ["gg:227000040", "gg:fixture-1", "gg:fixture-2", "gg:fixture-3"]
    private func launch(large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["BUS_WIDGET_TEST_API_URL"] = "http://127.0.0.1:8767"
        app.launchEnvironment["BUS_WIDGET_TEST_SUITE"] = "RouteMapUITests.\(UUID().uuidString)"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        if large {
            app.launchEnvironment["BUS_WIDGET_TEST_COLOR_SCHEME"] = "dark"
        }
        app.launch()
        return app
    }
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, up: Bool = true) {
        for _ in 0..<18 {
            let bottom = app.buttons["selection-wait"].exists ? app.buttons["selection-wait"].frame.minY - 50 : app.buttons["waiting-start"].exists ? app.buttons["waiting-start"].frame.minY - 50 : app.frame.maxY - 100
            let top = (app.navigationBars.allElementsBoundByIndex.filter(\.isHittable).map { $0.frame.maxY }.max() ?? 110) + 12
            if element.exists && element.isHittable && element.frame.midY > top && element.frame.midY < bottom { return }
            let scrollUp = element.exists && element.frame.midY < top ? false : up
            let distance = min(180, (bottom - top) * 0.65)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let from = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: scrollUp ? bottom - 8 : top + 8))
            let to = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: scrollUp ? bottom - 8 - distance : top + 8 + distance))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        attach("unreachable-control")
        print(app.debugDescription)
        XCTFail("Cannot reach \(element)")
    }
    private func openStation(_ app: XCUIApplication, map: Bool = false) {
        let station = app.buttons["\(map ? "station-pin" : "station-row").gg:104000069"]
        XCTAssertTrue(station.waitForExistence(timeout: 12))
        attach(map ? "station-map" : "station-list")
        station.tap()
        XCTAssertTrue(app.buttons["selection-wait"].waitForExistence(timeout: 8))
    }
    private func select(_ route: String, in app: XCUIApplication) {
        let option = app.buttons["boarding-option.\(route):104000069:1"]
        reveal(option, in: app)
        option.tap()
    }
    private func saveFavorite(_ app: XCUIApplication) {
        let save = app.buttons["save-favorite"]
        reveal(save, in: app)
        save.tap()
        XCTAssertTrue(app.buttons["즐겨찾기에 저장됨"].waitForExistence(timeout: 5) || !save.isEnabled)
        attach("favorite-selection-saved")
        app.buttons["닫기"].firstMatch.tap()
        app.tabBars.buttons["즐겨찾기"].tap()
    }
    private func openFavorite(_ app: XCUIApplication) {
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "favorite.")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8)); card.tap()
        XCTAssertTrue(app.buttons["waiting-start"].waitForExistence(timeout: 5))
    }

    func testStationSearchWithNoMatchesShowsEmptyState() {
        let app = launch()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("9304")
        XCTAssertTrue(app.staticTexts["정류장이 없습니다."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["서버 응답을 처리할 수 없습니다."].exists)
        attach("station-search-empty")
    }
    func testMapSelectionFavoritePersistenceAndExplicitWidgetPin() {
        let app = launch()
        openStation(app, map: true)
        select(ids[0], in: app)
        saveFavorite(app)
        XCTAssertFalse(app.staticTexts["위젯에 표시 중"].exists)
        app.terminate(); app.launch()
        openFavorite(app)
        let pin = app.buttons["위젯에 표시"]
        reveal(pin, in: app); pin.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["확인"].tap()
        XCTAssertTrue(app.buttons["위젯에 표시 중"].exists)
        attach("favorite-widget-pinned")
    }
    func testMultipleWaitingRoutesCanBeSelectedAndCleared() {
        let app = launch()
        openStation(app)
        for id in ids { select(id, in: app) }
        saveFavorite(app); openFavorite(app)
        let start = app.buttons["waiting-start"]
        XCTAssertTrue(start.isEnabled); XCTAssertTrue(start.label.contains("4개"))
        attach("favorite-four-routes")
        for id in ids {
            let route = app.buttons["waiting-route.\(id)"]
            reveal(route, in: app); route.tap()
        }
        XCTAssertFalse(start.isEnabled)
        reveal(app.buttons["waiting-route.gg:fixture-3"], in: app)
        app.buttons["waiting-route.gg:fixture-3"].tap()
        XCTAssertTrue(start.isEnabled); XCTAssertTrue(start.label.contains("1개"))
        app.terminate(); app.launch(); openFavorite(app)
        XCTAssertTrue(app.buttons["waiting-start"].label.contains("4개"), "Today's selection must not overwrite the favorite")
    }
    func testLargeTypeDarkSelectionAndLandscape() {
        let app = launch(large: true)
        openStation(app)
        select(ids[0], in: app)
        saveFavorite(app); openFavorite(app)
        let route = app.buttons["waiting-route.gg:227000040"]
        reveal(route, in: app); route.tap()
        XCTAssertFalse(app.buttons["waiting-start"].isEnabled)
        attach("favorite-largest-type-dark")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["waiting-start"].exists)
        attach("favorite-largest-type-landscape")
    }
    func testLandscapeStationList() {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        openStation(app)
        select(ids[0], in: app)
        XCTAssertTrue(app.buttons["selection-wait"].isEnabled)
        attach("station-selection-landscape")
    }
}
