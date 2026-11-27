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

    @State private var lockAfter = LockAfter(stored: UserDefaults.standard.string(forKey: LockAfter.key))
    @State private var soundsOn = SoundBoard.shared.enabled
    @State private var style = SoundBoard.shared.style
    @State private var remindersOn = Reminders.shared.enabled == true
    @State private var alertsDenied = false
    private let today = Engine.shared.today

    /// One style in the list: its name (and what it does, for the three that differ), a check on the chosen one.
    private func styleRow(_ s: SoundStyle) -> some View {
        Button {
            style = s
            PrefsHub.shared.setStyle(s, preview: true)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).foregroundStyle(soundsOn ? Color.primary : Color.secondary)
                    if !s.isTone {
                        Text(s.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if s == style {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.virtAccent)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(!soundsOn)
        .accessibilityIdentifier("style-\(s.rawValue)")
        .accessibilityAddTraits(s == style ? .isSelected : [])
    }

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
                    Picker("Lock after", selection: $lockAfter) {
                        ForEach(LockAfter.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .onChange(of: lockAfter) { _, l in PrefsHub.shared.setLockAfter(l) }
                    .accessibilityIdentifier("lock-after")
                } header: {
                    Text("Face ID")
                } footer: {
                    Text(lockAfter == .never
                         ? "Virt opens without Face ID. Anyone holding this unlocked iPhone can see your training."
                         : "Face ID asks when you come back to Virt after this long away. Never in the middle of a workout.")
                }

                Section {
                    Toggle("Sounds", isOn: $soundsOn)
                        .onChange(of: soundsOn) { _, on in PrefsHub.shared.setSounds(on) }
                        .accessibilityIdentifier("sounds-toggle")
                } header: {
                    Text("Sounds")
                } footer: {
                    Text("A sound at each zero, the 3-2-1 before it, a click when a set is logged, and a short finish. They mix with your music and follow the silent switch. With the phone locked the same sound comes with a quiet alert, which Virt clears once you're back. With Sounds off, Virt makes no sound at all, on the Lock Screen too.")
                }

                // The styles, grouped (VirtCore's SoundStyle.Group): tap one to choose it and hear it (its work-ends
                // sound), again to hear it again.
                ForEach(SoundStyle.Group.allCases, id: \.self) { g in
                    Section {
                        ForEach(SoundStyle.styles(in: g), id: \.self) { s in styleRow(s) }
                    } header: {
                        Text(g.rawValue)
                    } footer: {
                        if g == .playful {
                            Text("Chime and Digital play a green light when a rest ends (three short tones, then go on the zero). Every other tone plays at both zeros, after the 3-2-1.")
                        }
                    }
                }

                Section {
                    Toggle("Training-day reminders", isOn: $remindersOn)
                        .onChange(of: remindersOn) { _, on in PrefsHub.shared.setRemindersFromSheet(on) }
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
        .tint(.virtAccent)
        .alert(AccountCopy.signOutTitle, isPresented: $confirmLeave) {
            Button("Sign out", role: .destructive) { account.leave() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AccountCopy.signOutMessage(account.door))
        }
        .alert(AccountCopy.deleteTitle, isPresented: $confirmDelete) {
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
            Text(AccountCopy.deleteMessage)
        }
        .task {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            alertsDenied = s.authorizationStatus == .denied
        }
    }
}

extension SettingsView {
    var signInFooter: String {
        if account.midWorkout { return AccountAsk.finishFirstLine }
        if deleting { return account.door == .tyler ? "Signing in with Apple…" : "Deleting…" }
        if let n = deleteNote { return n }
        if account.owner { return "Your own Training, signed in with Apple. Only your Apple ID opens it." }
        return account.door == .friend
            ? "Signed in with Apple to your Time2Play account. Only you see your training: no AI and no analytics."
            : "Studio Training, signed in with the studio's email code. Sign in with Apple to use your Apple ID instead: Virt links it to your Training for you."
    }
}

/// The sign-out and Delete account confirmations, the same words in the sheet and when the page asks.
enum AccountCopy {
    static let signOutTitle = "Switch sign-in?"
    static func signOutMessage(_ door: Door?) -> String {
        door == .friend
            ? "You're signed out on this phone and Virt goes back to its first screen. Your training stays in your account."
            : "This phone signs out of the studio and Virt goes back to its first screen. Training's copy on this phone stays."
    }
    static let deleteTitle = "Delete your account?"
    static let deleteMessage = "This deletes your Time2Play account and all of your training, for good. Apple asks you to confirm it's you."
}

private struct Tip: View {
    let lines: [String]

    var body: some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(i + 1)").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Color.virtAccent)
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
            Image(systemName: "bell.badge").font(.system(size: 34, weight: .semibold)).foregroundStyle(Color.virtAccent)
                .padding(.top, 8)
            Text("A nudge on training days?").font(.title2.weight(.semibold)).foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(ReminderCopy.line(today)).font(.body).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Button { answer(true) } label: {
                    Text("Remind me").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.virtAccent)
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
