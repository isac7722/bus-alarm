import XCTest

final class RouteMapUITests: XCTestCase {
    private func launch(large: Bool = false) throws -> XCUIApplication {
        // This dedicated scheme is run by make test-route-ui, which owns port 8767.
        let base = "http://127.0.0.1:8767"
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["BUS_WIDGET_TEST_API_URL"] = base
        app.launchEnvironment["BUS_WIDGET_TEST_SUITE"] = "RouteMapUITests.\(UUID().uuidString)"
        if large {
            app.launchEnvironment["BUS_WIDGET_TEST_COLOR_SCHEME"] = "dark"
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }
    private func openRoute(_ app: XCUIApplication) {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("9304")
        let route = app.buttons["catalog-route.gg:227000040"]
        XCTAssertTrue(route.waitForExistence(timeout: 8)); route.tap()
        let picker = app.buttons["route-direction"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8)); picker.tap()
        app.buttons["하남 방면"].firstMatch.tap()
    }
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testRouteMapPinAndSave() throws {
        let app = try launch()
        openRoute(app)
        attach("route-map-light")
        let stop = app.buttons["route-pin.gg:227000040:104000069:1"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5)); stop.tap()
        let confirm = app.buttons["이 정류장에서 탈게요"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        let save = app.buttons["위젯에 저장"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        attach("route-review")
        save.tap()
        let saved = app.buttons["설정 변경"].waitForExistence(timeout: 8)
        if !saved { app.swipeUp(); attach("save-failure"); print(app.debugDescription) }
        XCTAssertTrue(saved)
        XCTAssertTrue(app.staticTexts["9304 · 하남 방면"].firstMatch.exists)
        attach("route-saved")
    }
    func testLargeTypeDarkListCanSelectStop() throws {
        let app = try launch(large: true)
        openRoute(app)
        let stop = app.buttons["route-stop.gg:227000040:104000069:1"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8)); stop.tap()
        let confirm = app.buttons["이 정류장에서 탈게요"]
        if !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.buttons["위젯에 저장"].waitForExistence(timeout: 5))
        attach("route-large-type-dark")
    }
    func testLandscapeList() throws {
        let app = try launch()
        openRoute(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.buttons["목록으로 보기"].tap()
        XCTAssertTrue(app.buttons["route-stop.gg:227000040:104000069:1"].waitForExistence(timeout: 5))
        attach("route-landscape")
    }
}
