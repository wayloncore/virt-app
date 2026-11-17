import ActivityKit
import AVFoundation
import UIKit
import UserNotifications
import VirtCore

/// Something that can hand a lock-screen command to the page (the web shell).
@MainActor protocol PageCommands: AnyObject {
    func send(_ command: TimerCommand)
}

/// The native side of Training: it hears the page's messages, keeps the timer state (VirtCore's TimerBoard), and
/// turns it into the four things the web can't do well: alerts at the exact zero (local notifications), the Live
/// Activity, the screen kept awake, and the chime and buzz while the app is open.
///
/// Nothing here leaves the phone. No server, no analytics, no AI.
@MainActor final class Engine {
    static let shared = Engine()

    private(set) var board = TimerBoard()
    weak var page: PageCommands?
    /// For the test build's status line.
    var onChange: (() -> Void)?
    private(set) var activityNote = "off"

    private var activity: Activity<VirtTimerAttributes>?
    private var scheduled: [String: Date] = [:]
    private var chimeTimer: Timer?
    private var quietTimer: Timer?
    private var askedForAlerts = false
    private var player: AVAudioPlayer?

    // MARK: - Start

    func launched() {
        // the page's 3-2-1 beeps and the chime mix with Tyler's music and follow the silent switch
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        if let url = Bundle.main.url(forResource: "virt-chime", withExtension: "wav") {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
        }
        // an activity left from before the app was closed: keep one to update, end any extra
        let left = Activity<VirtTimerAttributes>.activities
        activity = left.first
        for extra in left.dropFirst() { Task { await extra.end(nil, dismissalPolicy: .immediate) } }
        UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
            let ours = reqs.filter { $0.identifier.hasPrefix("virt.timer.") }
            Task { @MainActor in
                for r in ours {
                    if let t = r.trigger as? UNTimeIntervalNotificationTrigger, let at = t.nextTriggerDate() { self.scheduled[r.identifier] = at }
                }
            }
        }
        refresh()
    }

    // MARK: - In

    func receive(_ message: BridgeMessage) {
        switch message {
        case .workoutStart, .timerStart: askForAlerts()
        default: break
        }
        board.apply(message, now: Date())
        refresh()
    }

    /// A lock-screen or Dynamic Island button, or the test build's buttons.
    func command(_ c: TimerCommand) {
        board.apply(c, now: Date())
        refresh()
        page?.send(c)
    }

    func becameActive() { refresh() }

    // MARK: - Out

    func refresh() {
        let now = Date()
        scheduleAlerts(now: now)
        updateActivity(now: now)
        UIApplication.shared.isIdleTimerDisabled = board.keepAwake(now: now)
        armChime(now: now)
        armQuietCheck()
        onChange?()
    }

    private func askForAlerts() {
        guard !askedForAlerts else { return }
        askedForAlerts = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.scheduled = [:]; self.refresh() }
        }
    }

    /// Alerts at the exact zero, with the phone locked or the app in the background. Each step has one identifier, so
    /// scheduling it again replaces it.
    private func scheduleAlerts(now: Date) {
        let center = UNUserNotificationCenter.current()
        let plan = board.alerts(now: now)
        let wanted = Set(plan.map(\.identifier))
        let gone = scheduled.keys.filter { !wanted.contains($0) }
        if !gone.isEmpty { center.removePendingNotificationRequests(withIdentifiers: gone) }
        for id in gone { scheduled[id] = nil }
        for a in plan {
            if let had = scheduled[a.identifier], abs(had.timeIntervalSince(a.fireAt)) < 0.05 { continue }
            let content = UNMutableNotificationContent()
            content.title = a.title
            content.body = a.body
            content.sound = UNNotificationSound(named: UNNotificationSoundName("virt-chime.wav"))
            content.interruptionLevel = .active
            content.threadIdentifier = "virt.timer"
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(0.1, a.fireAt.timeIntervalSince(now)), repeats: false)
            center.add(UNNotificationRequest(identifier: a.identifier, content: content, trigger: trigger))
            scheduled[a.identifier] = a.fireAt
        }
    }

    private func updateActivity(now: Date) {
        let display = board.display(now: now)
        let title = board.title
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            activityNote = "not allowed"
            return
        }
        if let d = display {
            let content = ActivityContent(state: d, staleDate: d.endsAt?.addingTimeInterval(120))
            if let a = activity, a.activityState == .active || a.activityState == .stale {
                Task { await a.update(content) }
                activityNote = "on"
            } else {
                do {
                    activity = try Activity.request(attributes: VirtTimerAttributes(title: title), content: content, pushType: nil)
                    activityNote = "on"
                } catch {
                    activity = nil
                    activityNote = "error: \(error.localizedDescription)"
                }
            }
        } else if let a = activity {
            activity = nil
            activityNote = "off"
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// While the app is open, the chime and a strong buzz at the exact zero (the notification is held back then, so
    /// they don't double up).
    private func armChime(now: Date) {
        chimeTimer?.invalidate()
        chimeTimer = nil
        guard let at = board.nextZero(now: now) else { return }
        let t = Timer(fire: at, interval: 0, repeats: false) { _ in
            Task { @MainActor in self.zero() }
        }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        chimeTimer = t
    }

    private func zero() {
        if UIApplication.shared.applicationState == .active {
            player?.currentTime = 0
            player?.play()
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1)
            }
        }
        refresh()
    }

    /// A workout the page never finished lets the screen sleep after a quiet spell; check once a minute while on.
    private func armQuietCheck() {
        let on = board.workout != nil
        if on && quietTimer == nil {
            quietTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                Task { @MainActor in
                    UIApplication.shared.isIdleTimerDisabled = self.board.keepAwake(now: Date())
                }
            }
        } else if !on {
            quietTimer?.invalidate()
            quietTimer = nil
        }
    }

    /// One line for the test build: the timer, alerts, screen and activity.
    var status: String {
        let now = Date()
        var parts: [String] = []
        if let c = board.countdown { parts.append("timer \(c.id) \(c.paused ? "paused" : "running")") } else { parts.append("timer none") }
        if let e = board.countdown?.endsAt { parts.append("ends in \(Int(e.timeIntervalSince(now).rounded()))s") }
        parts.append("alerts \(board.alerts(now: now).count)")
        parts.append(board.keepAwake(now: now) ? "awake on" : "awake off")
        parts.append("activity \(activityNote)")
        parts.append(board.workout.map { "workout \($0.title)" } ?? "no workout")
        return parts.joined(separator: " · ")
    }
}

/// Lock-screen buttons arrive here (TimerCommandIntent runs in the app).
enum CommandSink {
    static func run(_ c: TimerCommand) async {
        await MainActor.run { Engine.shared.command(c) }
    }
}

/// Holds back Virt's own timer alerts while the app is open (the app chimes then); shows everything else.
final class AlertPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier.hasPrefix("virt.timer.") ? [] : [.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
