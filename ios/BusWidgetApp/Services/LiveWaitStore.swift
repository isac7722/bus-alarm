import Foundation
import Security

struct LiveWaitRecord: Codable {
    let activityId: String
    let secret: String
    let expiresAt: Double
    var needsDelete: Bool = false
}

// The session capability never goes into the widget attributes, URLs or logs.
enum LiveWaitStore {
    private static let service = "com.pangjoong.BusWidget.live-waits"

    static func newSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LiveWaitError.storage
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func load() throws -> [LiveWaitRecord] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "sessions",
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw LiveWaitError.storage }
        return try JSONDecoder().decode([LiveWaitRecord].self, from: data)
    }

    static func save(_ records: [LiveWaitRecord]) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "sessions"
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(records),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw LiveWaitError.storage
            }
        } else if status != errSecSuccess { throw LiveWaitError.storage }
    }
}

enum LiveWaitError: LocalizedError {
    case disabled, noPrediction, tokenUnavailable, storage, unavailable

    var errorDescription: String? {
        switch self {
        case .disabled: return "설정 앱에서 버스 위젯의 실시간 현황을 허용해 주세요."
        case .noPrediction: return "운행 중인 버스의 도착 정보가 없어 대기를 시작할 수 없습니다."
        case .tokenUnavailable: return "실시간 현황을 연결하지 못했습니다. 네트워크와 실시간 현황 설정을 확인한 뒤 다시 시도해 주세요."
        case .storage: return "대기 정보를 안전하게 저장하지 못했습니다. 다시 시도해 주세요."
        case .unavailable: return "실시간 현황 서비스를 준비 중입니다. 잠시 후 다시 시도해 주세요."
        }
    }
}

enum PushEnvironment {
    static var current: String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url), let environment = provisioningEnvironment(data) {
            return environment
        }
        // App Store and TestFlight apps have no embedded development profile.
        return "production"
        #endif
    }

    static func provisioningEnvironment(_ data: Data) -> String? {
        guard let start = data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String else { return nil }
        return environment == "development" ? "sandbox" : "production"
    }
}
