import Foundation
import Security

/// Where integration keys live. The real store is the login Keychain; a test host or a throwaway run keeps them in
/// memory, so neither prompts for the Keychain nor leaves keys behind.
nonisolated protocol CredentialStoring: Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

struct CredentialStoreError: Error, CustomStringConvertible {
    var status: OSStatus
    var description: String { (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)" }
}

/// Generic-password items under one service, one per integration. Each new build signature asks once whether the
/// app may read them; that is the Keychain working as intended.
nonisolated struct KeychainCredentialStore: CredentialStoring {
    var service = (Bundle.main.bundleIdentifier ?? "com.cnc.Gloss") + ".integrations"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read(account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
        return result as? Data
    }

    func write(_ data: Data, account: String) throws {
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw CredentialStoreError(status: update) }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Gloss \(account)"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError(status: status) }
    }
}

/// Keys for this run only.
nonisolated final class MemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()

    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return items[account] }
    func write(_ data: Data, account: String) throws { lock.lock(); defer { lock.unlock() }; items[account] = data }
    func delete(account: String) throws { lock.lock(); defer { lock.unlock() }; items[account] = nil }
}

nonisolated struct GitHubCredentials: Codable, Equatable, Sendable {
    var token: String
}

nonisolated struct AtlassianCredentials: Codable, Equatable, Sendable {
    var site: URL
    var email: String
    var token: String
}
