import Foundation
import Security

/// API keys live in a user-only file (0600) under Application Support.
///
/// History: these used to live in the login Keychain, but dev builds are
/// ad-hoc re-signed on every rebuild and the legacy keychain ACL model kept
/// demanding the login password whenever a differently-signed build rewrote
/// an item — editing a key in Settings meant delete + re-add per keystroke,
/// each one a password prompt. The ACL in use was already "any app may read
/// without confirmation", so the Keychain was adding prompts, not protection.
/// A file readable only by this user is the same effective security with no
/// prompts. Existing keychain values migrate over silently on first read
/// (reads never prompted; the old items are left behind, never touched).
enum Secrets {
    enum Account: String, CaseIterable {
        case deepgram
        case anthropic

        var legacyDefaultsKey: String {
            switch self {
            case .deepgram: return "deepgramAPIKey"
            case .anthropic: return "anthropicAPIKey"
            }
        }

        var environmentKey: String {
            switch self {
            case .deepgram: return "DEEPGRAM_API_KEY"
            case .anthropic: return "ANTHROPIC_API_KEY"
            }
        }
    }

    private static let service = "com.pavansai.ears"

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ears", isDirectory: true)
            .appendingPathComponent("secrets.json")
    }

    private static var cache: [String: String]?

    static func key(_ account: Account) -> String {
        var store = load()
        if let value = store[account.rawValue], !value.isEmpty {
            return value
        }
        // One-time migration from pre-file builds: Keychain first, then the
        // even older UserDefaults location.
        if let keychain = keychainRead(account), !keychain.isEmpty {
            store[account.rawValue] = keychain
            save(store)
            EarsLog.info("Migrated \(account.rawValue) key from the Keychain to the secrets file")
            return keychain
        }
        let legacy = (UserDefaults.standard.string(forKey: account.legacyDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !legacy.isEmpty {
            store[account.rawValue] = legacy
            save(store)
            UserDefaults.standard.removeObject(forKey: account.legacyDefaultsKey)
            EarsLog.info("Migrated \(account.rawValue) key from UserDefaults to the secrets file")
            return legacy
        }
        return ProcessInfo.processInfo.environment[account.environmentKey] ?? ""
    }

    static func set(_ value: String, for account: Account) {
        var store = load()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            store.removeValue(forKey: account.rawValue)
        } else {
            store[account.rawValue] = trimmed
        }
        save(store)
    }

    // MARK: - File store

    private static func load() -> [String: String] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            cache = [:]
            return [:]
        }
        cache = dict
        return dict
    }

    private static func save(_ store: [String: String]) {
        cache = store
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(store) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
        } catch {
            EarsLog.error("Failed to save secrets: \(error.localizedDescription)")
        }
    }

    // MARK: - Legacy Keychain (read-only migration source)

    /// Reads never prompted under the old open ACL; deletes/rewrites did.
    /// So: read once to migrate, never write or delete keychain items again.
    private static func keychainRead(_ account: Account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
