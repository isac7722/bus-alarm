import SwiftUI
import UIKit

/// One palette for SwiftUI screens, UIKit map controls, and Live Activities.
enum TransitColors {
    static let background = adaptive(light: 0xF5F6F8, dark: 0x151A21)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x202833)
    static let text = adaptive(light: 0x252A32, dark: 0xEDF0F4)
    static let secondaryText = adaptive(light: 0x606975, dark: 0xABB5C2)
    static let action = adaptive(light: 0x42658C, dark: 0xBED1E8)
    static let onAction = adaptive(light: 0xFFFFFF, dark: 0x202833)
    static let selection = adaptive(light: 0xE5EDF6, dark: 0x2C3B4E)
    static let separator = adaptive(light: 0xDFE3E9, dark: 0x3C4654)
    static let liveBackground = UIColor(rgb: 0x202833)
    static let liveAccent = UIColor(rgb: 0xBED1E8)
    static let liveSecondary = UIColor(rgb: 0xC1CAD5)

    private static func adaptive(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { UIColor(rgb: $0.userInterfaceStyle == .dark ? dark : light) }
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 255) / 255,
                  green: CGFloat((rgb >> 8) & 255) / 255,
                  blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
