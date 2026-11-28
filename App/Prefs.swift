import UIKit
import UserNotifications
import VirtCore

/// The web shell, as the settings see it: the page gets `kineticApp.prefs` on every load and a `kinetic:prefs` event
/// when one changes.
@MainActor protocol PrefsPage: AnyObject {
    func prefsChanged(_ prefs: AppPrefs)
}

/// Virt's settings in one place (VirtCore's AppPrefs; the contract is in CLAUDE.md, "The bridge"). The settings sheet
/// and Training's You tab are two views of the same stored values, so both change them here: it stores the value,
/// does what the value does (alerts rescheduled, reminders set), and tells the page.
///
/// The stored keys are the ones from before (`sounds.enabled`, `sounds.style`, `reminders.enabled`): nothing new is
/// saved. Virt has no lock since Nov 28, so the page hears no lock setting. Build 100's stored lock setting
/// (`lock.after`) stays on the phone, never read and never cleared, so a rollback to build 100 still finds it.
@MainActor final class PrefsHub {
    static let shared = PrefsHub()

    weak var page: PrefsPage?
    /// False only when iOS has Virt's notifications off (denied). Read when Virt starts and each time it comes forward.
    private(set) var notificationsAllowed = true
    /// The last prefs the page was told, so an unchanged value isn't sent again.
    private var told: AppPrefs?
    /// For the test build's status line: how many `kinetic:prefs` events went to the page.
    private(set) var sent = 0

    var current: AppPrefs {
        AppPrefs(sounds: SoundBoard.shared.enabled, soundStyle: SoundBoard.shared.style,
                 reminders: Reminders.shared.enabled == true, reminderLine: ReminderLine.short(Engine.shared.today),
                 notifications: notificationsAllowed)
    }

    /// Tells the page, if anything changed since it was last told (or always, with `force`).
    func update(force: Bool = false) {
        let p = current
        guard force || p != told else { return }
        told = p
        sent += 1
        page?.prefsChanged(p)
    }

    /// Virt came forward (or started): iOS's notification setting may have changed in Settings, so read it and tell
    /// the page either way.
    func cameForward() {
        Task { @MainActor in
            await self.readNotifications()
            self.update(force: true)
        }
    }

    private func readNotifications() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = s.authorizationStatus != .denied
    }

    // MARK: - Changes (the sheet and the page)

    /// Sounds off: no sound from Virt at all (the app's own, and the Lock Screen alerts are scheduled silent).
    func setSounds(_ on: Bool) {
        SoundBoard.shared.enabled = on
        Engine.shared.soundsChanged()
        update()
    }

    /// `preview`: play the new style's sound once (the sheet does; from the page, only with Sounds on).
    func setStyle(_ s: SoundStyle, preview: Bool) {
        SoundBoard.shared.style = s
        if preview { SoundBoard.shared.preview(s) }
        Engine.shared.soundStyleChanged()
        update()
    }

    /// From the sheet: exactly as before (on asks iOS if it hasn't been asked; if iOS has them off, the sheet offers
    /// the way to Settings and the switch stays on).
    func setRemindersFromSheet(_ on: Bool) {
        if on {
            Reminders.shared.turnOn(blocked: { Reminders.offerSettings(from: Reminders.topController()) },
                                    finished: { Task { await self.readNotifications(); self.update() } })
        } else {
            Reminders.shared.turnOff()
            update()
        }
    }

    /// From the page: on runs the same path as "Remind me" (iOS asks if it never has). If iOS has them off, reminders
    /// stay off and the page hears `notifications: 'off'`, so it can offer the next step itself (no native alert).
    func setRemindersFromPage(_ on: Bool) {
        if on {
            Reminders.shared.turnOn(blocked: {
                Reminders.shared.enabled = false
                Engine.shared.refreshReminders()
            }, finished: { Task { await self.readNotifications(); self.update(force: true) } })
        } else {
            Reminders.shared.turnOff()
            update()
        }
    }

    /// iOS Settings, at Virt's notifications.
    func openNotificationSettings() {
        if let u = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(u) }
    }
}
