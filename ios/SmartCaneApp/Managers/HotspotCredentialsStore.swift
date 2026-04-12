import Foundation
import Security

struct HotspotCredentials: Codable, Equatable {
    let ssid: String
    let password: String
}

final class HotspotCredentialsStore {
    private let service = "com.yuxuan.SmartCaneApp.hotspot"
    private let account = "phone-hotspot"

    func load() -> HotspotCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let credentials = try? JSONDecoder().decode(HotspotCredentials.self, from: data) else {
            return nil
        }

        return credentials
    }

    func save(ssid: String, password: String) {
        let credentials = HotspotCredentials(ssid: ssid, password: password)
        guard let data = try? JSONEncoder().encode(credentials) else {
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        var insertQuery = query
        insertQuery[kSecValueData as String] = data
        SecItemAdd(insertQuery as CFDictionary, nil)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
