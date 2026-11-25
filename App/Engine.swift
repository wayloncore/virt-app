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
    /// The zero whose sound has started (its identifier and end), so arming again never plays it twice.
    private var soundStarted: String?
    private var quietTimer: Timer?
    private var askedForAlerts = false
    private var askedAboutReminders = false
    /// Log set from the lock screen: one press is one set (VirtCore's LogPress).
    private var logPress = LogPress()
    /// The page's own word on whether a workout is open (`live` on `today`), and when it said it. nil from a page that
    /// doesn't say.
    private var pageLive: Bool?
    private var pageLiveAt: Date?
    /// The last copies kept on the phone, so they're written only when they change.
    private var keptBoard: TimerBoard.Snapshot?
    private var keptLive: LiveWorkout.Memory?
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
        // the workout as it was when Virt last ran (iOS may have ended the app since): a lock-screen button that woke
        // this launch still finds the set to log and keeps the Live Activity
        let now = Date()
        board = TimerBoard.restored(from: TimerBoard.Snapshot.decode(UserDefaults.standard.data(forKey: TimerBoard.Snapshot.key)), now: now)
        keptBoard = board.snapshot
        if let m = LiveWorkout.Memory.decode(UserDefaults.standard.data(forKey: LiveWorkout.Memory.key)) {
            keptLive = m
            // the page's own word carries across the launch, until the page speaks again
            if m.fromPage, m.stillLive(now: now) { pageLive = true; pageLiveAt = m.seenAt }
        }
        today = SharedStore.loadToday()
        Reminders.shared.registerCategory()
        refreshReminders()
        // an activity left from before the app was closed: keep one to update, end any extra
        let left = Activity<VirtTimerAttributes>.activities
        activity = left.first
        for extra in left.dropFirst() { Task { await extra.end(nil, dismissalPolicy: .immediate) } }
        UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
            let ours = reqs.filter { TimerAlerts.isTimer($0.identifier) }
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
        // the first workout asks iOS for alerts while Virt is open, never from a lock-screen press (a locked phone
        // can't show the ask)
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
        // a finished or closed workout isn't live, whatever the last `today` said
        if case .workoutFinish = message, pageLive != nil { pageLive = false; pageLiveAt = Date() }
        if case .workoutClose = message, pageLive != nil { pageLive = false; pageLiveAt = Date() }
        let wasGoing = board.workout != nil
        board.apply(message, now: Date())
        refresh()
        if wasGoing != (board.workout != nil) { refreshReminders() }
        // the workout's over: its alerts leave Notification Center too
        if wasGoing && board.workout == nil { clearDeliveredTimerAlerts(everything: true) }
    }

    // MARK: - Today, for the widgets, Siri and the reminders

    private func receiveToday(_ t: TodayInfo) {
        var t = t
        t.receivedAt = Date()
        if let live = t.live {
            pageLive = live
            pageLiveAt = t.receivedAt
            keepLive(now: Date())
        }
        let changed = !t.samePlan(as: today)
        today = t
        SharedStore.saveToday(t)
        if changed { WidgetCenter.shared.reloadAllTimelines() }
        refreshReminders()
        maybeAskAboutReminders()
        onChange?()
    }

    /// Someone signed out of a door (Virt's settings, or a friend's page): the widgets, Siri's "today" and the
    /// reminders forget that person's day, any timer and its Live Activity end, and the friendly reminders ask comes
    /// again for whoever signs in next.
    func startFresh() {
        board = TimerBoard()
        queue = CommandQueue()
        pageLive = nil
        pageLiveAt = nil
        refresh()
        clearDeliveredTimerAlerts(everything: true)
        today = nil
        SharedStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
        Reminders.shared.enabled = nil
        Reminders.shared.movedTo = nil
        askedAboutReminders = false
        askNote = "not yet"
        refreshReminders()
    }

    func refreshReminders() {
        Reminders.shared.refresh(today: today, workoutGoing: board.workout != nil)
        onChange?()
    }

    /// The friendly ask, once, the first time Training says which days he trains and when (never mid-workout).
    private func maybeAskAboutReminders() {
        guard Reminders.shared.enabled == nil, !askedAboutReminders else { return }
        guard board.workout == nil else { askNote = "later (mid-workout)"; return }
        guard let t = today, TodayInfo.time(t.usualTime) != nil, !(t.trainingDays ?? []).isEmpty else {
            askNote = "waiting for days and time"
            return
        }
        askedAboutReminders = true
        askNote = page == nil ? "no page" : "asked"
        page?.askAboutReminders()
    }

    /// For the test build's status line: what the reminders ask did.
    var askNote = "not yet"

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
            case .log: sentCommands.append("log")
            }
        }
        if !commands.isEmpty { onChange?() }
    }

    /// The sound style changed: the alerts already scheduled get the new sound.
    func soundStyleChanged() {
        scheduled = [:]
        refresh()
    }

    /// A lock-screen or Dynamic Island button, Control Center's Log set, or the test build's buttons. They run in
    /// Virt's process with the phone locked, so nothing here asks iOS for anything or needs the phone unlocked.
    func command(_ c: TimerCommand) {
        let now = Date()
        if c == .log {
            // one press, one set: a burst counts once, and nothing goes with no set left to log (#573). It goes with the
            // moment it was pressed and its own id, so the page's rest lines up and a repeat is dropped.
            let cmd = logPress.press(board: &board, now: now, id: UUID().uuidString)
            refresh()
            if let cmd { page?.send(page: cmd) }
            return
        }
        board.apply(c, now: now)
        refresh()
        page?.send(c)
    }

    func becameActive() {
        refresh()
        refreshReminders()
        // Virt's open: no workout-timer alert stays on the Lock Screen or in Notification Center
        clearDeliveredTimerAlerts(everything: true)
    }

    // MARK: - Live workouts (the lock never asks during one)

    /// True while a workout is live: the page's word when it gives one, Virt's own rule otherwise (VirtCore's
    /// LiveWorkout).
    func liveWorkout(now: Date) -> Bool {
        LiveWorkout.isLive(pageLive: pageLive, pageSaidAt: pageLiveAt, board: board, now: now)
    }

    /// At a fresh launch or a scene iOS built again: was a workout live when Virt last ran?
    func liveAtLaunch(now: Date) -> Bool {
        liveWorkout(now: now) || (keptLive?.stillLive(now: now) ?? false)
    }

    /// Keeps the board and the live state on the phone (UserDefaults: readable with the phone locked after its first
    /// unlock, which is when the lock-screen buttons run), only when they change.
    private func keep(now: Date) {
        let snap = board.snapshot
        if snap != keptBoard {
            keptBoard = snap
            UserDefaults.standard.set(snap.encoded(), forKey: TimerBoard.Snapshot.key)
        }
        keepLive(now: now)
    }

    private func keepLive(now: Date) {
        let live = liveWorkout(now: now)
        if let k = keptLive, k.live == live, k.fromPage == (pageLive != nil), !live || now.timeIntervalSince(k.seenAt) < 30 { return }
        let m = LiveWorkout.Memory(live: live, seenAt: now, fromPage: pageLive != nil)
        keptLive = m
        UserDefaults.standard.set(m.encoded(), forKey: LiveWorkout.Memory.key)
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
        keep(now: now)
        // each time Virt runs, the timer alerts already delivered go (one still sounding stays while in the background)
        clearDeliveredTimerAlerts(everything: UIApplication.shared.applicationState == .active)
        onChange?()
    }

    /// Takes the workout timer's delivered alerts out of Notification Center and off the Lock Screen (VirtCore's
    /// TimerAlerts). Reminders are never touched.
    private func clearDeliveredTimerAlerts(everything: Bool) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { list in
            let ids = TimerAlerts.toRemove(delivered: list.map { (id: $0.request.identifier, at: $0.date) }, now: Date(),
                                           everything: everything)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// Asks iOS for alerts once, and only with Virt open on the screen (never from a lock-screen press or Siri in the
    /// background: a locked phone can't show the ask).
    private func askForAlerts() {
        guard !askedForAlerts, UIApplication.shared.applicationState == .active else { return }
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
            // the green light starts a moment early, so its go tone lands on the zero
            let soundAt = a.fireAt.addingTimeInterval(-SoundBoard.shared.style.lead(a.cue))
            if let had = scheduled[a.identifier], abs(had.timeIntervalSince(soundAt)) < 0.05 { continue }
            let content = UNMutableNotificationContent()
            content.title = a.title
            content.body = a.body
            content.sound = SoundBoard.shared.notificationSound(a.cue)
            content.interruptionLevel = .active
            // its own category and thread, apart from the reminders, and last in the list
            content.categoryIdentifier = TimerAlerts.category
            content.threadIdentifier = TimerAlerts.thread
            content.relevanceScore = 0
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(0.1, soundAt.timeIntervalSince(now)), repeats: false)
            center.add(UNNotificationRequest(identifier: a.identifier, content: content, trigger: trigger))
            scheduled[a.identifier] = soundAt
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
            // stale at the zero: the system draws it again then, and the view moves on to the step running now
            let content = ActivityContent(state: d, staleDate: d.endsAt)
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
        // the zero sound starts early by its own lead-in (the green light's three tones), so its main tone is the zero
        let lead = SoundBoard.shared.style.lead(cue)
        let soundAt = next.fireAt.addingTimeInterval(-lead)
        let key = "\(next.identifier)@\(next.fireAt.timeIntervalSince1970)"
        if soundAt > now {
            tickTimers.append(exactTimer(at: soundAt) { self.zeroSound(cue, key: key) })
        } else if soundStarted != key {
            zeroSound(cue, key: key)  // armed again inside the lead-in (a page message just then): late, never missed
        }
        for at in LeadIn.ticks(zero: next.fireAt, now: now, length: next.length, lead: lead) {
            tickTimers.append(exactTimer(at: at) { SoundBoard.shared.play(.leadIn) })
        }
    }

    private func exactTimer(at: Date, _ run: @escaping @MainActor () -> Void) -> Timer {
        let t = Timer(fire: at, interval: 0, repeats: false) { _ in Task { @MainActor in run() } }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    /// The zero's sound, while the app is open (the notification is held back then). Once per zero.
    private func zeroSound(_ cue: SoundCue, key: String) {
        guard soundStarted != key else { return }
        soundStarted = key
        if UIApplication.shared.applicationState == .active { SoundBoard.shared.play(cue) }
    }

    private func zero(_ cue: SoundCue) {
        if UIApplication.shared.applicationState == .active {
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
                    // between sets, the activity goes once the workout's gone quiet
                    if self.board.countdown == nil { self.updateActivity(now: Date()) }
                }
            }
        } else if !on {
            quietTimer?.invalidate()
            quietTimer = nil
        }
    }

    /// The intro's stages so far this launch, for the test build's status line (AppLock records them; never saved).
    var introSeen: [String] = []

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
        parts.append("next \(board.nextSet?.label ?? "none")")
        parts.append("today \(today?.title ?? "none")\(today?.done == true ? " done" : "")")
        parts.append("store \(SharedStore.note)")
        parts.append("reminders \(Reminders.shared.count) (ask \(askNote))")
        parts.append("taps \(lightTaps)")
        parts.append("sound \(SoundBoard.shared.last)")
        parts.append("sent \(sentCommands.isEmpty ? "none" : sentCommands.joined(separator: ","))")
        parts.append("intro \(introSeen.joined(separator: ">"))")
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
        completionHandler(TimerAlerts.isTimer(id) || id.hasPrefix(ReminderPlan.prefix) ? [] : [.banner, .sound])
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
