import Foundation

// Virt's own settings, shown and changed on Training's You tab (the website's docs/kinetic/bridge.md, "prefs").
// The page and Virt's settings sheet are two views of the same stored values: Virt keeps them, the page asks.
//
// - Virt sets `window.kineticApp.prefs` before the page's scripts on every load (`PageStart.script(build:prefs:)`).
// - Virt dispatches a `kinetic:prefs` event (CustomEvent, `detail` = the same object) whenever one changes, from
//   either side, and when the app comes forward (iOS's notification setting may have changed). The event also
//   updates `kineticApp.prefs` in place, so the page can read either.
// - The page posts `{ type: 'pref', key, value }`, `{ type: 'openNotificationSettings' }`, `{ type: 'deleteAccount' }`
//   and `{ type: 'signOut' }` on the `kinetic` handler (`AppRequest`). Unknown keys and out-of-range values are
//   ignored.
// - No `lockAfter` (Nov 28): Virt has no lock of its own, so it never sends one, and an older page's
//   `{ type: 'pref', key: 'lockAfter' }` is ignored quietly like any other key Virt doesn't know. The website reads an
//   absent `lockAfter` as "no app lock" and shows no Lock and privacy row. Build 100's stored "Lock after"
//   (`lock.after` in UserDefaults) stays on the phone, unread, so a rollback to it still finds the setting.

/// The values the page sees, in the order it sees them.
public struct AppPrefs: Equatable, Sendable {
    /// Virt's "Sounds" switch. Off: no sound from Virt at all, in the app or on the Lock Screen.
    public var sounds: Bool
    /// Any id in `soundStyles`, the full list (`[{ id, name, group }]`, in display order) that comes with every
    /// object, so the page never keeps its own copy of the styles.
    public var soundStyle: SoundStyle
    /// Training-day reminders on.
    public var reminders: Bool
    /// When the reminders come, "6:00 PM on Mon, Tue and Thu"; "" when they're off or Training hasn't said yet.
    public var reminderLine: String
    /// False only when iOS has Virt's notifications turned off (he said no once, or switched them off in Settings).
    /// Never asked yet reads as on: Virt asks when it needs them, and Settings can't help until iOS has asked.
    public var notifications: Bool

    public init(sounds: Bool, soundStyle: SoundStyle, reminders: Bool, reminderLine: String, notifications: Bool) {
        self.sounds = sounds; self.soundStyle = soundStyle; self.reminders = reminders
        self.reminderLine = reminderLine; self.notifications = notifications
    }

    /// The object as JSON (valid JavaScript), keys always in this order; `soundStyles` last (added Nov 27). No
    /// `lockAfter` since Nov 28: Virt has no lock (the website reads it as optional).
    public var json: String {
        "{\"sounds\":\(sounds),\"soundStyle\":\(Self.quote(soundStyle.rawValue)),\"reminders\":\(reminders),"
            + "\"reminderLine\":\(Self.quote(reminders ? reminderLine : "")),"
            + "\"notifications\":\(Self.quote(notifications ? "on" : "off")),\"soundStyles\":\(SoundStyle.listJSON)}"
    }

    /// The `kinetic:prefs` event, and `kineticApp.prefs` brought up to date in place.
    public var eventScript: String {
        """
        (() => { try { const p = \(json); const k = window.kineticApp;
          if (k && k.prefs && typeof k.prefs === 'object') Object.assign(k.prefs, p);
          window.dispatchEvent(new CustomEvent('kinetic:prefs', { detail: p })); } catch (e) {} })();
        """
    }

    /// A string as a JSON string literal: quotes, backslashes and every control character escaped, and the two line
    /// separators JavaScript once treated as line ends, so nothing the page sent can break out of it.
    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<": out += "\\u003c"  // never "</script>", wherever the string ends up
            default:
                if u.value < 0x20 || u.value == 0x2028 || u.value == 0x2029 || (0x7F...0x9F).contains(u.value) {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}

/// The reminders' one line for the page: "6:00 PM on Mon, Tue and Thu", "6:00 PM every day", or "" until Training
/// has said both the time and the days (the settings sheet's longer copy covers the rest).
public enum ReminderLine {
    public static func short(_ t: TodayInfo?) -> String {
        guard let time = TodayInfo.clockLabel(t?.usualTime) else { return "" }
        let days = TodayInfo.daysLine((t?.trainingDays ?? []).filter { (0...6).contains($0) })
        if days.isEmpty { return "" }
        return days == "every day" ? "\(time) every day" : "\(time) on \(days)"
    }
}

/// What the page asks of Virt on the `kinetic` handler, beyond the workout's own messages. Not Engine messages: the
/// app does them itself. nil for anything else, a key Virt doesn't know or a value out of range (ignored). That
/// includes an older page's `lockAfter`: Virt has no lock since Nov 28.
public enum AppRequest: Equatable, Sendable {
    case setSounds(Bool)
    case setSoundStyle(SoundStyle)
    case setReminders(Bool)
    /// iOS Settings, at Virt's notifications.
    case openNotificationSettings
    /// The app's own Delete account flow (its native confirmation still asks).
    case deleteAccount
    /// The same as the settings sheet's "Switch sign-in" / "Sign out" (its native confirmation asks).
    case signOut

    /// The message types this reads; anything else isn't an AppRequest at all.
    public static let types: Set<String> = ["pref", "openNotificationSettings", "deleteAccount", "signOut"]

    /// True for a message of one of these types, valid or not (so the app never hands it on to the Engine).
    public static func isRequest(object: Any) -> Bool {
        guard let d = object as? [String: Any], let t = d["type"] as? String else { return false }
        return types.contains(t)
    }

    public static func decode(object: Any) -> AppRequest? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return decode(data)
    }

    public static func decode(_ data: Data) -> AppRequest? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), let type = raw.type else { return nil }
        switch type {
        case "openNotificationSettings": return .openNotificationSettings
        case "deleteAccount": return .deleteAccount
        case "signOut": return .signOut
        case "pref": break
        default: return nil
        }
        switch (raw.key, raw.value) {
        case ("sounds", .bool(let b)?): return .setSounds(b)
        case ("reminders", .bool(let b)?): return .setReminders(b)
        case ("soundStyle", .text(let s)?): return SoundStyle(rawValue: s).map { .setSoundStyle($0) }
        default: return nil
        }
    }

    /// Only Training's own pages may ask, and only from their main frame: the friends' page (or the bundle's own),
    /// and studio Training (https). The same rule as the page's `settings` message.
    public static func allowed(isMainFrame: Bool, scheme: String, host: String, bundled: Bool) -> Bool {
        guard isMainFrame else { return false }
        if Navigation.isFriendOrigin(scheme: scheme, host: host, bundled: bundled) { return true }
        return scheme.lowercased() == "https" && host.lowercased() == Navigation.studioHost
    }

    private enum Value: Decodable, Equatable {
        case bool(Bool), text(String), other
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) } else if let s = try? c.decode(String.self) { self = .text(s) } else { self = .other }
        }
    }

    private struct Raw: Decodable {
        var type: String?, key: String?, value: Value?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil
            key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? nil
            value = (try? c.decodeIfPresent(Value.self, forKey: .value)) ?? nil
        }
        enum K: String, CodingKey { case type, key, value }
    }
}

/// What the app does with the page's `signOut` and `deleteAccount`, by the settings sheet's own rules.
public enum AccountAsk: Equatable, Sendable {
    /// Show the sheet's own "Switch sign-in?" confirmation.
    case confirmSignOut
    /// Show the sheet's own "Delete your account?" confirmation.
    case confirmDelete
    /// Mid-workout: say "Finish the workout first, then you can switch." and do nothing else.
    case finishFirst
    /// Not here: a guest (no account), no one signed in, or Delete account where the sheet doesn't offer it.
    case ignore

    /// `owner`: Tyler's own Training, signed in with Apple. The sheet offers Delete account only on a friend's door
    /// that isn't Tyler's, and sign out on any door; a guest gets neither.
    public static func decide(_ r: AppRequest, door: Door?, owner: Bool, guest: Bool, midWorkout: Bool) -> AccountAsk {
        guard let door, !guest else { return .ignore }
        switch r {
        case .signOut:
            return midWorkout ? .finishFirst : .confirmSignOut
        case .deleteAccount:
            guard door == .friend, !owner else { return .ignore }
            return midWorkout ? .finishFirst : .confirmDelete
        default:
            return .ignore
        }
    }

    public static let finishFirstLine = "Finish the workout first, then you can switch."
}
