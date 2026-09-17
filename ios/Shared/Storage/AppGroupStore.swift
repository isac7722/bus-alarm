import Foundation

struct AppGroupStore {
    static var suiteName: String {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["BUS_WIDGET_TEST_SUITE"] { return suite }
        #endif
        return "group.com.pangjoong.buswidget"
    }
    static let configurationKey = "widget.configuration"

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init?(suiteName: String = AppGroupStore.suiteName) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.defaults = defaults
        encoder = JSONEncoder.busWidget
        decoder = JSONDecoder.busWidget
    }

    private func loadConfiguration() throws -> WidgetConfigurationData? {
        guard let data = defaults.data(forKey: Self.configurationKey) else { return nil }
        return try decoder.decode(WidgetConfigurationData.self, from: data)
    }

    func loadFavorites() throws -> [SavedStop] {
        if let data = defaults.data(forKey: "commute.favorites") {
            let favorites = try decoder.decode([SavedStop].self, from: data)
            clearLegacyWidgetData()
            return favorites
        }
        // Persist even an empty list so deleting the last favorite won't resurrect it.
        let migrated = try loadConfiguration().map { [SavedStop(configuration: $0)] } ?? []
        try saveFavorites(migrated)
        clearLegacyWidgetData()
        return migrated
    }

    func saveFavorites(_ favorites: [SavedStop]) throws {
        defaults.set(try encoder.encode(favorites), forKey: "commute.favorites")
    }

    private func clearLegacyWidgetData() {
        // Only called after favorites have been decoded or successfully migrated.
        defaults.removeObject(forKey: Self.configurationKey)
        defaults.removeObject(forKey: "widget.cachedArrivals")
        defaults.removeObject(forKey: "widget.selectionArrivals")
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
