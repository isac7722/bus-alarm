import SwiftUI

enum AppTheme {
    static let primary = Color(uiColor: TransitColors.action)
    static let action = primary
    static let background = Color(uiColor: TransitColors.background)
    static let surface = Color(uiColor: TransitColors.surface)
    static let text = Color(uiColor: TransitColors.text)
    static let secondaryText = Color(uiColor: TransitColors.secondaryText)
    static let selection = Color(uiColor: TransitColors.selection)
    static let separator = Color(uiColor: TransitColors.separator)
    static let onAction = Color(uiColor: TransitColors.onAction)
    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 12
    static let spacingSmall: CGFloat = 8
    static let spacingMedium: CGFloat = 16
    static let spacingLarge: CGFloat = 24
}

struct TransitButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(minHeight: 48)
            .foregroundStyle(prominent ? AppTheme.onAction : AppTheme.action)
            .tint(prominent ? AppTheme.onAction : AppTheme.action)
            .background(prominent ? AppTheme.action : AppTheme.selection,
                        in: RoundedRectangle(cornerRadius: AppTheme.controlRadius))
            .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
    }
}

/// A compact map overlay with a 36pt visual height and at least a 44pt touch target.
struct TransitMapButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 36)
            .foregroundStyle(AppTheme.action)
            .background(AppTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(AppTheme.separator, lineWidth: 1))
            .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

struct TransitEmptyState: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28, weight: .regular))
                .foregroundStyle(AppTheme.action).accessibilityHidden(true)
                .padding(.bottom, 4)
            Text(title).font(.headline).foregroundStyle(AppTheme.text)
                .accessibilityAddTraits(.isHeader)
            Text(message).font(.subheadline).foregroundStyle(AppTheme.secondaryText)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24).padding(.vertical, 32)
    }
}

struct StationSummaryView: View {
    let name: String
    let number: String
    var nickname = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !nickname.isEmpty {
                Text(nickname).font(.subheadline.weight(.medium)).foregroundStyle(AppTheme.secondaryText)
            }
            Text(name).font(.title3.weight(.semibold)).foregroundStyle(AppTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("정류장 \(number)").font(.subheadline).monospacedDigit()
                .foregroundStyle(AppTheme.secondaryText)
        }.padding(.vertical, 4)
    }
}

extension View {
    func transitCard() -> some View {
        background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.cardRadius)
                .strokeBorder(AppTheme.separator, lineWidth: 0.5))
    }

    func transitList() -> some View {
        scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .foregroundStyle(AppTheme.text)
            .tint(AppTheme.action)
    }

    func transitActionBar() -> some View {
        padding(.horizontal, 20).padding(.vertical, 12)
            .background(AppTheme.surface)
            .overlay(alignment: .top) { Rectangle().fill(AppTheme.separator).frame(height: 0.5) }
    }
}
