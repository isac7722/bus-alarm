import Foundation
import CoreLocation

@MainActor
final class StationLocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var message: String?
    private let manager = CLLocationManager()
    private var requested = false
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters }
    func request() {
        requested = true
        message = nil
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        default: message = "위치 없이도 지도와 목록에서 정류장을 고를 수 있어요."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard requested else { return }
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        coordinate = location.coordinate
        if location.horizontalAccuracy > 500 { message = "현재 위치가 정확하지 않을 수 있어요. 정류장 번호와 방향을 확인해 주세요." }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        message = "위치를 찾지 못했어요. 지도와 목록에서 정류장을 고를 수 있어요."
    }
}
