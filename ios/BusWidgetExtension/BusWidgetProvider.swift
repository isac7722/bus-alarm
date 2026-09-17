import Foundation
import WidgetKit

struct BusWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BusWidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (BusWidgetEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        let store = AppGroupStore()
        completion(
            BusWidgetEntry(
                date: Date(),
                configuration: store?.loadConfiguration(),
                response: store?.loadConfiguration().flatMap { store?.loadCachedArrivals(for: $0) },
                updateFailed: false
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BusWidgetEntry>) -> Void) {
        Task {
            let now = Date()
            guard let store = AppGroupStore(), let configuration = store.loadConfiguration() else {
                completion(
                    Timeline(
                        entries: [BusWidgetEntry(date: now, configuration: nil, response: nil, updateFailed: false)],
                        policy: .never
                    )
                )
                return
            }

            do {
                let client = try APIClient()
                let response = try await client.arrivals(configuration: configuration)
                try? store.saveCachedArrivals(response, for: configuration)
                let refreshDate = now.addingTimeInterval(WidgetConstants.refreshInterval)
                let dates = WidgetTimelineBuilder.eventDates(response: response, now: now, refreshDate: refreshDate)
                let entries = dates.map {
                    BusWidgetEntry(
                        date: $0,
                        configuration: configuration,
                        response: response,
                        updateFailed: false
                    )
                }
                completion(Timeline(entries: entries, policy: .after(refreshDate)))
            } catch {
                let cached = store.loadCachedArrivals(for: configuration)
                let retryDate = now.addingTimeInterval(WidgetConstants.failureRetryInterval)
                let dates = cached.map {
                    WidgetTimelineBuilder.eventDates(response: $0, now: now, refreshDate: retryDate)
                } ?? [now]
                let entries = dates.map {
                    BusWidgetEntry(
                        date: $0,
                        configuration: configuration,
                        response: cached,
                        updateFailed: true
                    )
                }
                completion(Timeline(entries: entries, policy: .after(retryDate)))
            }
        }
    }
}
