import Foundation
import Security
import ExecRemote

@MainActor enum DeviceStore {
    private static let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"app.exec.remote.pairing", kSecAttrAccount as String:"host"]
    static func load() throws -> PairedHost? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw RemoteFailure("Could not read the paired device credential.") }
        return try JSONDecoder().decode(PairedHost.self, from: data)
    }
    static func save(_ host: PairedHost) throws {
        let data = try JSONEncoder().encode(host)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query; entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw RemoteFailure("Could not save the device credential.") }
        } else if status != errSecSuccess { throw RemoteFailure("Could not update the device credential.") }
    }
    static func forget() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RemoteFailure("Could not remove the device credential.") }
    }
}
