import Foundation
import Security

/// Stores per-sensor session crypto keys (kEnc + ivEnc) in the iOS Keychain.
/// Plaintext sensor metadata (serial, BLE address, receiver ID) lives in
/// CGMManager rawState; only the secrets live here.
enum LibreLoopKeychain {
    private static let service = "org.loopkit.LibreLoop.sessionKeys"

    struct SessionKeys: Equatable {
        let kEnc: Data
        let ivEnc: Data
    }

    static func save(_ keys: SessionKeys, forSensorSerial serial: String) throws {
        let payload = keys.kEnc + Data([0xff]) + keys.ivEnc
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serial,
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData] = payload
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LibreLoopKeychainError.osStatus(status)
        }
    }

    static func load(forSensorSerial serial: String) throws -> SessionKeys {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serial,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw LibreLoopKeychainError.osStatus(status)
        }
        guard let sep = data.firstIndex(of: 0xff), data.count >= sep + 1 else {
            throw LibreLoopKeychainError.malformed
        }
        let kEnc = data[..<sep]
        let ivEnc = data[(sep + 1)...]
        return SessionKeys(kEnc: Data(kEnc), ivEnc: Data(ivEnc))
    }

    static func delete(forSensorSerial serial: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serial,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LibreLoopKeychainError.osStatus(status)
        }
    }
}

enum LibreLoopKeychainError: Error, CustomStringConvertible {
    case osStatus(OSStatus)
    case malformed

    var description: String {
        switch self {
        case .osStatus(let status): return "Keychain error \(status)"
        case .malformed: return "Stored session keys are malformed"
        }
    }
}
