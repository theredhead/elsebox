import Foundation
import Security

/// Passwords live in the login Keychain until WinPE has deployed the answer file.
enum WindowsSetupSecret {
    private static let service = "nl.theredhead.elsebox.windows-setup"

    static func save(_ password: String, for id: UUID) throws {
        let query = key(id)
        let value = Data(password.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData: value] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw error(updated) }

        var item = query
        item[kSecValueData] = value
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw error(status) }
    }

    static func read(for id: UUID) throws -> String {
        var query = key(id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
            let password = String(data: data, encoding: .utf8)
        else { throw settingsError("The Windows setup password is unavailable in Keychain.") }
        return password
    }

    static func remove(for id: UUID) throws {
        let status = SecItemDelete(key(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }

    private static func key(_ id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString]
    }

    private static func error(_ status: OSStatus) -> NSError {
        settingsError("Could not access the Windows setup password in Keychain (\(status)).")
    }
}
