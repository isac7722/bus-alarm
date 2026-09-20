import XCTest
import MapKit
@testable import BusWidgetApp

final class TransitMarkerTests: XCTestCase {
    func testLocationRegionShows150MeterRadiusAtDifferentLatitudes() {
        for latitude in [0.0, 37.5665, 60] {
            let center = CLLocationCoordinate2D(latitude: latitude, longitude: 126.978)
            let region = TransitMapCamera.locationRegion(center: center)
            let origin = CLLocation(latitude: latitude, longitude: center.longitude)
            let north = CLLocation(latitude: latitude + region.span.latitudeDelta / 2, longitude: center.longitude)
            let east = CLLocation(latitude: latitude, longitude: center.longitude + region.span.longitudeDelta / 2)
            XCTAssertEqual(origin.distance(from: north), 150, accuracy: 2)
            XCTAssertEqual(origin.distance(from: east), 150, accuracy: 2)
        }
    }

    @MainActor
    func testLocationPulseStopsWhenDisabledHiddenOrDetachedWithoutHidingAnchor() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        let marker = TransitUserLocationView()
        window.addSubview(marker)
        let halo = marker.subviews[0]
        let dot = marker.subviews[1]
        marker.setPulsing(true)
        XCTAssertNotNil(halo.layer.animation(forKey: "location-pulse"))
        marker.setPulsing(false) // Reduced motion or an inactive scene.
        XCTAssertNil(halo.layer.animation(forKey: "location-pulse"))
        XCTAssertFalse(marker.isHidden)
        XCTAssertEqual(dot.alpha, 1)
        XCTAssertNil(dot.layer.animationKeys())
        marker.setPulsing(true)
        marker.isHidden = true
        XCTAssertNil(halo.layer.animation(forKey: "location-pulse"))
        marker.isHidden = false
        XCTAssertNotNil(halo.layer.animation(forKey: "location-pulse"))
        marker.removeFromSuperview()
        XCTAssertNil(halo.layer.animation(forKey: "location-pulse"))
    }

    @MainActor
    func testRepeatedLocationFixPublishesARecenterEventEvenForSameCoordinates() {
        let manager = LocationTestManager()
        let service = StationLocationService(manager: manager)
        let fix = CLLocation(latitude: 37.5665, longitude: 126.978)
        service.request()
        service.locationManager(manager, didUpdateLocations: [fix])
        let firstID = service.updateID
        service.request()
        service.locationManager(manager, didUpdateLocations: [fix])
        XCTAssertNotEqual(service.updateID, firstID)
        XCTAssertEqual(service.coordinate?.latitude, fix.coordinate.latitude)
        XCTAssertEqual(service.coordinate?.longitude, fix.coordinate.longitude)
        XCTAssertFalse(service.isLocating)
    }

    @MainActor
    func testFailedLocationRequestClearsOldAnchorAndAllowsRetry() {
        let manager = LocationTestManager()
        let service = StationLocationService(manager: manager)
        service.request()
        service.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 37.5665, longitude: 126.978)])
        let previousID = service.updateID
        service.request()
        service.locationManager(manager, didFailWithError: CLError(.denied))
        XCTAssertNil(service.coordinate)
        XCTAssertFalse(service.isLocating)
        XCTAssertNotNil(service.message)
        XCTAssertEqual(service.updateID, previousID, "A failed lookup must not recenter to an old location")
    }

    @MainActor
    func testLateLocationFailureDoesNotEraseSuccessfulFix() {
        let manager = LocationTestManager()
        let service = StationLocationService(manager: manager)
        service.request()
        service.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 37.5665, longitude: 126.978)])
        service.locationManager(manager, didFailWithError: CLError(.locationUnknown))
        XCTAssertNotNil(service.coordinate)
        XCTAssertNil(service.message)
        XCTAssertFalse(service.isLocating)
    }

    func testZoomThresholdsHaveHysteresisAndPermitLargeJumps() {
        XCTAssertEqual(TransitMarkerDetail.overview.updated(zoom: 14.6), .overview)
        XCTAssertEqual(TransitMarkerDetail.overview.updated(zoom: 14.8), .neighborhood)
        XCTAssertEqual(TransitMarkerDetail.neighborhood.updated(zoom: 14.4), .neighborhood)
        XCTAssertEqual(TransitMarkerDetail.neighborhood.updated(zoom: 14.2), .overview)
        XCTAssertEqual(TransitMarkerDetail.neighborhood.updated(zoom: 16.8), .street)
        XCTAssertEqual(TransitMarkerDetail.street.updated(zoom: 16.4), .street)
        XCTAssertEqual(TransitMarkerDetail.street.updated(zoom: 16.2), .neighborhood)
        XCTAssertEqual(TransitMarkerDetail.overview.updated(zoom: 19), .street)
        XCTAssertEqual(TransitMarkerDetail.street.updated(zoom: 12), .overview)
    }

    func testNearbyStopsSeparateAfterZoomingAndNoneAreLost() {
        let points = [TransitMarkerPoint(id: "a", point: .zero),
                      TransitMarkerPoint(id: "b", point: CGPoint(x: 7.5, y: 0)),
                      TransitMarkerPoint(id: "c", point: CGPoint(x: 200, y: 0))]
        let grouped = TransitMarkerLayout.groups(points, scaleMeters: 500)
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(Set(grouped.flatMap { $0.members.map(\.id) }), Set(["a", "b", "c"]))
        let zoomed = points.map { TransitMarkerPoint(id: $0.id, point: CGPoint(x: $0.point.x * 4, y: $0.point.y * 4)) }
        XCTAssertEqual(TransitMarkerLayout.groups(zoomed, scaleMeters: 200).count, 3)
    }

    func testDenseGroupsHaveBoundedExtentAndStableMembership() {
        let points = (0..<200).map { i in
            TransitMarkerPoint(id: String(format: "%03d", i), point: CGPoint(x: CGFloat(i % 20) * 5, y: CGFloat(i / 20) * 7.5))
        }
        let groups = TransitMarkerLayout.groups(points, scaleMeters: 500)
        let reversed = TransitMarkerLayout.groups(points.reversed(), scaleMeters: 500)
        XCTAssertEqual(groups.map { $0.members.map(\.id) }, reversed.map { $0.members.map(\.id) })
        XCTAssertEqual(groups.flatMap { $0.members }.count, 200)
        for group in groups {
            XCTAssertLessThanOrEqual(group.members.map { $0.point.x }.max()! - group.members.map { $0.point.x }.min()!, 56)
            XCTAssertLessThanOrEqual(group.members.map { $0.point.y }.max()! - group.members.map { $0.point.y }.min()!, 56)
        }
    }

    func testOnlyOverlappingStopsClusterFrom500MetersAndSelectedStopsRemainIndividual() {
        let points = [TransitMarkerPoint(id: "a", point: .zero),
                      TransitMarkerPoint(id: "b", point: .zero),
                      TransitMarkerPoint(id: "c", point: CGPoint(x: 80, y: 0))]
        for scale in [0.0, 50, 100, 200, 300, 499] {
            XCTAssertEqual(TransitMarkerLayout.groups(points, scaleMeters: scale).count, 3)
        }
        XCTAssertEqual(TransitMarkerLayout.groups(points, scaleMeters: 500).count, 2)
        XCTAssertEqual(TransitMarkerLayout.groups(points, scaleMeters: 1_000, protectedIDs: ["a"]).count, 3)
        let farther = [points[0], TransitMarkerPoint(id: "d", point: CGPoint(x: 32, y: 0))]
        XCTAssertEqual(TransitMarkerLayout.groups(farther, scaleMeters: 500).count, 2)
        XCTAssertEqual(TransitMarkerLayout.groups(farther, scaleMeters: 1_000).count, 1)
    }

    func testScaleBarRoundingKeeps200And500MeterPoliciesDistinct() {
        for distance in [190.0, 199.8, 200, 210] {
            XCTAssertEqual(TransitMarkerLayout.scaleMeters(barDistance: distance), 200)
        }
        for distance in [480.0, 499.5, 500, 510] {
            XCTAssertEqual(TransitMarkerLayout.scaleMeters(barDistance: distance), 500)
        }
        XCTAssertEqual(TransitMarkerLayout.scaleMeters(barDistance: .nan), 0)
        XCTAssertEqual(TransitMarkerLayout.scaleMeters(barDistance: 0), 0)
    }

    func testCoincidentStopsKeepTheirExactCoordinates() {
        let points = (0..<8).map { TransitMarkerPoint(id: String($0), point: CGPoint(x: 25, y: 25)) }
        let groups = TransitMarkerLayout.groups(points, scaleMeters: 200)
        XCTAssertEqual(groups.count, points.count)
        XCTAssertTrue(groups.allSatisfy { $0.center == CGPoint(x: 25, y: 25) })
        XCTAssertEqual(Set(groups.map(\.id)), Set(points.map(\.id)))
    }

    func testSelectingNearbyStopsKeepsTheirOriginalCoordinates() {
        let points = [TransitMarkerPoint(id: "a", point: CGPoint(x: 100, y: 100)),
                      TransitMarkerPoint(id: "b", point: CGPoint(x: 105, y: 100)),
                      TransitMarkerPoint(id: "c", point: CGPoint(x: 110, y: 102))]
        for selected in ["b", "c", "a", "b"] {
            let groups = TransitMarkerLayout.groups(points, scaleMeters: 200, protectedIDs: [selected])
            for point in points {
                XCTAssertEqual(groups.first { $0.id == point.id }?.center, point.point)
            }
        }
    }

    func testClusterExpansionSeparatesStopsAndFitsAvailableMapArea() {
        let points = [CGPoint.zero, CGPoint(x: 20, y: 10)]
        let factor = TransitMarkerLayout.expansionFactor(points: points, scaleMeters: 500,
                                                        available: CGSize(width: 240, height: 160))
        XCTAssertGreaterThanOrEqual(factor * hypot(20, 10), 44)
        XCTAssertLessThanOrEqual(factor * 20, 240)
        XCTAssertLessThanOrEqual(factor * 10, 160)
        let coincident = TransitMarkerLayout.expansionFactor(points: [.zero, .zero], scaleMeters: 500,
                                                             available: CGSize(width: 240, height: 160))
        XCTAssertTrue(coincident.isFinite)
        XCTAssertGreaterThan(coincident, 1)
    }

    @MainActor
    func testVisualSizeNeverShrinksTheButtonTouchArea() {
        let button = TransitMarkerButton(frame: .zero)
        for detail in [TransitMarkerDetail.overview, .neighborhood, .street] {
            for selected in [false, true] {
                button.present(detail: detail, count: 1, selected: selected)
                XCTAssertEqual(button.bounds.width, 44)
                XCTAssertEqual(button.bounds.height, 44)
                XCTAssertEqual(button.accessibilityTraits.contains(.selected), selected)
            }
        }
        XCTAssertEqual(TransitMarkerDetail.overview.diameter(selected: false, clustered: false), 24)
        XCTAssertEqual(TransitMarkerDetail.neighborhood.diameter(selected: false, clustered: false), 28)
        XCTAssertEqual(TransitMarkerDetail.street.diameter(selected: false, clustered: false), 32)
        XCTAssertEqual(TransitMarkerDetail.overview.diameter(selected: true, clustered: true), 36)
        button.present(detail: .overview, count: 1, selected: false, emphasized: true)
        XCTAssertFalse(button.isSelected)
        XCTAssertFalse(button.accessibilityTraits.contains(.selected), "The nearest stop is not a boarding selection")
        XCTAssertEqual(button.bounds.width, 44)
    }
}

private final class LocationTestManager: CLLocationManager {
    override var authorizationStatus: CLAuthorizationStatus { .authorizedWhenInUse }
    override func requestLocation() {}
}
