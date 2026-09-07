import Foundation

struct AppGroupStore {
    static let suiteName = "group.com.pangjoong.buswidget"
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

    func loadCachedArrivals() -> ArrivalsResponse? {
        guard let data = defaults.data(forKey: Self.cachedArrivalsKey) else { return nil }
        return try? decoder.decode(ArrivalsResponse.self, from: data)
    }

    func saveCachedArrivals(_ response: ArrivalsResponse) throws {
        defaults.set(try encoder.encode(response), forKey: Self.cachedArrivalsKey)
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
