import SwiftUI
import WidgetKit

// WidgetKit also hosts Live Activities. No static home/lock screen widgets are registered.
@main
struct BusWidgetBundle: WidgetBundle {
    var body: some Widget {
        BusWaitingLiveActivity()
    }
}
