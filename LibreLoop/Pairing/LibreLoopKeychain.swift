import Foundation
import Security

/// Stores per-sensor session crypto keys in the iOS Keychain. Plaintext
/// sensor metadata (serial, BLE address, receiver ID) lives in CGMManager
/// rawState; only the secrets live here.
///
/// On-disk payload formats (one Keychain item per sensor serial):
///   v1 (legacy, read-only): `kEnc(16) || 0xff || ivEnc(8)` — 25 bytes.
///                           No phase5RawKey; cached/direct reconnect path
///                           cannot run for these sensors, so they keep
///                           using the full handshake until next re-pair.
///   v2:                     `0x02 || kEnc(16) || ivEnc(8) || phase5RawKey(16)`
///                           — 41 bytes.
///   v3 (current):           `0x03 || kEnc(16) || ivEnc(8) || phase5RawKey(16)
///                            || receiverID(4 LE)` — 45 bytes. The receiverID
///                           is what the sensor remembers as its current
///                           receiver; needed to issue switchReceiver after
///                           a CGMManager rawState wipe.
enum LibreLoopKeychain {
    private static let service = "org.loopkit.LibreLoop.sessionKeys"
    private static let v2Magic: UInt8 = 0x02
    private static let v3Magic: UInt8 = 0x03

    struct SessionKeys: Equatable {
        let kEnc: Data
        let ivEnc: Data
        /// Phase 5 raw key from the first-pair handshake. When present, the
        /// reconnect flow can use LibreCRKit's `runCachedReconnectHandshake`
        /// fast path. Nil for sensors paired before this field was persisted.
        let phase5RawKey: Data?
        /// Receiver ID this sensor was last paired under. Persisting it here
        /// (in addition to CGMManager rawState) lets onboarding auto-recover
        /// after a rawState wipe by issuing switchReceiver with the stored
        /// ID. Nil for sensors paired before this field was persisted.
        let receiverID: UInt32?
    }

    static func save(_ keys: SessionKeys, forSensorSerial serial: String) throws {
        let payload: Data
        if let phase5RawKey = keys.phase5RawKey, phase5RawKey.count == 16 {
            if let receiverID = keys.receiverID {
                var ridLE = Data(count: 4)
                ridLE[0] = UInt8(truncatingIfNeeded: receiverID)
                ridLE[1] = UInt8(truncatingIfNeeded: receiverID >> 8)
                ridLE[2] = UInt8(truncatingIfNeeded: receiverID >> 16)
                ridLE[3] = UInt8(truncatingIfNeeded: receiverID >> 24)
                payload = Data([v3Magic]) + keys.kEnc + keys.ivEnc + phase5RawKey + ridLE
            } else {
                payload = Data([v2Magic]) + keys.kEnc + keys.ivEnc + phase5RawKey
            }
        } else {
            // Legacy-shaped record. Still readable by old binaries.
            payload = keys.kEnc + Data([0xff]) + keys.ivEnc
        }
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
        if data.count == 45 && data.first == v3Magic {
            // v3: 0x03 || kEnc(16) || ivEnc(8) || phase5RawKey(16) || receiverID(4 LE)
            let kEnc = data.subdata(in: 1..<17)
            let ivEnc = data.subdata(in: 17..<25)
            let phase5RawKey = data.subdata(in: 25..<41)
            let ridLE = data.subdata(in: 41..<45)
            let receiverID = UInt32(ridLE[0])
                | (UInt32(ridLE[1]) << 8)
                | (UInt32(ridLE[2]) << 16)
                | (UInt32(ridLE[3]) << 24)
            return SessionKeys(kEnc: kEnc, ivEnc: ivEnc, phase5RawKey: phase5RawKey, receiverID: receiverID)
        }
        if data.count == 41 && data.first == v2Magic {
            // v2: 0x02 || kEnc(16) || ivEnc(8) || phase5RawKey(16)
            let kEnc = data.subdata(in: 1..<17)
            let ivEnc = data.subdata(in: 17..<25)
            let phase5RawKey = data.subdata(in: 25..<41)
            return SessionKeys(kEnc: kEnc, ivEnc: ivEnc, phase5RawKey: phase5RawKey, receiverID: nil)
        }
        // v1 fallback: kEnc(16) || 0xff || ivEnc(8). No phase5RawKey.
        guard let sep = data.firstIndex(of: 0xff), data.count >= sep + 1 else {
            throw LibreLoopKeychainError.malformed
        }
        let kEnc = data[..<sep]
        let ivEnc = data[(sep + 1)...]
        return SessionKeys(kEnc: Data(kEnc), ivEnc: Data(ivEnc), phase5RawKey: nil, receiverID: nil)
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
