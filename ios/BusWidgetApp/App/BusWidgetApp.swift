import SwiftUI

@main
struct BusWidgetApplication: App {
    @StateObject private var waiting = BusWaitingManager()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(waiting)
        }
    }
}
