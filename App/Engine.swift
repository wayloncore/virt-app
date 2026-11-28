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
    /// Hands the page a command and says afterward whether the page took it (false: the web view couldn't run it,
    /// say its page process was ended while the phone was locked).
    func send(page command: PageCommand, done: @escaping @MainActor (Bool) -> Void)
    /// Shows Training's front page unless a workout is going (Navigation.todayAction).
    func goToToday(midWorkout: Bool)
    /// The first-time reminders ask.
    func askAboutReminders()
}

/// The native side of Training: it hears the page's messages, keeps the timer state (VirtCore's TimerBoard), and
/// turns it into the four things the web can't do well: the zero sound with the phone locked (the sound keeper), the Live
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
    private var chimeTimer: Timer?
    /// True while Virt isn't on the screen (from the moment it starts to leave: the lock, the Home Screen, Control
    /// Center), which is when the lock-screen sound keeper runs. The test build's `-uitest-keeper-away` keeps it true
    /// so the UI tests can watch the keeper with the app open.
    private var away = false
    private let keeperAwayForTest = ProcessInfo.processInfo.arguments.contains("-uitest-keeper-away")
    private var tickTimers: [Timer] = []
    /// The zero whose sound has started (its identifier and end), so arming again never plays it twice.
    private var soundStarted: String?
    private var quietTimer: Timer?
    private var askedAboutReminders = false
    /// Log set from the lock screen: one press is one set (VirtCore's LogPress).
    private var logPress = LogPress()
    /// Log set presses the page hasn't been handed yet (no page, or it was loading): kept on the phone and handed over
    /// when Training is up (VirtCore's PendingLogs).
    private var pendingLogs = PendingLogs()
    /// The page's own word on whether a workout is open (`live` on `today`), and when it said it. nil from a page that
    /// doesn't say.
    private var pageLive: Bool?
    private var pageLiveAt: Date?
    /// Which screen the page says it's on (`screen` on `today`), and when it said it; nil from a page that doesn't say
    /// (the screen then stays awake only while a countdown runs). Forgotten when a new page loads.
    private var pageScreen: WorkoutScreen?
    private var pageScreenAt: Date?
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
        // a launch in the background (a lock-screen press, a Siri rest) is away; a normal launch comes to the screen
        away = UIApplication.shared.applicationState == .background
        BackgroundSound.shared.onChange = { [weak self] in self?.refresh() }
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
        pendingLogs = PendingLogs.decode(UserDefaults.standard.data(forKey: PendingLogs.key)) ?? PendingLogs()
        today = SharedStore.loadToday()
        Reminders.shared.registerCategory()
        refreshReminders()
        // an activity left from before the app was closed: keep one to update, end any extra
        let left = Activity<VirtTimerAttributes>.activities
        activity = left.first
        for extra in left.dropFirst() { Task { await extra.end(nil, dismissalPolicy: .immediate) } }
        // the workout timer never schedules a notification (Tyler, Nov 27: "I don't want all those notifications"):
        // any left waiting from an earlier build go
        UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
            let ids = TimerAlerts.pendingToRemove(reqs.map(\.identifier))
            if !ids.isEmpty { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids) }
        }
        refresh()
    }

    // MARK: - In

    func receive(_ message: BridgeMessage) {
        // the workout timer needs no notification permission (the sound keeper plays the zeros): only turning on the
        // reminders asks iOS (Reminders.swift)
        switch message {
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
        #if DEBUG
        LockedRead.recheck()
        #endif
        if changed { WidgetCenter.shared.reloadAllTimelines() }
        pageScreen = t.workoutScreen
        pageScreenAt = t.receivedAt
        applyAwake(now: Date())
        armQuietCheck()
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
        pendingLogs = PendingLogs()
        keepPendingLogs()
        pageLive = nil
        pageLiveAt = nil
        pageScreen = nil
        pageScreenAt = nil
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
        // reminders on or off, from anywhere (the sheet, the page, the first-time ask): the page hears it
        PrefsHub.shared.update()
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
        board.startNativeRest(seconds: seconds, now: now)
        refresh()
        flush(queue.add(.rest(endsAt: now.addingTimeInterval(TimeInterval(seconds))), now: now))
    }

    /// A new page is loading in the web view: commands wait.
    func pageLoading() {
        queue.pageLoading()
        // the new page says its screen again on load; until then, the plain rule
        pageScreen = nil
        pageScreenAt = nil
        applyAwake(now: Date())
    }

    /// Training is up and listening: send what's waiting, and the Log set presses it hasn't heard yet.
    func pageReady() {
        let now = Date()
        flush(queue.pageReady(now: now))
        let held = pendingLogs.take(now: now)
        keepPendingLogs()
        for c in held { deliver(c) }
    }

    /// A Log set press for the page: handed over now when Training is up, otherwise held (on the phone) until it is.
    /// If the web view couldn't run it, it's held again; the page drops a press whose id it has already logged.
    private func deliver(_ cmd: PageCommand) {
        guard let page, queue.ready else { return hold(cmd) }
        if case .log = cmd { sentCommands.append("log") }
        page.send(page: cmd) { [weak self] took in
            if !took { self?.hold(cmd) }
        }
    }

    private func hold(_ cmd: PageCommand) {
        pendingLogs.hold(cmd)
        keepPendingLogs()
        onChange?()
    }

    private func keepPendingLogs() {
        UserDefaults.standard.set(pendingLogs.isEmpty ? nil : pendingLogs.encoded(), forKey: PendingLogs.key)
    }

    /// For the test build: the page counts as not ready (asleep, or iOS started Virt for a press with no screen), so
    /// the next presses are held; `pageReady()` hands them over.
    func pageAsleepForTest() { queue.pageLoading() }

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

    /// Sounds turned off or on: the sound keeper stops or starts.
    func soundsChanged() { refresh() }

    /// The sound style changed: the keeper's zeros get the new sound.
    func soundStyleChanged() { refresh() }

    /// A lock-screen or Dynamic Island button, Control Center's Log set, or the test build's buttons. They run in
    /// Virt's process with the phone locked, so nothing here asks iOS for anything or needs the phone unlocked.
    func command(_ c: TimerCommand) {
        let now = Date()
        if c == .log {
            // one press, one set: a burst counts once, and nothing goes with no set left to log (#573). It goes with the
            // moment it was pressed and its own id, so the page's rest lines up and a repeat is dropped.
            let cmd = logPress.press(board: &board, now: now, id: UUID().uuidString)
            refresh()
            if let cmd { deliver(cmd) }
            return
        }
        board.apply(c, now: now)
        refresh()
        page?.send(c)
    }

    /// The phone was unlocked: a `today` that couldn't be read at a locked launch is read now.
    func protectedDataAvailable() {
        if today == nil, let t = SharedStore.loadToday() {
            today = t
            refreshReminders()
        }
    }

    /// Virt is leaving the screen (the lock, the Home Screen, Control Center): the sound keeper takes over the zeros
    /// while a workout is going. It starts here, while Virt is still in front, so iOS lets the audio start.
    func willResignActive() {
        away = true
        refresh()
    }

    func didEnterBackground() {
        away = true
        refresh()
    }

    func becameActive() {
        away = false
        refresh()
        refreshReminders()
        // Virt's open: no workout-timer alert stays on the Lock Screen or in Notification Center
        clearDeliveredTimerAlerts(everything: true)
        // iOS's notification setting may have changed in Settings: the page hears the prefs again
        PrefsHub.shared.cameForward()
    }

    // MARK: - The screen kept awake (only in the workout)

    /// VirtCore's rule: on the workout screen when the page says which screen it's on; otherwise only while a
    /// countdown runs.
    func keepAwake(now: Date) -> Bool {
        board.keepAwake(now: now, screen: pageScreen, screenSaidAt: pageScreenAt)
    }

    private func applyAwake(now: Date) {
        UIApplication.shared.isIdleTimerDisabled = keepAwake(now: now)
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
        updateKeeper(now: now)
        updateActivity(now: now)
        applyAwake(now: now)
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

    /// The zero sound with the phone locked (Tyler, Nov 27): the sound keeper (App/BackgroundSound.swift) is on while a
    /// workout is going, Virt is away and Sounds is on (VirtCore's SoundKeeper.shouldRun), with every zero ahead
    /// scheduled. There's no notification for a timer zero, in any case (Tyler, Nov 27: "I don't want all those
    /// notifications"): if the keeper can't play (a call took the audio), that zero is silent and the keeper comes back
    /// after. The Live Activity still shows the timer.
    private func updateKeeper(now: Date) {
        let run = SoundKeeper.shouldRun(soundsOn: SoundBoard.shared.enabled, away: away || keeperAwayForTest, board: board,
                                        live: liveWorkout(now: now), now: now)
        // Sounds off: no zeros at all (a count-in already sounding stops)
        let cues = SoundBoard.shared.enabled ? SoundKeeper.cues(board: board, style: SoundBoard.shared.style, now: now) : []
        BackgroundSound.shared.update(run: run, cues: cues, now: now)
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

    /// While the app is open: the zero's sound with its three-second count-in (Nov 27; VirtCore's `LeadIn`: the beats
    /// at -3, -2 and -1 s, or the ones that still fit, then the zero sound on the zero), and a strong buzz at the exact
    /// zero (away from the screen, the sound keeper plays the same sound instead).
    private func armChime(now: Date) {
        chimeTimer?.invalidate()
        chimeTimer = nil
        tickTimers.forEach { $0.invalidate() }
        tickTimers = []
        let ahead = board.alerts(now: now).min(by: { $0.fireAt < $1.fireAt })
        let aheadKey = ahead.map { SoundKeeper.key(identifier: $0.identifier, fireAt: $0.fireAt) }
        // a count-in for a zero that was paused, moved or skipped stops (with Sounds off, every one)
        SoundBoard.shared.stopCountIn(keeping: SoundBoard.shared.enabled ? aheadKey : nil, now: now)
        guard let next = ahead, let key = aheadKey else { return }
        let cue = next.cue
        chimeTimer = exactTimer(at: next.fireAt) { self.zero(cue) }
        guard soundStarted != key else { return }
        // the sound starts on the first beat that fits, so the zero sound lands on the zero
        let beats = LeadIn.beats(zero: next.fireAt, now: now, length: next.length)
        let soundAt = next.fireAt.addingTimeInterval(-TimeInterval(beats))
        let zeroAt = next.fireAt
        // a little ahead, so the player is set to start on the beat itself (play(atTime:)), not on the timer's tick
        let armAt = soundAt.addingTimeInterval(-0.15)
        if armAt > now {
            let length = next.length
            tickTimers.append(exactTimer(at: armAt) {
                let n = LeadIn.beats(zero: zeroAt, now: Date(), length: length)
                self.zeroSound(cue, key: key, beats: n, zeroAt: zeroAt)
            })
        } else {
            zeroSound(cue, key: key, beats: beats, zeroAt: zeroAt)
        }
    }

    private func exactTimer(at: Date, _ run: @escaping @MainActor () -> Void) -> Timer {
        let t = Timer(fire: at, interval: 0, repeats: false) { _ in Task { @MainActor in run() } }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    /// The zero's sound with its count-in, while the app is open. Once per zero, and never one the sound keeper has
    /// played.
    private func zeroSound(_ cue: SoundCue, key: String, beats: Int, zeroAt: Date) {
        guard soundStarted != key else { return }
        soundStarted = key
        // the lock-screen sound keeper has it (scheduled or already sounding): never twice
        if BackgroundSound.shared.covers(key) { return }
        if UIApplication.shared.applicationState == .active, SoundBoard.shared.playZero(cue, beats: beats, key: key, zeroAt: zeroAt) {
            // the app's count-in has started: if Virt leaves the screen during it, it plays on, and the keeper doesn't
            // start a second one
            BackgroundSound.shared.appStarted(key)
        }
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
        let on = board.workout != nil || pageScreen == .workout
        if on && quietTimer == nil {
            quietTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                Task { @MainActor in
                    self.applyAwake(now: Date())
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
        parts.append(keepAwake(now: now) ? "awake on" : "awake off")
        if let s = pageScreen { parts.append("screen \(s.rawValue)") }
        parts.append("activity \(activityNote)")
        parts.append(board.workout.map { "workout \($0.title)" } ?? "no workout")
        parts.append("next \(board.nextSet?.label ?? "none")")
        parts.append("today \(today?.title ?? "none")\(today?.done == true ? " done" : "")")
        parts.append("store \(SharedStore.note)")
        parts.append("reminders \(Reminders.shared.count) (ask \(askNote))")
        parts.append("taps \(lightTaps)")
        parts.append("sound \(SoundBoard.shared.last)")
        let keeper = BackgroundSound.shared
        parts.append("sound keeper \(keeper.state.rawValue)")
        parts.append("cue \(keeper.nextCueAt.map { String(Int($0.timeIntervalSince1970.rounded())) } ?? "none")")
        parts.append("keeper-seen \(keeper.history.isEmpty ? "none" : keeper.history.joined(separator: ">"))")
        parts.append("held \(pendingLogs.count)")
        #if DEBUG
        parts.append("locked-read \(LockedRead.summary)")
        parts.append("intents \(IntentAudit.summary)")
        #endif
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
