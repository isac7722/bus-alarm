import SwiftUI
import MapKit
import NMapsMap

/// A camera request changes only for an explicit recenter action, never for search results.
struct TransitMapCamera {
    let id = UUID()
    var region: MKCoordinateRegion
    var snapshot: NMFCameraPosition? = nil
}

struct TransitMapPin {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let label: String
    var title: String = ""
    var enabled = true
    var selected = false
    let action: () -> Void
}

final class NaverMapAuthentication: NSObject, ObservableObject, NMFAuthManagerDelegate {
    static let shared = NaverMapAuthentication()
    @Published private(set) var failed = false

    private override init() {
        super.init()
        let key = (Bundle.main.object(forInfoDictionaryKey: "NMFNcpKeyId") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        failed = key.isEmpty || key.contains("$(")
        NMFAuthManager.shared().delegate = self
    }

    func authorized(_ state: NMFAuthState, error: Error?) {
        DispatchQueue.main.async { self.failed = state != .authorized }
    }
}

struct NaverTransitMap: View {
    let camera: TransitMapCamera
    let pins: [TransitMapPin]
    var line: [CLLocationCoordinate2D] = []
    var dashed = false
    var onMove: (MKCoordinateRegion) -> Void = { _ in }
    var onCameraChange: (NMFCameraPosition) -> Void = { _ in }
    @ObservedObject private var authentication = NaverMapAuthentication.shared

    var body: some View {
        NaverMapSurface(camera: camera, pins: pins, line: line, dashed: dashed, onMove: onMove, onCameraChange: onCameraChange)
            .overlay(alignment: .bottom) {
                if authentication.failed {
                    Text("지도를 불러올 수 없습니다. 정류장 목록을 이용해 주세요.")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText).padding(8).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        // Leave NAVER's logo and legal notice control unobstructed.
                        .padding(.horizontal, 52).padding(.bottom, 38)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct NaverMapSurface: UIViewRepresentable {
    let camera: TransitMapCamera
    let pins: [TransitMapPin]
    let line: [CLLocationCoordinate2D]
    let dashed: Bool
    let onMove: (MKCoordinateRegion) -> Void
    let onCameraChange: (NMFCameraPosition) -> Void

    func makeUIView(context: Context) -> TransitNaverMapView { TransitNaverMapView() }
    func updateUIView(_ view: TransitNaverMapView, context: Context) {
        view.onMove = onMove
        view.onCameraChange = onCameraChange
        view.setPins(pins)
        view.setLine(line, dashed: dashed)
        view.setCamera(camera)
    }
    static func dismantleUIView(_ view: TransitNaverMapView, coordinator: ()) { view.cleanUp() }
}

private final class TransitNaverMapView: NMFNaverMapView, NMFMapViewCameraDelegate {
    var onMove: (MKCoordinateRegion) -> Void = { _ in }
    var onCameraChange: (NMFCameraPosition) -> Void = { _ in }
    private var cameraID: UUID?
    private var pendingCamera: TransitMapCamera?
    private var pins: [TransitMapPin] = []
    private var buttons: [String: TransitMarkerButton] = [:]
    private var captions: [String: UILabel] = [:]
    private var groups: [TransitMarkerGroup] = []
    private var detail: TransitMarkerDetail = .overview
    private var scaleMeters: Double = 0
    private var markerOffsets: [String: CGPoint] = [:]
    private let connectorLayer = CAShapeLayer()
    private var lastLayoutSize: CGSize = .zero
    private var moving = false
    private var pinSignature: [String] = []
    private var polyline: NMFPolylineOverlay?
    private var lineSignature: [Double] = []
    private let directionArrow = UIImageView(image: UIImage(systemName: "arrowtriangle.up.fill"))
    private var directionSegment: [CLLocationCoordinate2D] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        showCompass = true
        showScaleBar = true
        showZoomControls = false
        showLocationButton = false
        mapView.isTiltGestureEnabled = false
        mapView.locale = "ko"
        mapView.addCameraDelegate(delegate: self)
        clipsToBounds = true
        connectorLayer.fillColor = nil
        connectorLayer.lineWidth = 1
        // Above the SDK renderer, below our marker buttons.
        layer.addSublayer(connectorLayer)
        let zoomControls = UIStackView()
        zoomControls.axis = .vertical
        zoomControls.spacing = 1
        zoomControls.backgroundColor = TransitColors.separator
        zoomControls.layer.cornerRadius = 10
        zoomControls.clipsToBounds = true
        for zoomIn in [true, false] {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: zoomIn ? "plus" : "minus"), for: .normal)
            button.tintColor = TransitColors.action
            button.backgroundColor = TransitColors.surface
            button.accessibilityLabel = zoomIn ? "지도 확대" : "지도 축소"
            button.accessibilityIdentifier = zoomIn ? "map-zoom-in" : "map-zoom-out"
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                mapView.moveCamera(NMFCameraUpdate(zoomTo: mapView.cameraPosition.zoom + (zoomIn ? 1 : -1)))
            }, for: .touchUpInside)
            zoomControls.addArrangedSubview(button)
        }
        addSubview(zoomControls)
        zoomControls.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            zoomControls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            zoomControls.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        directionArrow.tintColor = TransitColors.action
        directionArrow.bounds.size = CGSize(width: 20, height: 20)
        directionArrow.isAccessibilityElement = false
        mapView.addSubview(directionArrow)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard hit != nil else { return nil }
        if let control = hit as? UIControl, !(control is TransitMarkerButton) { return hit }
        // Keep 44pt hit areas without forcing nearby visible stations into a cluster.
        let nearest = buttons.values.filter { !$0.isHidden && $0.isEnabled && $0.frame.contains(point) }.min {
            let a = hypot($0.center.x - point.x, $0.center.y - point.y)
            let b = hypot($1.center.x - point.x, $1.center.y - point.y)
            return a == b ? ($0.accessibilityIdentifier ?? "") < ($1.accessibilityIdentifier ?? "") : a < b
        }
        return nearest ?? hit
    }

    func setCamera(_ camera: TransitMapCamera) {
        guard cameraID != camera.id else { return }
        cameraID = camera.id
        pendingCamera = camera
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let camera = pendingCamera, bounds.width > 0, bounds.height > 0 {
            pendingCamera = nil
            let region = camera.region
            let sw = NMGLatLng(lat: region.center.latitude - region.span.latitudeDelta / 2,
                               lng: region.center.longitude - region.span.longitudeDelta / 2)
            let ne = NMGLatLng(lat: region.center.latitude + region.span.latitudeDelta / 2,
                               lng: region.center.longitude + region.span.longitudeDelta / 2)
            if let snapshot = camera.snapshot {
                mapView.moveCamera(NMFCameraUpdate(position: snapshot))
            } else {
                mapView.moveCamera(NMFCameraUpdate(fit: NMGLatLngBounds(southWest: sw, northEast: ne)))
            }
        }
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            rebuildGroups()
        } else {
            positionPins()
        }
    }
    func setPins(_ values: [TransitMapPin]) {
        pins = values
        let signature = values.map { "\($0.id):\($0.coordinate.latitude):\($0.coordinate.longitude):\($0.label):\($0.title):\($0.enabled):\($0.selected)" }
        guard signature != pinSignature else { return }
        pinSignature = signature
        if !moving { rebuildGroups() }
    }
    private var markerBounds: CGRect {
        mapView.bounds.inset(by: UIEdgeInsets(top: 60, left: 24, bottom: 60, right: 76))
    }

    private func mapScaleView(in view: UIView) -> NMFScaleView? {
        if let scale = view as? NMFScaleView { return scale }
        return view.subviews.lazy.compactMap { self.mapScaleView(in: $0) }.first
    }

    private func updateScale() {
        guard let scale = mapScaleView(in: self), let width = scale.scaleBarWidthConstraint?.constant,
              width > 0, mapView.bounds.width > 0 else {
            scaleMeters = 0 // Until the SDK has laid out its scale, keep every stop individually visible.
            return
        }
        let center = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
        let from = mapView.projection.latlng(from: center)
        let to = mapView.projection.latlng(from: CGPoint(x: center.x + width, y: center.y))
        scaleMeters = TransitMarkerLayout.scaleMeters(barDistance: from.distance(to: to))
        scale.isAccessibilityElement = true
        scale.accessibilityIdentifier = "map-scale"
        scale.accessibilityLabel = "지도 축척"
        scale.accessibilityValue = "\(Int(scaleMeters))m"
    }

    private func rebuildGroups() {
        updateScale()
        detail = detail.updated(zoom: mapView.cameraPosition.zoom)
        let visible = markerBounds
        let points = pins.compactMap { pin -> TransitMarkerPoint? in
            let point = project(pin.coordinate)
            guard visible.contains(point) else { return nil }
            return TransitMarkerPoint(id: pin.id, point: point)
        }
        let selectedIDs = Set(pins.filter(\.selected).map(\.id))
        groups = TransitMarkerLayout.groups(points, scaleMeters: scaleMeters, protectedIDs: selectedIDs)
        markerOffsets = TransitMarkerLayout.offsets(groups.map { TransitMarkerPoint(id: $0.id, point: $0.center) },
                                                   in: visible, protectedIDs: selectedIDs)
        let ids = Set(groups.map(\.id))
        for id in Array(buttons.keys) where !ids.contains(id) {
            buttons.removeValue(forKey: id)?.removeFromSuperview()
            captions.removeValue(forKey: id)?.removeFromSuperview()
        }
        let byID = Dictionary(uniqueKeysWithValues: pins.map { ($0.id, $0) })
        for group in groups {
            let members = group.members.compactMap { byID[$0.id] }
            let selected = members.contains { $0.selected }
            let button: TransitMarkerButton
            if let existing = buttons[group.id] { button = existing }
            else {
                button = TransitMarkerButton(frame: .zero)
                let id = group.id
                button.addAction(UIAction { [weak self] _ in self?.activateGroup(id) }, for: .touchUpInside)
                // Keep buttons outside the SDK's gesture recognizers.
                addSubview(button)
                buttons[id] = button
                let caption = UILabel()
                caption.font = .systemFont(ofSize: 13, weight: .medium)
                caption.textColor = TransitColors.text
                caption.backgroundColor = TransitColors.surface
                caption.layer.cornerRadius = 4
                caption.clipsToBounds = true
                caption.textAlignment = .center
                caption.isAccessibilityElement = false
                caption.isUserInteractionEnabled = false
                addSubview(caption)
                captions[id] = caption
            }
            button.accessibilityIdentifier = group.id
            button.accessibilityLabel = members.count == 1 ? members[0].label : "조회된 정류장 \(members.count)개"
            button.accessibilityHint = members.count == 1 ? "정류장의 버스를 확인합니다" : "확대하여 정류장을 선택합니다"
            button.isEnabled = members.count > 1 || (members.first?.enabled ?? false)
            button.alpha = button.isEnabled ? 1 : 0.45
            button.present(detail: detail, count: members.count, selected: selected)
            captions[group.id]?.text = members.count == 1 ? members[0].title : nil
            if selected { bringSubviewToFront(button) }
        }
        positionPins()
    }
    private func project(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
        mapView.projection.point(from: NMGLatLng(lat: coordinate.latitude, lng: coordinate.longitude))
    }
    private func activateGroup(_ id: String) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        let members = group.members.compactMap { member in pins.first { $0.id == member.id } }
        if members.count == 1 {
            if members[0].enabled { members[0].action() }
            return
        }
        guard !members.isEmpty else { return }
        let points = members.map { project($0.coordinate) }
        let center = CGPoint(x: ((points.map(\.x).min() ?? 0) + (points.map(\.x).max() ?? 0)) / 2,
                             y: ((points.map(\.y).min() ?? 0) + (points.map(\.y).max() ?? 0)) / 2)
        let available = markerBounds.insetBy(dx: min(24, markerBounds.width * 0.1),
                                            dy: min(24, markerBounds.height * 0.1))
        let factor = TransitMarkerLayout.expansionFactor(points: points, scaleMeters: scaleMeters,
                                                         available: available.size)
        let update = NMFCameraUpdate(scrollTo: mapView.projection.latlng(from: center),
                                     zoomTo: min(mapView.maxZoomLevel, mapView.cameraPosition.zoom + log2(factor)))
        update.pivot = CGPoint(x: available.midX / mapView.bounds.width, y: available.midY / mapView.bounds.height)
        update.animation = UIAccessibility.isReduceMotionEnabled ? .none : .easeOut
        update.animationDuration = 0.28
        mapView.moveCamera(update)
    }
    private func positionPins() {
        directionArrow.isHidden = directionSegment.count != 2
        if directionSegment.count == 2 {
            let points = directionSegment.map { project($0) }
            directionArrow.center = CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
            directionArrow.transform = CGAffineTransform(rotationAngle: atan2(points[1].x - points[0].x, points[0].y - points[1].y))
        }
        let byID = Dictionary(uniqueKeysWithValues: pins.map { ($0.id, $0) })
        let visible = markerBounds
        let connectors = UIBezierPath()
        for group in groups {
            guard let button = buttons[group.id] else { continue }
            let points = group.members.compactMap { byID[$0.id].map { project($0.coordinate) } }
            guard !points.isEmpty else { button.isHidden = true; continue }
            let center = CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
                                 y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count))
            let offset = markerOffsets[group.id] ?? .zero
            let displayed = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
            button.center = mapView.convert(displayed, to: self)
            button.isHidden = !visible.contains(displayed)
            if !button.isHidden && offset != .zero {
                let anchor = mapView.convert(center, to: self)
                connectors.move(to: anchor)
                connectors.addLine(to: button.center)
                connectors.append(UIBezierPath(ovalIn: CGRect(x: anchor.x - 2, y: anchor.y - 2, width: 4, height: 4)))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        connectorLayer.strokeColor = UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor
        connectorLayer.path = connectors.cgPath
        CATransaction.commit()
        // Give the selected stop first choice of label space, including at overview scales.
        var occupied = buttons.values.filter { !$0.isHidden }.map { $0.frame.insetBy(dx: -4, dy: -4) }
        let labelGroups = groups.sorted {
            let a = $0.members.contains { byID[$0.id]?.selected == true }
            let b = $1.members.contains { byID[$0.id]?.selected == true }
            return a == b ? $0.id < $1.id : a
        }
        for group in labelGroups {
            guard let caption = captions[group.id], let button = buttons[group.id] else { continue }
            caption.isHidden = true
            let selected = group.members.contains { byID[$0.id]?.selected == true }
            guard (detail == .street || selected), !moving, !button.isHidden, group.members.count == 1,
                  let text = caption.text, !text.isEmpty else { continue }
            let width = min(150, caption.intrinsicContentSize.width + 12)
            let candidates = [
                CGRect(x: button.center.x - width / 2, y: button.frame.maxY + 6, width: width, height: 22),
                CGRect(x: button.center.x - width / 2, y: button.frame.minY - 28, width: width, height: 22)
            ]
            guard let frame = candidates.first(where: { candidate in
                bounds.inset(by: UIEdgeInsets(top: 60, left: 8, bottom: 42, right: 60)).contains(candidate) &&
                !occupied.contains(where: { $0.intersects(candidate) })
            }) else { continue }
            caption.frame = frame
            caption.isHidden = false
            occupied.append(frame.insetBy(dx: -4, dy: -4))
        }
    }
    func setLine(_ coordinates: [CLLocationCoordinate2D], dashed: Bool) {
        let signature = [dashed ? 1.0 : 0.0] + coordinates.flatMap { [$0.latitude, $0.longitude] }
        guard signature != lineSignature else { return }
        lineSignature = signature
        directionSegment = dashed ? Array(coordinates.prefix(2)) : []
        polyline?.mapView = nil
        polyline = nil
        if coordinates.count > 1 {
            polyline = NMFPolylineOverlay(coordinates.map { NMGLatLng(lat: $0.latitude, lng: $0.longitude) })
            polyline?.color = TransitColors.action
            polyline?.width = 3
            polyline?.pattern = dashed ? [6, 5] : []
            polyline?.mapView = mapView
        }
        positionPins()
    }
    func mapView(_ mapView: NMFMapView, cameraIsChangingByReason reason: Int) {
        moving = true
        positionPins()
    }
    func mapViewCameraIdle(_ mapView: NMFMapView) {
        moving = false
        let bounds = mapView.contentBounds
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (bounds.southWestLat + bounds.northEastLat) / 2,
                                          longitude: (bounds.southWestLng + bounds.northEastLng) / 2),
            span: MKCoordinateSpan(latitudeDelta: bounds.northEastLat - bounds.southWestLat,
                                   longitudeDelta: bounds.northEastLng - bounds.southWestLng))
        let snapshot = mapView.cameraPosition
        DispatchQueue.main.async { [weak self] in
            // The SDK scale bar's camera delegate must finish before reading its public width.
            guard let self, !self.moving else { return }
            self.rebuildGroups()
            self.onMove(region)
            self.onCameraChange(snapshot)
        }
    }
    func cleanUp() {
        mapView.removeCameraDelegate(delegate: self)
        polyline?.mapView = nil
        onMove = { _ in }
        onCameraChange = { _ in }
        pins = []
        for button in buttons.values { button.menu = nil; button.removeFromSuperview() }
        buttons = [:]
        groups = []
        markerOffsets = [:]
        connectorLayer.path = nil
    }
}
