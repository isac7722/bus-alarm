import XCTest
import CoreLocation

final class RouteMapUITests: XCTestCase {
    private let ids = ["gg:227000040", "gg:fixture-1", "gg:fixture-2", "gg:fixture-3"]
    private func launch(large: Bool = false, fixturePath: String = "", dark: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["BUS_WIDGET_TEST_API_URL"] = "http://127.0.0.1:8767\(fixturePath)"
        app.launchEnvironment["BUS_WIDGET_TEST_SUITE"] = "RouteMapUITests.\(UUID().uuidString)"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        if large || dark {
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
            let bottom = app.buttons["selection-wait"].exists ? app.buttons["selection-wait"].frame.minY - 12 : app.buttons["waiting-start"].exists ? app.buttons["waiting-start"].frame.minY - 12 : app.frame.maxY - 100
            let top = (app.navigationBars.allElementsBoundByIndex.last(where: \.isHittable)?.frame.maxY ?? 110) + 12
            if element.exists && element.isHittable && element.frame.midY > top && element.frame.midY < bottom { return }
            let scrollUp = element.exists && element.frame.midY < top ? false : up
            let distance = min(140, (bottom - top) * 0.5)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let from = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: scrollUp ? bottom - 8 : top + 8))
            let to = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: scrollUp ? bottom - 8 - distance : top + 8 + distance))
            // Stop at the destination to avoid flinging a short landscape list past the target.
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
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
        XCTAssertTrue(card.waitForExistence(timeout: 8)); reveal(card, in: app); card.tap()
        XCTAssertTrue(app.buttons["waiting-start"].waitForExistence(timeout: 5))
    }

    private func zoomToScale(_ meters: Int, in app: XCUIApplication) {
        let scale = app.descendants(matching: .any)["map-scale"].firstMatch
        XCTAssertTrue(scale.waitForExistence(timeout: 12))
        for _ in 0..<12 {
            let value = scale.value as? String ?? ""
            if value == "\(meters)m" { return }
            let current = Int(value.replacingOccurrences(of: "m", with: "")) ?? 0
            XCTAssertGreaterThan(current, 0)
            app.buttons[current > meters ? "map-zoom-in" : "map-zoom-out"].tap()
            expectation(for: NSPredicate { _, _ in (scale.value as? String) != value }, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
        }
        XCTFail("Could not reach \(meters)m scale: \(String(describing: scale.value))")
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
    func testMyLocationRecentersAndShowsCompactRefresh() {
        verifyMyLocation(dark: false)
    }
    func testMyLocationInDarkMode() {
        verifyMyLocation(dark: true)
    }
    func testLocationControlAtLargestTypeAndInLandscape() {
        let app = launch(large: true)
        let locate = app.buttons["my-location"]
        XCTAssertTrue(locate.waitForExistence(timeout: 10))
        XCTAssertTrue(locate.isHittable)
        XCTAssertGreaterThanOrEqual(locate.frame.height, 43.99)
        XCTAssertGreaterThanOrEqual(locate.frame.minX, 0)
        XCTAssertLessThanOrEqual(locate.frame.maxX, app.frame.maxX)
        attach("location-largest-type-dark")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        expectation(for: NSPredicate { _, _ in
            app.frame.width > app.frame.height && app.staticTexts["정류장 목록"].exists
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(locate.isHittable)
        XCTAssertGreaterThanOrEqual(locate.frame.minX, 0)
        XCTAssertLessThanOrEqual(locate.frame.maxX, app.frame.maxX)
        let previousLocation = XCUIDevice.shared.location
        defer { XCUIDevice.shared.location = previousLocation }
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 37.56675, longitude: 126.978))
        locate.tap()
        expectation(for: NSPredicate { _, _ in locate.isEnabled }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.staticTexts["위치를 찾지 못했어요. 지도와 목록에서 정류장을 고를 수 있어요."].exists)
        attach("location-largest-type-landscape")
    }
    private func verifyMyLocation(dark: Bool) {
        let previousLocation = XCUIDevice.shared.location
        defer { XCUIDevice.shared.location = previousLocation }
        let app = launch(dark: dark)
        let locate = app.buttons["my-location"]
        XCTAssertTrue(locate.waitForExistence(timeout: 10))
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 37.56675, longitude: 126.978))
        locate.tap()
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permission.waitForExistence(timeout: 3) {
            let allow = permission.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'While Using' OR label CONTAINS '앱을 사용하는 동안'")).firstMatch
            XCTAssertTrue(allow.exists)
            allow.tap()
        }
        let marker = app.images["map-user-location"]
        XCTAssertTrue(marker.waitForExistence(timeout: 12))
        XCTAssertTrue(locate.isEnabled)
        let original = marker.frame
        let refresh = app.buttons["이 지역 다시 찾기"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(refresh.frame.height, 43.99)
        XCTAssertLessThan(refresh.frame.width, 220)
        XCTAssertLessThan(refresh.frame.height, 52)
        attach(dark ? "my-location-dark" : "my-location-light")
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: original.midX - 55, dy: original.midY + 45))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 50, dy: 0)))
        expectation(for: NSPredicate { _, _ in abs(marker.frame.midX - original.midX) > 20 }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        locate.tap() // Same coordinates must still trigger a fresh camera request.
        expectation(for: NSPredicate { _, _ in
            marker.exists && abs(marker.frame.midX - original.midX) < 2 && abs(marker.frame.midY - original.midY) < 2
        }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        refresh.tap()
        XCTAssertTrue(app.buttons["station-row.gg:104000069"].waitForExistence(timeout: 5))
        XCTAssertEqual(marker.frame.midX, original.midX, accuracy: 2)
        XCTAssertEqual(marker.frame.midY, original.midY, accuracy: 2)
    }
    func testClusterExpandsToSeparateSelectableStations() {
        let app = launch(fixturePath: "/cluster")
        zoomToScale(200, in: app)
        let individual = app.buttons["station-pin.gg:104000069"]
        XCTAssertTrue(individual.waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["station-pin.gg:fixture-neighbor"].exists)
        attach("200m-all-stations-individual")
        zoomToScale(500, in: app)
        let cluster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "map-cluster.")).firstMatch
        XCTAssertTrue(cluster.waitForExistence(timeout: 12))
        XCTAssertEqual(cluster.label, "조회된 정류장 2개")
        attach("compact-marker-cluster")
        cluster.tap()
        let first = app.buttons["station-pin.gg:104000069"]
        let second = app.buttons["station-pin.gg:fixture-neighbor"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertTrue(second.waitForExistence(timeout: 8))
        XCTAssertEqual(first.frame.width, 44, accuracy: 0.01)
        XCTAssertEqual(second.frame.width, 44, accuracy: 0.01)
        attach("expanded-station-markers")
        first.tap()
        XCTAssertTrue(app.buttons["selection-wait"].waitForExistence(timeout: 8))
    }
    func testCoincidentStationsStayIndividuallySelectableAt200Meters() {
        let app = launch(fixturePath: "/coincident")
        zoomToScale(200, in: app)
        let first = app.buttons["station-pin.gg:104000069"]
        let second = app.buttons["station-pin.gg:fixture-neighbor"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertTrue(second.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(hypot(first.frame.midX - second.frame.midX, first.frame.midY - second.frame.midY), 43.9)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "map-cluster.")).firstMatch.exists)
        attach("200m-coincident-stations-spread")
        let originalFirst = first.frame
        let originalSecond = second.frame
        second.tap()
        XCTAssertTrue(app.buttons["selection-wait"].waitForExistence(timeout: 8))
        app.buttons["닫기"].firstMatch.tap()
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame.midX, originalFirst.midX, accuracy: 1, "Selecting a neighbor must not move this marker")
        XCTAssertEqual(first.frame.midY, originalFirst.midY, accuracy: 1)
        XCTAssertEqual(second.frame.midX, originalSecond.midX, accuracy: 1, "Selection must keep the tapped marker in place")
        XCTAssertEqual(second.frame.midY, originalSecond.midY, accuracy: 1)
        first.tap()
        XCTAssertTrue(app.buttons["selection-wait"].waitForExistence(timeout: 8))
        app.buttons["닫기"].firstMatch.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame.midX, originalFirst.midX, accuracy: 1)
        XCTAssertEqual(first.frame.midY, originalFirst.midY, accuracy: 1)
        XCTAssertEqual(second.frame.midX, originalSecond.midX, accuracy: 1)
        XCTAssertEqual(second.frame.midY, originalSecond.midY, accuracy: 1)
        second.tap()
        XCTAssertTrue(app.buttons["selection-wait"].waitForExistence(timeout: 8))
        app.buttons["닫기"].firstMatch.tap()
        zoomToScale(500, in: app)
        XCTAssertTrue(second.exists, "The selected stop must remain outside clusters")
        XCTAssertTrue(first.exists)
        attach("500m-selected-station-remains-individual")
    }
    func testCoincidentClusterExpandsIntoIndividualStops() {
        let app = launch(fixturePath: "/coincident")
        zoomToScale(500, in: app)
        let cluster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "map-cluster.")).firstMatch
        XCTAssertTrue(cluster.waitForExistence(timeout: 12))
        cluster.tap()
        let first = app.buttons["station-pin.gg:104000069"]
        let second = app.buttons["station-pin.gg:fixture-neighbor"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertTrue(second.waitForExistence(timeout: 8))
        XCTAssertGreaterThanOrEqual(hypot(first.frame.midX - second.frame.midX, first.frame.midY - second.frame.midY), 43.9)
        attach("coincident-cluster-expanded")
        first.tap()
        XCTAssertTrue(app.buttons["selection-wait"].waitForExistence(timeout: 8))
    }
    func testMapZoomAndSearchPreservePannedCamera() {
        let app = launch()
        let pin = app.buttons["station-pin.gg:104000069"]
        XCTAssertTrue(pin.waitForExistence(timeout: 12))
        app.buttons["map-zoom-in"].tap()
        app.buttons["map-zoom-out"].tap()
        let before = pin.frame
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: before.midX - 55, dy: before.midY + 50))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 45, dy: 0)))
        let refresh = app.buttons["이 지역 다시 찾기"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        let moved = NSPredicate { _, _ in abs(pin.frame.midX - before.midX) > 20 }
        expectation(for: moved, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        let afterPan = pin.frame
        refresh.tap()
        XCTAssertTrue(app.buttons["station-row.gg:104000069"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate { _, _ in app.activityIndicators.count == 0 }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(pin.frame.midX, afterPan.midX, accuracy: 8)
        app.buttons["목록으로 보기"].tap()
        app.buttons["지도로 보기"].tap()
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        XCTAssertEqual(pin.frame.midX, afterPan.midX, accuracy: 8)
        attach("naver-map-panned-after-search")
    }
    func testFavoriteCardPersistenceAndWaitingWithoutWidgetControls() {
        let app = launch()
        app.tabBars.buttons["즐겨찾기"].tap()
        let add = app.buttons["favorite-add-station"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        attach("favorite-empty-calm")
        add.tap()
        openStation(app, map: true)
        select(ids[0], in: app)
        saveFavorite(app)
        XCTAssertFalse(app.staticTexts["위젯에 표시 중"].exists)
        XCTAssertTrue(app.staticTexts["9304번 버스"].exists)
        XCTAssertTrue(app.buttons["favorite-add-station"].exists)
        attach("favorite-card-refreshed")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["favorite-add-station"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["9304번 버스"].exists)
        openFavorite(app)
        XCTAssertFalse(app.buttons["위젯에 표시"].exists)
        XCTAssertTrue(app.buttons["waiting-route.gg:227000040"].exists)
        XCTAssertTrue(app.buttons["waiting-start"].isEnabled)
        attach("favorite-waiting-without-widget")
    }
    func testMultipleWaitingRoutesCanBeSelectedAndCleared() {
        let app = launch()
        openStation(app)
        for id in ids { select(id, in: app) }
        saveFavorite(app)
        attach("favorite-card-four-routes")
        openFavorite(app)
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
        saveFavorite(app)
        attach("favorite-card-largest-type-dark")
        openFavorite(app)
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
