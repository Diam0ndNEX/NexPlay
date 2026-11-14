import Foundation
import Security

// 6.3.0: this iPhone's pairing file for built-in JIT. It is a credential for the device itself, so it lives in the
// Keychain (this device only, while unlocked), never in Application Support or Documents. Its bytes go only to the
// JIT helper, inside one request. Adapted from BCD's JITPairingFileStore in JITSetup.swift (GPL-3.0-or-later,
// Madeira Converter Exception). Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).

enum JITPairingStore {
    private static let service = "NexPlayJITPairing"
    private static let account = "pairing"
    private static let kindKey = "jitPairingKind"

    static var isPresent: Bool { (try? data()) != nil }

    /// "remote pairing" (RPPairing, from iloader) or "lockdown pairing" (idevice_pair, SideStore); nil without a file.
    static var kind: String? {
        isPresent ? (UserDefaults.standard.string(forKey: kindKey) ?? "pairing file") : nil
    }

    static func data() throws -> Data {
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
            throw JITError(message: "No pairing file is saved on this iPhone.")
        }
        return data
    }

    /// Reads a file picked in Files and saves it. Returns its kind.
    @discardableResult
    static func importFile(from url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try store(try Data(contentsOf: url))
    }

    /// Checks that the data is a pairing plist and makes it the pairing file. Returns its kind.
    @discardableResult
    static func store(_ data: Data) throws -> String {
        guard !data.isEmpty,
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else {
            throw JITError(message: "This file isn't a pairing file. Use the .mobiledevicepairing or .plist file that SideStore, StikDebug, idevice_pair or iloader made for this iPhone.")
        }
        let kind: String
        if plist["public_key"] is Data, plist["private_key"] is Data, plist["identifier"] is String {
            kind = "remote pairing"
        } else if plist["HostPrivateKey"] != nil || plist["HostCertificate"] != nil {
            kind = "lockdown pairing"
        } else {
            throw JITError(message: "This plist has no pairing keys. Use the pairing file made for this iPhone.")
        }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(item as CFDictionary)
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw JITError(message: "The pairing file couldn't be saved to the Keychain (error \(status)). Unlock the iPhone and try again.")
        }
        UserDefaults.standard.set(kind, forKey: kindKey)
        return kind
    }

    static func remove() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: kindKey)
    }
}
