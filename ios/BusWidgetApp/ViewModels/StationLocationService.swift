import Foundation
import CoreLocation

@MainActor
final class StationLocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var message: String?
    @Published private(set) var isLocating = false
    @Published private(set) var updateID = UUID()
    private let manager: CLLocationManager
    private var requested = false
    private var retryCount = 0
    private var retryTask: Task<Void, Never>?
    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }
    func request() {
        guard !isLocating else { return }
        requested = true
        retryCount = 0
        isLocating = true
        message = nil
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        default:
            finish()
            coordinate = nil
            message = "위치 없이도 지도와 목록에서 정류장을 고를 수 있어요."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard requested else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        case .denied, .restricted:
            finish()
            coordinate = nil
            message = "위치 없이도 지도와 목록에서 정류장을 고를 수 있어요."
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard requested else { return }
        guard let location = locations.last(where: { $0.horizontalAccuracy >= 0 && CLLocationCoordinate2DIsValid($0.coordinate) }) else {
            finish()
            coordinate = nil
            message = "위치를 찾지 못했어요. 지도와 목록에서 정류장을 고를 수 있어요."
            return
        }
        finish()
        coordinate = location.coordinate
        message = location.horizontalAccuracy > 150 ? "현재 위치가 정확하지 않을 수 있어요. 정류장 번호와 방향을 확인해 주세요." : nil
        // Every successful request recenters, including an unchanged latitude/longitude.
        updateID = UUID()
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore late callbacks after a successful one-shot lookup.
        guard requested else { return }
        // A cold location fix can be temporarily unavailable. Retry briefly, then show the fallback.
        if requested, (error as? CLError)?.code == .locationUnknown, retryCount < 2 {
            retryCount += 1
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.requested else { return }
                self.manager.requestLocation()
            }
            return
        }
        finish()
        coordinate = nil
        message = "위치를 찾지 못했어요. 지도와 목록에서 정류장을 고를 수 있어요."
    }
    private func finish() {
        requested = false
        isLocating = false
        retryTask?.cancel()
        retryTask = nil
    }
}
