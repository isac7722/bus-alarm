import Foundation

struct AppGroupStore {
    static var suiteName: String {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["BUS_WIDGET_TEST_SUITE"] { return suite }
        #endif
        return "group.com.pangjoong.buswidget"
    }
    static let configurationKey = "widget.configuration"
    static let cachedArrivalsKey = "widget.cachedArrivals"

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init?(suiteName: String = AppGroupStore.suiteName) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.defaults = defaults
        encoder = JSONEncoder.busWidget
        decoder = JSONDecoder.busWidget
    }

    func loadConfiguration() -> WidgetConfigurationData? {
        guard let data = defaults.data(forKey: Self.configurationKey) else { return nil }
        return try? decoder.decode(WidgetConfigurationData.self, from: data)
    }

    func saveConfiguration(_ configuration: WidgetConfigurationData) throws {
        defaults.set(try encoder.encode(configuration), forKey: Self.configurationKey)
    }

    func loadFavorites() throws -> [SavedStop] {
        if let data = defaults.data(forKey: "commute.favorites") {
            return try decoder.decode([SavedStop].self, from: data)
        }
        // Persist even an empty list so deleting the last favorite won't resurrect it.
        let migrated = loadConfiguration().map { [SavedStop(configuration: $0)] } ?? []
        try saveFavorites(migrated)
        return migrated
    }

    func saveFavorites(_ favorites: [SavedStop]) throws {
        defaults.set(try encoder.encode(favorites), forKey: "commute.favorites")
    }

    func clearConfiguration() {
        defaults.removeObject(forKey: Self.configurationKey)
        defaults.removeObject(forKey: Self.cachedArrivalsKey)
        defaults.removeObject(forKey: "widget.selectionArrivals")
    }

    func loadCachedArrivals() -> ArrivalsResponse? {
        guard let data = defaults.data(forKey: Self.cachedArrivalsKey) else { return nil }
        return try? decoder.decode(ArrivalsResponse.self, from: data)
    }

    func saveCachedArrivals(_ response: ArrivalsResponse) throws {
        defaults.set(try encoder.encode(response), forKey: Self.cachedArrivalsKey)
    }
    private struct SelectionCache: Codable {
        let identity: String
        let response: ArrivalsResponse
    }

    func loadCachedArrivals(for configuration: WidgetConfigurationData) -> ArrivalsResponse? {
        guard let data = defaults.data(forKey: "widget.selectionArrivals"),
              let cache = try? decoder.decode(SelectionCache.self, from: data),
              cache.identity == configuration.cacheIdentity else {
            if configuration.version == 1, let legacy = loadCachedArrivals(),
               legacy.station.stationId == configuration.stationId,
               Set(legacy.arrivals.map(\.routeId)) == Set(configuration.routeIds) { return legacy }
            return nil
        }
        return cache.response
    }

    func saveCachedArrivals(_ response: ArrivalsResponse, for configuration: WidgetConfigurationData) throws {
        guard response.station.stationId == configuration.stationId else { return }
        let cache = SelectionCache(identity: configuration.cacheIdentity, response: response)
        defaults.set(try encoder.encode(cache), forKey: "widget.selectionArrivals")
    }

}

extension JSONDecoder {
    static var busWidget: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var busWidget: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
