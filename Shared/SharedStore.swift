import Foundation
import Security
import VirtCore

/// The last `today` the page sent, shared between the app and its widgets (compiled into both).
///
/// It's kept in a keychain group the two share (`6WK983RXJT.com.tyleralocke.virt.shared`, in both targets'
/// entitlements), not an App Group: App Store Connect's API can't create App Groups, and a keychain group needs no
/// registration at all (every App Store profile allows the team's own groups). The copy stays on this phone
/// (`ThisDeviceOnly`), readable after the first unlock so the widgets can draw while it's locked.
///
/// Saved-data rule: keys are only ever added. `today` holds TodayInfo's JSON (its fields only ever added too).
enum SharedStore {
    static let group = "6WK983RXJT.com.tyleralocke.virt.shared"
    static let service = "com.tyleralocke.virt.shared"
    static let todayKey = "today"
    /// The app's own copy, for when the shared keychain can't be used (the simulator's unsigned test builds).
    static let localKey = "virt.shared.today"

    /// What the last save did, for the test build's status line.
    private(set) static var note = "not saved"

    static func saveToday(_ t: TodayInfo) {
        guard let data = t.encoded() else { return }
        let status = write(data, key: todayKey)
        if status == errSecSuccess {
            note = "saved"
        } else {
            // no shared keychain (an unsigned simulator build): the app keeps its own copy
            UserDefaults.standard.set(data, forKey: localKey)
            note = status == errSecMissingEntitlement ? "app only (no keychain group)" : "app only (\(status))"
        }
    }

    static func loadToday() -> TodayInfo? {
        if let d = read(key: todayKey), let t = TodayInfo.decodeStored(d) { return t }
        return UserDefaults.standard.data(forKey: localKey).flatMap(TodayInfo.decodeStored)
    }

    /// Forgets the saved `today` (switching who signs in: the widgets never show the last person's day).
    static func clear() {
        SecItemDelete(base(todayKey) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: localKey)
        note = "cleared"
    }

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
         kSecAttrAccessGroup as String: group]
    }

    private static func write(_ data: Data, key: String) -> OSStatus {
        let q = base(key)
        let update = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update != errSecItemNotFound { return update }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }

    private static func read(key: String) -> Data? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
}
