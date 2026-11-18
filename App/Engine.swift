import ActivityKit
import AVFoundation
import UIKit
import UserNotifications
import VirtCore
import WidgetKit

/// The web shell, as the Engine sees it: it hands commands to the page and can bring Training's front page up.
@MainActor protocol PageCommands: AnyObject {
    func send(_ command: TimerCommand)
    func send(page command: PageCommand)
    /// Shows Training's front page unless a workout is going (Navigation.todayAction).
    func goToToday(midWorkout: Bool)
    /// The first-time reminders ask.
    func askAboutReminders()
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
    private var scheduledStyle = SoundBoard.shared.style
    private var chimeTimer: Timer?
    private var tickTimers: [Timer] = []
    private var quietTimer: Timer?
    private var askedForAlerts = false
    private var askedAboutReminders = false
    /// Commands for the page that wait until Training has loaded (Siri, widgets, reminders).
    private var queue = CommandQueue()
    /// The last `today` the page sent (also in the shared keychain, for the widgets).
    private(set) var today: TodayInfo?
    /// For the test build's status line.
    private(set) var lightTaps = 0
    private(set) var sentCommands: [String] = []

    // MARK: - Start

    func launched() {
        SoundBoard.shared.setUp()
        today = SharedStore.loadToday()
        Reminders.shared.registerCategory()
        refreshReminders()
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
        case .today(let t): return receiveToday(t)
        case .setLogged:
            if UIApplication.shared.applicationState == .active {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                SoundBoard.shared.play(.set)
                lightTaps += 1
            }
        case .workoutFinish: SoundBoard.shared.play(.finish)
        default: break
        }
        let wasGoing = board.workout != nil
        board.apply(message, now: Date())
        refresh()
        if wasGoing != (board.workout != nil) { refreshReminders() }
    }

    // MARK: - Today, for the widgets, Siri and the reminders

    private func receiveToday(_ t: TodayInfo) {
        var t = t
        t.receivedAt = Date()
        let changed = !t.samePlan(as: today)
        today = t
        SharedStore.saveToday(t)
        if changed { WidgetCenter.shared.reloadAllTimelines() }
        refreshReminders()
        maybeAskAboutReminders()
        onChange?()
    }

    func refreshReminders() {
        Reminders.shared.refresh(today: today, workoutGoing: board.workout != nil)
        onChange?()
    }

    /// The friendly ask, once, the first time Training says which days he trains and when (never mid-workout).
    private func maybeAskAboutReminders() {
        guard Reminders.shared.enabled == nil, !askedAboutReminders, board.workout == nil,
              let t = today, TodayInfo.time(t.usualTime) != nil, !(t.trainingDays ?? []).isEmpty else { return }
        askedAboutReminders = true
        page?.askAboutReminders()
    }

    // MARK: - Commands for the page (Siri, widgets, quick actions, reminders)

    /// Opens Training to today and starts today's workout (once the page is ready).
    func startToday() {
        page?.goToToday(midWorkout: board.midWorkout(now: Date()))
        flush(queue.add(.startToday(since: Date()), now: Date()))
    }

    /// Opens Training to today (a widget tap, a reminder).
    func openToday() {
        page?.goToToday(midWorkout: board.midWorkout(now: Date()))
    }

    /// A rest from Siri, Shortcuts or a quick action: Virt starts it at once (alert, Live Activity), and the page
    /// takes it over when it hears.
    func startRest(seconds: Int) {
        let now = Date()
        askForAlerts()
        board.startNativeRest(seconds: seconds, now: now)
        refresh()
        flush(queue.add(.rest(endsAt: now.addingTimeInterval(TimeInterval(seconds))), now: now))
    }

    /// A new page is loading in the web view: commands wait.
    func pageLoading() { queue.pageLoading() }

    /// Training is up and listening: send what's waiting.
    func pageReady() { flush(queue.pageReady(now: Date())) }

    private func flush(_ commands: [PageCommand]) {
        for c in commands {
            page?.send(page: c)
            switch c {
            case .startToday: sentCommands.append("startToday")
            case .rest(let s): sentCommands.append("rest \(s)")
            case .timer(let t): sentCommands.append(t.rawValue)
            }
        }
        if !commands.isEmpty { onChange?() }
    }

    /// The sound style changed: the alerts already scheduled get the new sound.
    func soundStyleChanged() {
        scheduled = [:]
        refresh()
    }

    /// A lock-screen or Dynamic Island button, or the test build's buttons.
    func command(_ c: TimerCommand) {
        board.apply(c, now: Date())
        refresh()
        page?.send(c)
    }

    func becameActive() {
        refresh()
        refreshReminders()
    }

    // MARK: - Out

    func refresh() {
        let now = Date()
        board.expireNative(now: now)
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
        if scheduledStyle != SoundBoard.shared.style { scheduledStyle = SoundBoard.shared.style; scheduled = [:] }
        let wanted = Set(plan.map(\.identifier))
        let gone = scheduled.keys.filter { !wanted.contains($0) }
        if !gone.isEmpty { center.removePendingNotificationRequests(withIdentifiers: gone) }
        for id in gone { scheduled[id] = nil }
        for a in plan {
            if let had = scheduled[a.identifier], abs(had.timeIntervalSince(a.fireAt)) < 0.05 { continue }
            let content = UNMutableNotificationContent()
            content.title = a.title
            content.body = a.body
            content.sound = SoundBoard.shared.notificationSound(a.cue)
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

    /// While the app is open: the soft 3-2-1 ticks, then the chime and a strong buzz at the exact zero (the
    /// notification is held back then, so they don't double up).
    private func armChime(now: Date) {
        chimeTimer?.invalidate()
        chimeTimer = nil
        tickTimers.forEach { $0.invalidate() }
        tickTimers = []
        guard let next = board.alerts(now: now).min(by: { $0.fireAt < $1.fireAt }) else { return }
        let cue = next.cue
        chimeTimer = exactTimer(at: next.fireAt) { self.zero(cue) }
        for at in LeadIn.ticks(zero: next.fireAt, now: now, length: next.length) {
            tickTimers.append(exactTimer(at: at) { SoundBoard.shared.play(.leadIn) })
        }
    }

    private func exactTimer(at: Date, _ run: @escaping @MainActor () -> Void) -> Timer {
        let t = Timer(fire: at, interval: 0, repeats: false) { _ in Task { @MainActor in run() } }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func zero(_ cue: SoundCue) {
        if UIApplication.shared.applicationState == .active {
            SoundBoard.shared.play(cue)
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
        if let e = board.countdown?.endsAt { parts.append("ends at \(Int(e.timeIntervalSince1970.rounded()))") }
        parts.append("alerts \(board.alerts(now: now).count)")
        parts.append(board.keepAwake(now: now) ? "awake on" : "awake off")
        parts.append("activity \(activityNote)")
        parts.append(board.workout.map { "workout \($0.title)" } ?? "no workout")
        parts.append("today \(today?.title ?? "none")\(today?.done == true ? " done" : "")")
        parts.append("store \(SharedStore.note)")
        parts.append("reminders \(Reminders.shared.count)")
        parts.append("taps \(lightTaps)")
        parts.append("sound \(SoundBoard.shared.last)")
        parts.append("sent \(sentCommands.isEmpty ? "none" : sentCommands.joined(separator: ","))")
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
        let id = notification.request.identifier
        // the timer chimes itself while the app is open, and a reminder isn't needed with Virt already open
        completionHandler(id.hasPrefix("virt.timer.") || id.hasPrefix(ReminderPlan.prefix) ? [] : [.banner, .sound])
    }

    /// A reminder's buttons: Move it (an hour later, without opening Virt), Start, or a tap (opens to today).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        guard request.identifier.hasPrefix(ReminderPlan.prefix) else { return completionHandler() }
        let due = (request.trigger as? UNCalendarNotificationTrigger).flatMap { Calendar.current.date(from: $0.dateComponents) }
            ?? response.notification.date
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            case Reminders.moveAction: Reminders.shared.move(due: due)
            case Reminders.startAction: Engine.shared.startToday()
            case UNNotificationDefaultActionIdentifier: Engine.shared.openToday()
            default: break
            }
            completionHandler()
        }
    }
}
