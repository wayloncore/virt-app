import SwiftUI
import UIKit
import UserNotifications
import VirtCore

/// Virt's own settings and tips: a native sheet, because the page has no settings for these. Open it from the Home
/// Screen icon (touch and hold, Settings and tips) or `virt://settings`.
/// Who's signed in, for the settings sheet's Sign-in section, and what it can do.
struct SettingsAccount {
    var door: Door?
    /// The friend's name ("Sam"); empty for Tyler's door.
    var name: String
    /// Tyler's own Training, signed in with Apple (#732).
    var owner = false
    /// Switching waits until the workout's done.
    var midWorkout: Bool
    var leave: () -> Void
    /// Deletes a friend's account: nil when it's done, otherwise why not.
    var delete: () async -> String?
    /// On the studio's sign-in: Sign in with Apple instead (links it to his studio Training). nil when done.
    var apple: () async -> String? = { nil }
    /// Signed in with Apple as Tyler: back to the studio's sign-in.
    var studio: () -> Void = {}
}

struct SettingsView: View {
    var account: SettingsAccount
    var done: () -> Void

    @State private var confirmLeave = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteNote: String?

    @State private var soundsOn = SoundBoard.shared.enabled
    @State private var style = SoundBoard.shared.style
    @State private var remindersOn = Reminders.shared.enabled == true
    @State private var alertsDenied = false
    private let today = Engine.shared.today

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Signed in", value: account.owner ? "Tyler, with Apple" : account.door == .friend ? (account.name.isEmpty ? "With Apple" : account.name) : "Tyler's studio")
                        .accessibilityIdentifier("signed-in-as")
                    if account.door == .tyler {
                        Button("Sign in with Apple") {
                            deleting = true
                            deleteNote = nil
                            Task {
                                let why = await account.apple()
                                deleting = false
                                deleteNote = why
                            }
                        }
                        .disabled(account.midWorkout || deleting)
                        .accessibilityIdentifier("owner-apple")
                    }
                    if account.owner {
                        Button("Use the studio sign-in") { account.studio() }
                            .disabled(account.midWorkout || deleting)
                            .accessibilityIdentifier("owner-studio")
                    }
                    Button(account.owner ? "Sign out" : "Switch sign-in") { confirmLeave = true }
                        .disabled(account.midWorkout || deleting)
                        .accessibilityIdentifier("switch-sign-in")
                    if account.door == .friend && !account.owner {
                        Button("Delete account", role: .destructive) { confirmDelete = true }
                            .disabled(account.midWorkout || deleting)
                            .accessibilityIdentifier("delete-account")
                    }
                } header: {
                    Text("Sign-in")
                } footer: {
                    Text(signInFooter)
                }

                Section {
                    Toggle("Sounds", isOn: $soundsOn)
                        .onChange(of: soundsOn) { _, on in SoundBoard.shared.enabled = on }
                        .accessibilityIdentifier("sounds-toggle")
                    Picker("Style", selection: $style) {
                        ForEach(SoundStyle.allCases, id: \.self) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name)
                                Text(s.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(s)
                        }
                    }
                    .pickerStyle(.inline)
                    .disabled(!soundsOn)
                    .onChange(of: style) { _, s in
                        SoundBoard.shared.style = s
                        SoundBoard.shared.preview(s)
                        Engine.shared.soundStyleChanged()
                    }
                } header: {
                    Text("Sounds")
                } footer: {
                    Text("The 3-2-1 ticks, the chime at zero, a click when a set is logged, and a short finish. They mix with your music and follow the silent switch. Lock Screen alerts use the same chime even with Sounds off; change those in iOS Settings, Notifications, Virt.")
                }

                Section {
                    Toggle("Training-day reminders", isOn: $remindersOn)
                        .onChange(of: remindersOn) { _, on in on ? Reminders.shared.turnOn() : Reminders.shared.turnOff() }
                        .accessibilityIdentifier("reminders-toggle")
                    if alertsDenied {
                        Button("Turn on notifications for Virt") {
                            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                        }
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text(ReminderCopy.line(today))
                }

                Section("Training Focus") {
                    Tip(lines: [
                        "In Settings, open Focus and tap +. Choose Fitness, or Custom and name it Training.",
                        "Under Allowed Notifications, choose Apps and add Virt. Everything else waits until you're done.",
                        "Turn it on from Control Center when you start. To have it come on by itself, make a Shortcuts automation: When Virt is opened, Set Focus to Training, until you turn it off.",
                    ])
                }

                Section("Siri and the Action button") {
                    Tip(lines: [
                        "Say \"Start my workout in Virt\" or \"Start a rest timer in Virt\". \"Rest for 90 seconds in Virt\" works too.",
                        "On an iPhone with an Action button: Settings, Action Button, Shortcut, then Virt's Start a rest timer (90 seconds unless you set it).",
                    ])
                }

                Section("Widgets") {
                    Tip(lines: [
                        "Home Screen: touch and hold an empty spot, tap Edit, then Add Widget, and find Virt.",
                        "Lock Screen: touch and hold it, tap Customize, then the Lock Screen and the row under the clock, and find Virt.",
                    ])
                }
            }
            .navigationTitle("Virt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done).accessibilityIdentifier("settings-done") } }
        }
        .tint(.virtGold)
        .alert("Switch sign-in?", isPresented: $confirmLeave) {
            Button("Sign out", role: .destructive) { account.leave() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(account.door == .friend
                 ? "You're signed out on this phone and Virt goes back to its first screen. Your training stays in your account."
                 : "This phone signs out of the studio and Virt goes back to its first screen. Training's copy on this phone stays.")
        }
        .alert("Delete your account?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                deleting = true
                deleteNote = nil
                Task {
                    deleteNote = await account.delete()
                    deleting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your Time2Play account and all of your training, for good. Apple asks you to confirm it's you.")
        }
        .task {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            alertsDenied = s.authorizationStatus == .denied
        }
    }
}

extension SettingsView {
    var signInFooter: String {
        if account.midWorkout { return "Finish the workout first, then you can switch." }
        if deleting { return account.door == .tyler ? "Signing in with Apple…" : "Deleting…" }
        if let n = deleteNote { return n }
        if account.owner { return "Your own Training, signed in with Apple. Only your Apple ID opens it; the studio's email sign-in is the backup." }
        return account.door == .friend
            ? "Signed in with Apple to your Time2Play account. Only you see your training: no AI and no analytics."
            : "Studio Training, signed in with the studio's email code. Sign in with Apple to use your Apple ID instead: Virt links it to your Training for you."
    }
}

private struct Tip: View {
    let lines: [String]

    var body: some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(i + 1)").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Color.virtGold)
                Text(l).font(.subheadline)
            }
        }
    }
}

enum ReminderCopy {
    /// "One nudge at 6:30 PM on Mon, Wed and Fri, with the day's workout..."
    static func line(_ t: TodayInfo?) -> String {
        let time = TodayInfo.clockLabel(t?.usualTime)
        let days = t?.trainingDays.map(TodayInfo.daysLine) ?? ""
        let when: String
        switch (time, days.isEmpty) {
        case (let time?, false): when = days == "every day" ? "at \(time) every day" : "at \(time) on \(days)"
        case (let time?, true): when = "at \(time) on your training days"
        case (nil, false): when = "on \(days), at your usual time once Training knows it"
        default: when = "on your training days, at your usual time once Training knows it"
        }
        return "One nudge \(when), with the day's workout. It's skipped once you've trained, and Move it pushes it an hour."
    }
}

/// The friendly first ask, as a small sheet, the first time Training says which days he trains.
struct ReminderAskView: View {
    let today: TodayInfo?
    var answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bell.badge").font(.system(size: 34, weight: .semibold)).foregroundStyle(Color.virtGold)
                .padding(.top, 8)
            Text("A nudge on training days?").font(.title2.weight(.semibold)).foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(ReminderCopy.line(today)).font(.body).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Button { answer(true) } label: {
                    Text("Remind me").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.virtGold)
                .foregroundStyle(Color.virtBlack)
                .accessibilityIdentifier("remind-yes")
                Button { answer(false) } label: {
                    Text("Not now").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityIdentifier("remind-no")
            }
            Text("You can change this any time in Virt's settings (touch and hold the Virt icon).")
                .font(.footnote).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.virtBlack)
    }
}
