import SwiftUI

private struct ArrivalRefreshEnabled: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var arrivalRefreshEnabled: Bool {
        get { self[ArrivalRefreshEnabled.self] }
        set { self[ArrivalRefreshEnabled.self] = newValue }
    }
}
private struct ArrivalPolling: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @Environment(\.arrivalRefreshEnabled) private var enabled
    @ObservedObject private var connection = ConnectionRecovery.shared
    let model: CommuteArrivalsModel
    let configuration: WidgetConfigurationData
    let visible: Bool
    func body(content: Content) -> some View {
        content.task(id: "\(configuration.cacheIdentity)|\(phase)|\(enabled && visible)|\(connection.generation)") {
            guard phase == .active, enabled, visible, !configuration.routeIds.isEmpty else { return }
            await model.poll(configuration, forceInitial: true)
        }
    }
}
extension View {
    func arrivalPolling(_ model: CommuteArrivalsModel, configuration: WidgetConfigurationData, visible: Bool = true) -> some View {
        modifier(ArrivalPolling(model: model, configuration: configuration, visible: visible))
    }
}
