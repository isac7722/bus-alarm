import UIKit

/// Zoom hysteresis avoids flickering between marker styles during a pinch gesture.
enum TransitMarkerDetail: String {
    case overview, neighborhood, street

    func updated(zoom: Double) -> Self {
        switch self {
        case .overview:
            return zoom >= 16.7 ? .street : zoom >= 14.7 ? .neighborhood : .overview
        case .neighborhood:
            return zoom < 14.3 ? .overview : zoom >= 16.7 ? .street : .neighborhood
        case .street:
            return zoom < 14.3 ? .overview : zoom < 16.3 ? .neighborhood : .street
        }
    }

    func diameter(selected: Bool, clustered: Bool) -> CGFloat {
        if selected { return 36 }
        if clustered { return 32 }
        switch self {
        case .overview: return 24
        case .neighborhood: return 28
        case .street: return 32
        }
    }
}

struct TransitMarkerPoint {
    let id: String
    let point: CGPoint
}

struct TransitMarkerGroup {
    private(set) var members: [TransitMarkerPoint]
    private(set) var center: CGPoint

    init(members: [TransitMarkerPoint]) {
        self.members = members
        center = CGPoint(x: members.reduce(0) { $0 + $1.point.x } / CGFloat(max(1, members.count)),
                         y: members.reduce(0) { $0 + $1.point.y } / CGFloat(max(1, members.count)))
    }
    mutating func merge(_ other: Self) {
        let a = CGFloat(members.count), b = CGFloat(other.members.count)
        center = CGPoint(x: (center.x * a + other.center.x * b) / (a + b),
                         y: (center.y * a + other.center.y * b) / (a + b))
        members += other.members
    }
    var id: String { members.count == 1 ? members[0].id : "map-cluster.\(members[0].id).\(members.count)" }
}

enum TransitMarkerLayout {
    static let hitSize: CGFloat = 44

    /// Recover the metric label from the SDK's public scale-bar width and projection.
    /// Rounding tolerates projection/latitude and subpixel differences, without parsing UI text.
    static func scaleMeters(barDistance: Double) -> Double {
        guard barDistance.isFinite, barDistance > 0 else { return 0 }
        let magnitude = pow(10, floor(log10(barDistance)))
        return [1.0, 2, 5, 10].map { $0 * magnitude }.min {
            abs(log($0 / barDistance)) < abs(log($1 / barDistance))
        } ?? 0
    }

    static func separation(scaleMeters: Double) -> CGFloat {
        guard scaleMeters >= 500 else { return 0 }
        return scaleMeters >= 1_000 ? 36 : 28
    }

    /// Deterministic groups; every loaded pin belongs to exactly one group.
    /// Selected stops never disappear into a cluster. Below 500m every stop stays individual.
    static func groups(_ points: [TransitMarkerPoint], scaleMeters: Double,
                       protectedIDs: Set<String> = []) -> [TransitMarkerGroup] {
        let singles = points.filter { protectedIDs.contains($0.id) }
            .sorted { $0.id < $1.id }.map { TransitMarkerGroup(members: [$0]) }
        var groups = points.filter { !protectedIDs.contains($0.id) }
            .sorted { $0.id < $1.id }.map { TransitMarkerGroup(members: [$0]) }
        let separation = separation(scaleMeters: scaleMeters)
        guard separation > 0 else { return singles + groups }
        var changed = true
        while changed {
            changed = false
            outer: for i in groups.indices {
                for j in groups.indices where j > i {
                    let a = groups[i].center, b = groups[j].center
                    guard hypot(a.x - b.x, a.y - b.y) < separation else { continue }
                    // Bound the entire group as well as its center; chains must not absorb a street.
                    let members = groups[i].members + groups[j].members
                    let width = (members.map { $0.point.x }.max() ?? 0) - (members.map { $0.point.x }.min() ?? 0)
                    let height = (members.map { $0.point.y }.max() ?? 0) - (members.map { $0.point.y }.min() ?? 0)
                    if max(width, height) <= separation * 2 {
                        groups[i].merge(groups[j])
                        groups.remove(at: j)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return singles + groups
    }

    /// Keep displaced individual stops selectable, inside the map, and attached to their true anchor.
    /// Call only at camera idle; retain these offsets while the user pans or pinches.
    static func offsets(_ points: [TransitMarkerPoint], in bounds: CGRect,
                        protectedIDs: Set<String> = []) -> [String: CGPoint] {
        var occupied: [CGPoint] = []
        var result: [String: CGPoint] = [:]
        let ordered = points.sorted {
            let a = protectedIDs.contains($0.id), b = protectedIDs.contains($1.id)
            return a == b ? $0.id < $1.id : a
        }
        for point in ordered {
            var target = point.point
            if occupied.contains(where: { hypot($0.x - target.x, $0.y - target.y) < 36 }) {
                let rings = Int(ceil(max(bounds.width, bounds.height) / hitSize)) + 1
                search: for ring in 1...max(1, rings) {
                    let radius = CGFloat(ring) * hitSize
                    let count = max(8, ring * 8)
                    for index in 0..<count {
                        let angle = CGFloat(index) * 2 * .pi / CGFloat(count)
                        let candidate = CGPoint(x: point.point.x + cos(angle) * radius,
                                                y: point.point.y + sin(angle) * radius)
                        if bounds.contains(candidate), !occupied.contains(where: {
                            hypot($0.x - candidate.x, $0.y - candidate.y) < hitSize
                        }) {
                            target = candidate
                            break search
                        }
                    }
                }
            }
            occupied.append(target)
            result[point.id] = CGPoint(x: target.x - point.point.x, y: target.y - point.point.y)
        }
        return result
    }

    static func expansionFactor(points: [CGPoint], scaleMeters: Double, available: CGSize) -> Double {
        guard points.count > 1 else { return 2 }
        let width = (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0)
        let height = (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)
        var nearest = CGFloat.greatestFiniteMagnitude
        for i in points.indices {
            for j in points.indices where j > i {
                nearest = min(nearest, hypot(points[i].x - points[j].x, points[i].y - points[j].y))
            }
        }
        let desired = max(2, scaleMeters / 100, Double(hitSize / max(8, nearest)))
        let fit = min(available.width / max(1, width), available.height / max(1, height))
        return max(1, min(desired, Double(fit)))
    }
}

/// Visual size and hit size are independent. The UIKit button always stays 44pt.
final class TransitMarkerButton: UIButton {
    private let face = UIView()
    private let glyph = UIImageView()
    private let countLabel = UILabel()
    private var presentation = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        bounds.size = CGSize(width: 44, height: 44)
        face.bounds.size = CGSize(width: 36, height: 36)
        face.center = CGPoint(x: 22, y: 22)
        face.layer.cornerRadius = 10
        face.layer.cornerCurve = .continuous
        face.isUserInteractionEnabled = false
        addSubview(face)
        glyph.frame = CGRect(x: 7, y: 7, width: 22, height: 22)
        glyph.contentMode = .scaleAspectFit
        face.addSubview(glyph)
        countLabel.frame = CGRect(x: 23, y: -3, width: 19, height: 19)
        countLabel.layer.cornerRadius = 9.5
        countLabel.clipsToBounds = true
        countLabel.layer.borderWidth = 1.5
        countLabel.layer.borderColor = UIColor.systemBackground.cgColor
        countLabel.textAlignment = .center
        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        countLabel.adjustsFontSizeToFitWidth = true
        countLabel.minimumScaleFactor = 0.65
        face.addSubview(countLabel)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (button: TransitMarkerButton, _: UITraitCollection) in
            button.updateColors()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(detail: TransitMarkerDetail, count: Int, selected: Bool) {
        let next = "\(detail.rawValue)-\(count)-\(selected)"
        guard next != presentation else { return }
        let animate = !presentation.isEmpty && !UIAccessibility.isReduceMotionEnabled
        presentation = next
        isSelected = selected
        updateColors()
        face.layer.borderWidth = selected ? 2 : 1.5
        glyph.image = UIImage(systemName: "bus.fill")
        countLabel.text = count > 1 ? String(count) : "✓"
        countLabel.isHidden = count == 1 && !selected
        accessibilityTraits = selected ? [.button, .selected] : [.button]
        let size = detail.diameter(selected: selected, clustered: count > 1)
        let changes = { self.face.transform = CGAffineTransform(scaleX: size / 36, y: size / 36) }
        if animate { UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes) }
        else { changes() }
    }
    private func updateColors() {
        let action = TransitColors.action.resolvedColor(with: traitCollection)
        let surface = TransitColors.surface.resolvedColor(with: traitCollection)
        let onAction = TransitColors.onAction.resolvedColor(with: traitCollection)
        face.backgroundColor = isSelected ? action : surface
        face.layer.borderColor = action.cgColor
        glyph.tintColor = isSelected ? onAction : action
        countLabel.textColor = onAction
        countLabel.backgroundColor = action
        countLabel.layer.borderColor = surface.cgColor
    }
    override var isHighlighted: Bool {
        didSet { face.alpha = isHighlighted ? 0.6 : 1 }
    }
}
