import Foundation
import Security
import UIKit
import VirtCore

/// Keeps what Virt saves readable while the phone is locked (after its first unlock), so a lock-screen press never
/// meets data it can't read (docs/lock-screen-buttons.md).
///
/// - The keychain copies (the widgets' `today`, the studio's sign-in, a friend's session) are written "after first
///   unlock, this phone only". Apple's default for an item is "when unlocked", so `moveIfNeeded` checks each one at
///   launch and whenever the phone unlocks, and moves any item kept another way to that class. The data stays the
///   same, so the build before this one reads it exactly as before.
/// - The board, the live-workout memory and held Log set presses are in UserDefaults, whose file iOS keeps under its
///   default protection ("complete until first user authentication"); Virt never sets a stricter class.
enum LockedRead {
    struct Item {
        let name: String
        let service: String
        let account: String
        let group: String?
    }

    static let items: [Item] = [
        Item(name: "today", service: SharedStore.service, account: SharedStore.todayKey, group: SharedStore.group),
        Item(name: "signin", service: "com.tyleralocke.virt.signin", account: "session-cookies", group: nil),
        Item(name: "friend", service: "com.tyleralocke.virt.friend", account: "session", group: nil),
    ]

    private static func query(_ i: Item) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: i.service,
                                kSecAttrAccount as String: i.account]
        if let g = i.group { q[kSecAttrAccessGroup as String] = g }
        return q
    }

    /// The item's stored class (`ak`, `cku`...), or nil with no item (or no keychain: an unsigned simulator build).
    static func storedClass(_ i: Item) -> String? {
        var q = query(i)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let attrs = out as? [String: Any] else { return nil }
        return attrs[kSecAttrAccessible as String] as? String
    }

    /// Moves any item a locked phone couldn't read to "after first unlock, this phone only". Only while the phone is
    /// unlocked (a "when unlocked" item can't be reached otherwise); nothing is deleted.
    @MainActor static func moveIfNeeded() {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        for i in items where LockedAccess.keychainNeedsMove(storedClass(i)) {
            SecItemUpdate(query(i) as CFDictionary,
                          [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        }
    }

    /// UserDefaults' file and its protection class (nil: none set, as in the simulator).
    static func defaultsProtection() -> String? {
        guard let id = Bundle.main.bundleIdentifier,
              let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let file = lib.appendingPathComponent("Preferences/\(id).plist")
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        return (attrs?[.protectionKey] as? FileProtectionType)?.rawValue
    }

    /// The test build's status line: "ok", or what a locked phone couldn't read. Also checks that VirtCore's class
    /// name is the Security framework's own.
    static var summary: String {
        let sameName = (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) == LockedAccess.keychainClass
        let s = LockedAccess.summary(keychain: items.map { ($0.name, storedClass($0)) },
                                     files: [("defaults", defaultsProtection())])
        return sameName ? s : "class name \(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)"
    }
}
