import Foundation
import XCTest
@testable import BusWidgetApp

final class AppGroupStoreTests: XCTestCase {
    @MainActor
    func testLegacyWidgetMigratesOnceAndRetiredWidgetDataIsCleared() throws {
        let suite = "BusWidgetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try XCTUnwrap(AppGroupStore(suiteName: suite))
        let configuration = WidgetConfigurationData(stationId: "22001", stationName: "강남역", routeIds: ["100100341"])
        let data = try JSONEncoder.busWidget.encode(configuration)
        defaults.set(data, forKey: AppGroupStore.configurationKey)
        defaults.set(Data(), forKey: "widget.cachedArrivals")
        let favorites = FavoritesStore(store: store, client: nil)
        XCTAssertEqual(favorites.items.map(\.configuration), [configuration])
        XCTAssertNil(defaults.data(forKey: AppGroupStore.configurationKey))
        XCTAssertNil(defaults.data(forKey: "widget.cachedArrivals"))
        favorites.delete(try XCTUnwrap(favorites.items.first))
        defaults.set(data, forKey: AppGroupStore.configurationKey)
        XCTAssertTrue(try store.loadFavorites().isEmpty, "Deleting all favorites must not migrate them again")
    }

    func testCorruptLegacyConfigurationIsPreservedForRecovery() throws {
        let suite = "BusWidgetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try XCTUnwrap(AppGroupStore(suiteName: suite))
        let damaged = Data("invalid".utf8)
        defaults.set(damaged, forKey: AppGroupStore.configurationKey)
        XCTAssertThrowsError(try store.loadFavorites())
        XCTAssertNil(defaults.data(forKey: "commute.favorites"))
        XCTAssertEqual(defaults.data(forKey: AppGroupStore.configurationKey), damaged)
    }

    func testExistingFavoritesTakePriorityAndCorruptFavoritesPreserveLegacyBackup() throws {
        let suite = "BusWidgetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try XCTUnwrap(AppGroupStore(suiteName: suite))
        let favorite = SavedStop(configuration: WidgetConfigurationData(stationId: "22001", stationName: "강남역", routeIds: ["100100341"]), nickname: "퇴근길")
        let legacy = try JSONEncoder.busWidget.encode(favorite.configuration)
        defaults.set(legacy, forKey: AppGroupStore.configurationKey)
        defaults.set(Data("invalid".utf8), forKey: "commute.favorites")
        XCTAssertThrowsError(try store.loadFavorites())
        XCTAssertEqual(defaults.data(forKey: AppGroupStore.configurationKey), legacy)
        try store.saveFavorites([favorite])
        XCTAssertEqual(try store.loadFavorites(), [favorite])
        XCTAssertNil(defaults.data(forKey: AppGroupStore.configurationKey))
    }
}
