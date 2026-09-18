import Foundation
import XCTest
import CoreLocation
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
    @MainActor
    func testUndoDeleteRestoresOriginalPositionWithoutLosingNewFavorites() throws {
        let storage = try store()
        let favorites = FavoritesStore(store: storage, client: nil)
        let first = SavedStop(configuration: WidgetConfigurationData(stationId: "1", stationName: "첫 정류장", routeIds: ["1"]))
        let second = SavedStop(configuration: WidgetConfigurationData(stationId: "2", stationName: "둘째 정류장", routeIds: ["2"]))
        let third = SavedStop(configuration: WidgetConfigurationData(stationId: "3", stationName: "새 정류장", routeIds: ["3"]))
        favorites.save(first); favorites.save(second)
        XCTAssertTrue(favorites.delete(first))
        favorites.save(third)
        favorites.undoDelete()
        XCTAssertEqual(favorites.items, [first, second, third])
        XCTAssertEqual(try storage.loadFavorites(), favorites.items)
        XCTAssertNil(favorites.deletedFavorite)
    }

    @MainActor
    func testUndoDoesNotDuplicateOrOverwriteNewlySavedEquivalentFavorite() throws {
        let favorites = FavoritesStore(store: try store(), client: nil)
        let original = SavedStop(configuration: WidgetConfigurationData(stationId: "1", stationName: "정류장", routeIds: ["1"]))
        favorites.save(original); favorites.delete(original)
        let refreshed = SavedStop(configuration: original.configuration, nickname: "새 이름")
        favorites.save(refreshed); favorites.undoDelete()
        XCTAssertEqual(favorites.items, [refreshed])
        favorites.announceSave(SavedStop(configuration: original.configuration))
        XCTAssertEqual(favorites.saveNotice?.favoriteID, refreshed.id)
    }

    @MainActor
    func testOldDeletionTimeoutDoesNotClearNewUndoAndFailedDeleteHasNoUndo() throws {
        let favorites = FavoritesStore(store: try store(), client: nil)
        let first = SavedStop(configuration: WidgetConfigurationData(stationId: "1", stationName: "정류장", routeIds: ["1"]))
        favorites.save(first); favorites.delete(first)
        let oldID = try XCTUnwrap(favorites.deletedFavorite?.id)
        favorites.undoDelete(); favorites.delete(first)
        favorites.expireDeletion(oldID)
        XCTAssertNotNil(favorites.deletedFavorite)
        let failed = FavoritesStore(store: nil, client: nil)
        XCTAssertFalse(failed.delete(first))
        XCTAssertNil(failed.deletedFavorite)
    }

    @MainActor
    func testFavoriteDeduplicationRetainsIdentityAndDifferentDirection() throws {
        let favorites = FavoritesStore(store: try store())
        let config = WidgetConfigurationData(validated: ValidatedSelection(station: testMapStation, selections: [boarding()]))
        let first = SavedStop(configuration: config, nickname: "퇴근길")
        favorites.save(first)
        favorites.save(SavedStop(configuration: config))
        XCTAssertEqual(favorites.items.count, 1)
        XCTAssertEqual(favorites.items.first?.id, first.id)
        XCTAssertEqual(favorites.items.first?.nickname, "퇴근길")
        let opposite = WidgetConfigurationData(validated: ValidatedSelection(station: testMapStation, selections: [boarding(4)]))
        favorites.save(SavedStop(configuration: opposite))
        XCTAssertEqual(favorites.items.count, 2)
    }

    @MainActor
    func testArrivalPreviewRetainsOldETAAndClearsWhenSelectionIsEmpty() async throws {
        let config = WidgetConfigurationData(validated: ValidatedSelection(station: testMapStation, selections: [boarding(4)]))
        let model = CommuteArrivalsModel(api: try api())
        await model.refresh(config)
        XCTAssertEqual(model.label("gg:227000040", at: Date(timeIntervalSince1970: 1030)), "2분")
        XCTAssertNotNil(model.upcoming("gg:227000040", at: Date(timeIntervalSince1970: 1091)))
        XCTAssertEqual(model.label("gg:227000040", at: Date(timeIntervalSince1970: 1121)), "다시 연결 중")
        await model.refresh(config.selecting([]))
        XCTAssertNil(model.response)
        XCTAssertFalse(model.loading)
    }

    @MainActor
    func testArrivalFailureIsNotShownAsNoArrivals() async {
        let model = CommuteArrivalsModel(api: nil)
        await model.refresh(WidgetConfigurationData(validated: ValidatedSelection(station: testMapStation, selections: [boarding()])))
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.label("gg:227000040", at: .now), "조회 실패")
    }

    @MainActor
    func testStationFirstSelectionLimitAndValidationFailure() async throws {
        let model = StationBusViewModel(station: testMapStation, api: try api("changed.test"))
        XCTAssertFalse(model.canContinue)
        model.toggle(occurrence())
        for n in 1...4 { model.toggle(occurrence(route: "gg:20000000\(n)")) }
        XCTAssertEqual(model.selections.count, 4)
        XCTAssertTrue(model.disabled(occurrence(route: "gg:200000004")))
        model.toggle(occurrence(4))
        XCTAssertEqual(model.selections.first?.sequence, 4)
        let result = await model.validate()
        XCTAssertNil(result)
        XCTAssertEqual(model.selections.count, 4)
        XCTAssertNotNil(model.error)
        model.toggle(occurrence(4))
        XCTAssertEqual(model.selections.count, 3)
    }

    @MainActor
    func testLegacyGyeonggiFavoriteOnlyPreselectsUnambiguousBoarding() async throws {
        let legacy = SavedStop(configuration: WidgetConfigurationData(stationId: "05267", stationName: "강변역", routeIds: ["gg:227000040", "gg:123"]))
        let model = StationBusViewModel(station: testMapStation, favorite: legacy, api: try api())
        await model.load()
        XCTAssertEqual(model.selections, [boarding()], "Two visits of the other route require an explicit direction choice")
    }

    func testSavedBoardingNamesAppearWithoutSeparateRouteMetadata() {
        let configuration = WidgetConfigurationData(validated: ValidatedSelection(station: testMapStation, selections: [boarding()]))
        let favorite = SavedStop(configuration: configuration, routes: [])
        XCTAssertEqual(favorite.displayRoutes.map(\.routeName), ["9304"])
        XCTAssertEqual(favorite.directions, ["하남 방면"])
        XCTAssertFalse(favorite.hasMissingRouteNames)
    }

    @MainActor
    func testLegacyRouteNamesAreFetchedAndPersistedWithoutChangingSelection() async throws {
        let storage = try store()
        let favorites = FavoritesStore(store: storage, client: try api())
        let old = SavedStop(configuration: WidgetConfigurationData(stationId: "05267", stationName: "강변역", routeIds: ["gg:227000040"]), nickname: "퇴근길")
        favorites.save(old)
        await favorites.hydrateLegacyNames()
        XCTAssertEqual(favorites.items.first?.displayRoutes.map(\.routeName), ["9304"])
        XCTAssertEqual(favorites.items.first?.configuration, old.configuration)
        XCTAssertEqual(try storage.loadFavorites().first?.nickname, "퇴근길")
        XCTAssertEqual(try storage.loadFavorites().first?.displayRoutes.map(\.routeName), ["9304"])
        XCTAssertTrue(favorites.loadingNames.isEmpty)
    }

    @MainActor
    func testFailedNameLookupKeepsFavoriteAndAllowsRetry() async throws {
        let storage = try store()
        let favorites = FavoritesStore(store: storage, client: try api("gateway.test"))
        let old = SavedStop(configuration: WidgetConfigurationData(stationId: "05267", stationName: "강변역", routeIds: ["gg:227000040"]))
        favorites.save(old)
        await favorites.hydrateLegacyNames()
        XCTAssertEqual(favorites.items, [old])
        XCTAssertTrue(favorites.loadingNames.isEmpty)
        XCTAssertNil(favorites.error, "Metadata failure must not block saving or deleting favorites")
        let retry = FavoritesStore(store: storage, client: try api())
        await retry.hydrateLegacyNames()
        XCTAssertFalse(try XCTUnwrap(retry.items.first).hasMissingRouteNames)
    }

    @MainActor
    func testLateRouteMetadataCannotRestoreDeletedOrEditedFavorite() throws {
        let favorites = FavoritesStore(store: try store(), client: nil)
        let old = SavedStop(configuration: WidgetConfigurationData(stationId: "05267", stationName: "강변역", routeIds: ["gg:227000040"]))
        let metadata = [RouteSummary(routeId: "gg:227000040", routeName: "9304")]
        favorites.save(old)
        var renamed = old; renamed.nickname = "퇴근길"
        favorites.save(renamed)
        favorites.updateRouteNames(metadata, for: old)
        XCTAssertEqual(favorites.items.first?.nickname, "퇴근길")
        var edited = old
        edited.configuration = WidgetConfigurationData(stationId: "22001", stationName: "강남역", routeIds: ["123"])
        favorites.save(edited)
        favorites.updateRouteNames(metadata, for: old)
        XCTAssertEqual(favorites.items, [edited])
        favorites.delete(edited)
        favorites.updateRouteNames(metadata, for: old)
        XCTAssertTrue(favorites.items.isEmpty)
    }

    @MainActor
    func testBusSearchSurvivesStationSearchFailureAndShowsProviderWarning() async throws {
        let model = StationFinderViewModel(api: try api("gateway.test"))
        model.query = "9304"
        model.search()
        for _ in 0..<100 where model.loading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.routes.map(\.id), [testCatalogRoute.id])
        XCTAssertTrue(model.stations.isEmpty)
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.routeWarning?.contains("서울") == true)
    }

    @MainActor
    func testRouteSearchFailureDoesNotEraseStationResult() async throws {
        let model = StationFinderViewModel(api: try api("route-failure.test"))
        model.query = "05267"
        model.search()
        for _ in 0..<100 where model.loading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.stations.first?.displayNumber, "05267")
        XCTAssertTrue(model.routes.isEmpty)
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.routeWarning)
    }

    @MainActor
    func testCancelledSearchCannotReplaceNewQuery() async throws {
        let model = StationFinderViewModel(api: try api())
        model.query = "9304"; model.search(); model.cancel()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.routes.isEmpty)
        XCTAssertFalse(model.loading)
        model.query = "05267"; model.search()
        for _ in 0..<100 where model.loading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.query, "05267")
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.routes.isEmpty)
    }

    @MainActor
    func testRouteWithoutLocationStartsWithAllStopsAndKeepsDirectionsDistinct() async throws {
        let model = RouteStopFinderViewModel(route: testCatalogRoute, api: try api())
        await model.load(coordinate: nil)
        XCTAssertEqual(model.scope, .all)
        XCTAssertEqual(model.visibleStops.map(\.sequence), [1, 4])
        XCTAssertEqual(model.mapStations.count, 1)
        XCTAssertNil(model.selected)
        model.focus(testMapStation)
        XCTAssertNil(model.selected, "A shared map pin must not silently choose a direction")
        XCTAssertEqual(model.visibleStops.count, 2)
        model.select(occurrence(4))
        XCTAssertEqual(model.selected?.directionId, "inbound")
        model.show(.nearby, coordinate: CLLocationCoordinate2D(latitude: 37.535, longitude: 127.094))
        XCTAssertEqual(model.scope, .nearby)
        XCTAssertEqual(model.selected?.sequence, 4)
        model.show(.all, coordinate: nil)
        XCTAssertEqual(model.visibleStops.count, 2)
        model.show(.nearby, coordinate: CLLocationCoordinate2D(latitude: 35, longitude: 128))
        XCTAssertEqual(model.scope, .all)
        XCTAssertTrue(model.notice?.contains("1km") == true)
    }

    @MainActor
    func testNearbyRankingDoesNotDropStopsFromAllViewOrInventMissingCoordinates() {
        let origin = CLLocationCoordinate2D(latitude: 37.535, longitude: 127.094)
        let original = occurrence()
        func at(_ id: String, latitude: Double?, longitude: Double?) -> RouteStopOccurrence {
            let station = MapStation(stationRef: id, name: id, displayNumber: "", latitude: latitude, longitude: longitude)
            return RouteStopOccurrence(boardingId: id, routeRef: original.routeRef, routeRevision: original.routeRevision,
                routeName: original.routeName, stationRef: id, sequence: 10, directionId: original.directionId,
                direction: original.direction, station: station, nextStop: "", selectable: true, reason: nil)
        }
        let near = at("near", latitude: 37.536, longitude: 127.094)
        let far = at("far", latitude: 36, longitude: 128)
        let missing = at("missing", latitude: nil, longitude: nil)
        let result = RouteStopFinderViewModel.nearby([far, near, missing, original], coordinate: origin)
        XCTAssertEqual(result.map(\.id), [original.id, near.id])
        XCTAssertNil(RouteStopFinderViewModel.point(missing.station))
    }

    @MainActor
    func testPreselectionKeepsExactDirectionAndSurvivesOptionsRefreshAndValidationFailure() async throws {
        let model = StationBusViewModel(station: testMapStation, preselected: occurrence(4), api: try api("changed.test"))
        XCTAssertTrue(model.canContinue)
        XCTAssertEqual(model.selections, [boarding(4)])
        await model.load()
        XCTAssertEqual(model.selections, [boarding(4)])
        let result = await model.validate()
        XCTAssertNil(result)
        XCTAssertEqual(model.selections, [boarding(4)])
        XCTAssertNotNil(model.error)
    }

    @MainActor
    func testNearbyLocationRequiresRecentAccurateFix() {
        let now = Date()
        func fix(age: Double, accuracy: Double) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 37.5, longitude: 127), altitude: 0,
                       horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(StationLocationService.isUsableForNearby(fix(age: 30, accuracy: 50), now: now))
        XCTAssertFalse(StationLocationService.isUsableForNearby(fix(age: 121, accuracy: 50), now: now))
        XCTAssertFalse(StationLocationService.isUsableForNearby(fix(age: 0, accuracy: 151), now: now))
        XCTAssertFalse(StationLocationService.isUsableForNearby(fix(age: 0, accuracy: -1), now: now))
    }

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
    func testStationSearchWithNoMatchesReturnsEmptyList() async throws {
        let stations = try await api().searchStations(query: "9304")
        XCTAssertTrue(stations.isEmpty)
    }
    func testStationSearchGatewayFailureIsNotAnEmptyResult() async throws {
        do {
            _ = try await api("gateway.test").searchStations(query: "9304")
            XCTFail("A gateway failure must not be treated as no matching stations")
        } catch let error as APIClientError {
            XCTAssertEqual(error, .server(code: "HTTP_502", message: "서버에 일시적인 문제가 발생했습니다. 잠시 후 다시 시도해 주세요."))
        }
    }
}

private final class RouteTestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var status = 200
        let data: Data
        switch request.url?.path {
        case "/api/v1/stations/search":
            if request.url?.host == "gateway.test" {
                status = 502
                data = Data("error code: 502".utf8)
            } else if request.url?.host == "route-failure.test" {
                data = Data(#"{"stations":[{"station_id":"05267","name":"강변역","ars_id":"05267","latitude":37.535,"longitude":127.094}]}"#.utf8)
            } else {
                data = Data(#"{"stations":[]}"#.utf8)
            }
        case "/api/v2/routes/search":
            if request.url?.host == "route-failure.test" {
                status = 502; data = Data("gateway error".utf8)
            } else {
                data = try! JSONEncoder.busWidget.encode(CatalogSearchResponse(routes: [testCatalogRoute], providers: [
                    ProviderStatus(provider: "gg", available: true, message: nil),
                    ProviderStatus(provider: "seoul", available: false, message: "일부 결과를 조회하지 못했습니다.")
                ]))
            }
        case "/api/v1/stations/05267":
            if request.url?.host == "gateway.test" {
                status = 502; data = Data("error code: 502".utf8)
            } else {
                data = try! JSONEncoder.busWidget.encode(StationDetailResponse(
                    station: StationSummary(stationId: "05267", arsId: "05267", name: "강변역", direction: nil, latitude: 37.535, longitude: 127.094),
                    routes: [RouteSummary(routeId: "gg:227000040", routeName: "9304"), RouteSummary(routeId: "unselected", routeName: "123")]))
            }
        case "/api/v2/routes/gg:227000040":
            data = try! JSONEncoder.busWidget.encode(CatalogDetail(route: testCatalogRoute, revision: "revision-a", directions: [RouteDirection(id: "outbound", name: "하남 방면"), RouteDirection(id: "inbound", name: "강변역 방면")], stops: [occurrence(), occurrence(4)]))
        case "/api/v2/routes/gg:227000040/geometry":
            data = Data(#"{"coordinates":[],"source":"stops"}"#.utf8)
        case "/api/v2/stations/gg:104000069/boarding-options":
            data = try! JSONEncoder.busWidget.encode(BoardingOptions(station: testMapStation, options: [occurrence(), occurrence(route: "gg:123"), occurrence(4, route: "gg:123")], complete: true, warnings: []))
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
            data = try! JSONEncoder.busWidget.encode(ArrivalsResponse(station: ArrivalStation(stationId: testMapStation.id, name: "강변역"), updatedAt: Date(timeIntervalSince1970: 1000), fetchedAt: Date(timeIntervalSince1970: 1000), arrivals: [
                RouteArrival(routeId: "gg:227000040", routeName: "9304", predictions: [
                    ArrivalPrediction(order: 1, arrivalAt: Date(timeIntervalSince1970: 1120), remainingSeconds: 120, remainingStops: 2, vehicleStatus: .running)
                ])
            ]))
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
