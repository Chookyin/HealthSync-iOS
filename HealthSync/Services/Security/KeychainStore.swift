import Foundation
import Security

/// 敏感信息（API Token / 证书指纹）安全存储于 Keychain。
public final class KeychainStore: @unchecked Sendable {
    public enum Key: String, CaseIterable {
        case apiToken = "hermes_api_token"
        case serverHost = "hermes_server_host"
        case serverPort = "hermes_server_port"
        case trustFingerprint = "hermes_trust_fingerprint"
    }

    private let service: String

    public init(service: String = "com.example.HealthSync") {
        self.service = service
    }

    private func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    public func save(_ value: String, for key: Key) throws {
        let data = Data(value.utf8)
        var query = baseQuery(for: key)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(status: addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unhandled(status: status)
        }
    }

    public func read(_ key: Key) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(_ key: Key) throws {
        let query = baseQuery(for: key)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unhandled(status: status)
        }
    }

    public func deleteAll() throws {
        for key in Key.allCases {
            try delete(key)
        }
    }
}

public enum KeychainError: Error {
    case unhandled(status: OSStatus)
}
