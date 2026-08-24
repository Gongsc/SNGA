import Foundation
import Security

protocol AIKeyStore: Sendable {
    func apiKey() async throws -> String?
    func save(apiKey: String) async throws
    func removeAPIKey() async throws
}

struct KeychainAIKeyStore: AIKeyStore {
    static let shared = KeychainAIKeyStore()

    private let service = "cn.snga.client.ai"
    private let account = "openai-compatible-api-key"

    func apiKey() async throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw AIServiceError.keychain(status: status)
        }
        return key
    }

    func save(apiKey: String) async throws {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            try await removeAPIKey()
            return
        }
        let data = Data(normalized.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AIServiceError.keychain(status: updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AIServiceError.keychain(status: addStatus)
        }
    }

    func removeAPIKey() async throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIServiceError.keychain(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

#if DEBUG
actor InMemoryAIKeyStore: AIKeyStore {
    private var storedKey: String?

    init(apiKey: String? = nil) {
        self.storedKey = apiKey
    }

    func apiKey() -> String? {
        storedKey
    }

    func save(apiKey: String) {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        storedKey = normalized.isEmpty ? nil : normalized
    }

    func removeAPIKey() {
        storedKey = nil
    }
}
#endif
