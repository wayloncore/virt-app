import UIKit
import UserNotifications
import VirtCore

/// Workout reminders: "Today: Legs A" at his usual start time on training days (VirtCore's ReminderPlan), skipped
/// once today's workout is done. Each has "Move it" (an hour later) and "Start". Off until he says yes in the
/// friendly ask (or turns them on in Virt's settings).
///
/// Settings (saved-data rule: new keys only): `reminders.enabled` (nil until asked), `reminders.movedTo` (when
/// today's was moved to, epoch seconds).
@MainActor final class Reminders {
    static let shared = Reminders()

    static let category = "virt.reminder"
    static let moveAction = "virt.reminder.move"
    static let startAction = "virt.reminder.start"

    enum Key {
        static let enabled = "reminders.enabled"
        static let movedTo = "reminders.movedTo"
    }

    /// For the test build's status line: how many are scheduled.
    private(set) var count = 0

    /// nil until he's been asked.
    var enabled: Bool? {
        get { UserDefaults.standard.object(forKey: Key.enabled) as? Bool }
        set { UserDefaults.standard.set(newValue, forKey: Key.enabled) }
    }

    var movedTo: Date? {
        get { (UserDefaults.standard.object(forKey: Key.movedTo) as? Double).map { Date(timeIntervalSince1970: $0) } }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970, forKey: Key.movedTo) }
    }

    func registerCategory() {
        let move = UNNotificationAction(identifier: Self.moveAction, title: "Move it", options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "clock.arrow.circlepath"))
        let start = UNNotificationAction(identifier: Self.startAction, title: "Start", options: [.foreground],
                                         icon: UNNotificationActionIcon(systemImageName: "play.fill"))
        let cat = UNNotificationCategory(identifier: Self.category, actions: [move, start], intentIdentifiers: [],
                                         options: [])
        // the workout timer's alerts have their own category (no buttons), so the reminders' are never theirs
        let timer = UNNotificationCategory(identifier: TimerAlerts.category, actions: [], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat, timer])
    }

    /// Puts the week's reminders in place (replacing whatever was scheduled).
    func refresh(today: TodayInfo?, workoutGoing: Bool) {
        let center = UNUserNotificationCenter.current()
        let plan = enabled == true
            ? ReminderPlan.plan(today, now: Date(), movedTo: movedTo, workoutGoing: workoutGoing)
                + ReminderPlan.streakPlan(today, now: Date(), workoutGoing: workoutGoing)
            : []
        count = plan.count
        center.getPendingNotificationRequests { reqs in
            let old = reqs.map(\.identifier).filter { $0.hasPrefix(ReminderPlan.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            for r in plan {
                let content = UNMutableNotificationContent()
                content.title = r.title
                content.body = r.body
                content.sound = .default
                // the streak's morning nudge is a plain note: no Move it, no Start
                if !r.identifier.hasPrefix(ReminderPlan.streakPrefix) { content.categoryIdentifier = Self.category }
                content.threadIdentifier = "virt.reminder"
                content.interruptionLevel = .active
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: r.fireAt)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                center.add(UNNotificationRequest(identifier: r.identifier, content: content, trigger: trigger))
            }
        }
    }

    /// "Move it": today's reminder an hour later.
    func move(due: Date?) {
        movedTo = ReminderPlan.moved(from: due, now: Date())
        Engine.shared.refreshReminders()
    }

    /// He said yes: turn them on, asking iOS for alerts if it hasn't been asked yet. If iOS has alerts off for Virt
    /// (he said no to its question once, or switched them off), iOS won't ask again, so `blocked` runs and the
    /// caller offers the way to Settings (Tyler, Nov 23: saying yes must actually lead to iOS allowing them).
    /// `finished` runs last, either way (the settings tell the page).
    func turnOn(blocked: (@MainActor () -> Void)? = nil, finished: (@MainActor () -> Void)? = nil) {
        enabled = true
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .denied {
                Task { @MainActor in blocked?(); finished?() }
                return
            }
            center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
                Task { @MainActor in
                    Engine.shared.refreshReminders()
                    if !ok { blocked?() }
                    finished?()
                }
            }
        }
    }

    /// The window's root, for an alert asked for from a SwiftUI sheet.
    static func topController() -> UIViewController? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }.first
    }

    /// "Notifications are off for Virt": one alert with the way to Virt's page in Settings.
    static func offerSettings(from host: UIViewController?) {
        guard let host else { return }
        let a = UIAlertController(title: "Notifications are off for Virt",
                                  message: "Turn them on in Settings and your reminders will come through.",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Not now", style: .cancel))
        a.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let u = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(u) }
        })
        var top = host
        while let p = top.presentedViewController, !p.isBeingDismissed { top = p }
        top.present(a, animated: true)
    }

    func turnOff() {
        enabled = false
        Engine.shared.refreshReminders()
    }
}
