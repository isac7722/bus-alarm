import XCTest
@testable import BusWidgetApp

final class TransitMarkerTests: XCTestCase {
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

    func testCoincidentStopsSpreadInsideMapWithoutLosingTheirAnchors() {
        let points = (0..<8).map { TransitMarkerPoint(id: String($0), point: CGPoint(x: 25, y: 25)) }
        let bounds = CGRect(x: 24, y: 24, width: 280, height: 240)
        let offsets = TransitMarkerLayout.offsets(points, in: bounds, protectedIDs: ["3"])
        XCTAssertEqual(offsets["3"], .zero)
        XCTAssertEqual(offsets, TransitMarkerLayout.offsets(points.reversed(), in: bounds, protectedIDs: ["3"]))
        let displayed = points.map { CGPoint(x: $0.point.x + offsets[$0.id]!.x, y: $0.point.y + offsets[$0.id]!.y) }
        XCTAssertTrue(displayed.allSatisfy { bounds.contains($0) })
        for i in displayed.indices {
            for j in displayed.indices where j > i {
                XCTAssertGreaterThanOrEqual(hypot(displayed[i].x - displayed[j].x, displayed[i].y - displayed[j].y), 43.99)
            }
        }
        XCTAssertTrue(points.allSatisfy { $0.point == CGPoint(x: 25, y: 25) })
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
    }
}
