import LocalAuthentication
import SwiftUI
import UIKit
import VirtCore

/// The Face ID lock. Training is Tyler's health data and the studio's sign-in lasts a month, so Virt keeps it behind
/// Face ID (the iPhone's passcode is the fallback):
///
/// - a fresh launch shows the lock screen before Training shows anything, unless a workout is live (or Lock after is
///   Never): then Training opens straight away, no launch clip and no Face ID (`LockPolicy.lockedAtLaunch`);
/// - coming back after the "Lock after" time away (15 minutes unless he changes it in Virt's settings) locks it
///   again, but never while a workout is live (VirtCore's `LockPolicy`, `LockAfter` and `LiveWorkout`);
/// - while the app is in the background (the app switcher), a plain cover hides Training, so the app switcher's
///   picture never shows it. A banner, Control Center, Notification Center or the Face ID sheet only make the app
///   inactive: no cover then, and the cover lifts as soon as the app comes forward.
/// - The lock belongs to the app, not the scene: a scene iOS builds again (after discarding it to save memory) picks
///   up where the last one was, locked or not.
///
/// The lock is its own window above the app's, so the web view keeps loading underneath and Training is ready when
/// the unlock clip reaches black (the video intro: Intro.swift and VirtCore's `IntroFlow`).
/// The lock-screen and Dynamic Island buttons and the alerts at zero don't go through here, so they keep working while
/// it's locked. "Lock after: Never" in Virt's settings turns it off; nothing else gets around it.
@MainActor final class AppLock: ObservableObject {
    /// `unlocking`: Face ID said yes and the unlock clip is playing; Training fades in when it reaches black.
    enum Mode { case open, cover, locked, unlocking }

    @Published private(set) var mode: Mode = .locked
    /// Why the last try didn't unlock, shown under the button.
    @Published private(set) var note: String?
    @Published private(set) var checking = false
    /// The video intro's order of events (VirtCore's IntroFlow; Intro.swift plays it).
    @Published private(set) var flow: IntroFlow {
        didSet { if flow.stage != oldValue.stage { noteStage() } }
    }
    let playback = IntroPlayback()

    /// The app's lock, shared by every scene (a scene iOS builds again starts where the last one left off).
    private static var shared: LockPolicy?
    private var policy: LockPolicy {
        get { Self.shared ?? LockPolicy() }
        set { Self.shared = newValue }
    }
    private var active = false
    /// In the background (the app switcher): the cover is up. Merely inactive (a banner, Control Center, the Face ID
    /// sheet) isn't.
    private var inBackground = false
    /// Ask for Face ID by itself the next time the app is active (a fresh launch, or coming back to a locked app).
    private var askWhenActive = true
    private var window: UIWindow?
    private weak var appWindow: UIWindow?
    private static let origin = ContinuousClock.now
    /// The test build's VIRT_LOCK_AFTER (seconds), which wins over the setting.
    private static var testLimit: TimeInterval?
    /// The test build's still frames (VIRT_INTRO_AT, VIRT_UNLOCK_AT: seconds into the launch or unlock clip).
    private var frozenLaunchAt: TimeInterval?
    private var frozenUnlockAt: TimeInterval?
    /// The test build's launch clip speed (VIRT_INTRO_RATE), so a test can tap during it on a slow simulator.
    private var launchRate: Float = 1

    /// How the test build answers instead of Face ID (Debug only; a Release build always asks Face ID).
    private enum Answer { case faceID, yes, no }
    private let answer: Answer
    /// The test build: answer yes by itself as the app opens, the way Face ID does (`-uitest-auto-unlock`).
    private var askBySelf = false

    init() {
        var limit = LockAfter(stored: UserDefaults.standard.string(forKey: LockAfter.key)).limit
        var answer = Answer.faceID
        var reduceMotion = UIAccessibility.isReduceMotionEnabled
        var introOff = false
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        if args.contains("-uitest-skip-faceid") { answer = .yes }
        if args.contains("-uitest-faceid-fails") { answer = .no }
        if args.contains("-uitest-reduce-motion") { reduceMotion = true }
        if args.contains("-uitest-auto-unlock") { answer = .yes; askBySelf = true }
        if let s = env["VIRT_LOCK_AFTER"], let n = TimeInterval(s) { limit = n; Self.testLimit = n }
        if let s = env["VIRT_INTRO_AT"], let n = TimeInterval(s) { frozenLaunchAt = n }
        if let s = env["VIRT_UNLOCK_AT"], let n = TimeInterval(s) { frozenUnlockAt = n }
        if let s = env["VIRT_INTRO_RATE"], let n = Float(s), n > 0 { launchRate = n }
        // the lock screen as it is after time away: the still, no launch clip
        if env["VIRT_INTRO"] == "off" { introOff = true }
        #endif
        self.answer = answer
        // the first scene of a launch: locked, unless a workout is live (Virt remembers it across a launch) or Lock
        // after is Never. A scene built again: the app's lock as it is.
        let fresh = Self.shared == nil
        if fresh {
            let live = Engine.shared.liveAtLaunch(now: Date())
            let lockAfter = LockAfter(stored: UserDefaults.standard.string(forKey: LockAfter.key))
            var locked = LockPolicy.lockedAtLaunch(lockAfter: lockAfter, liveWorkout: live)
            #if DEBUG
            if frozenLaunchAt != nil || frozenUnlockAt != nil { locked = true }  // the intro's still frames
            #endif
            Self.shared = LockPolicy(awayLimit: limit, locked: locked)
        } else {
            Self.shared?.awayLimit = limit
        }
        let opensStraightIn = !Self.shared!.locked
        flow = opensStraightIn ? IntroFlow.open(reduceMotion: reduceMotion) : IntroFlow(reduceMotion: reduceMotion)
        if !fresh && !opensStraightIn { flow.relocked() }  // a scene built again while locked: the V, no launch clip
        if !opensStraightIn && (introOff || frozenUnlockAt != nil) { flow.relocked() }
        playback.onLaunchEnded = { [weak self] in self?.launchEnded() }
        playback.onUnlockEnded = { [weak self] in self?.unlockEnded() }
        if let t = frozenUnlockAt {
            flow.unlocked()  // the unlock clip's picture only; still locked underneath
            playback.playUnlock(frozenAt: t)
        } else if flow.stage == .launch {
            playback.playLaunch(frozenAt: frozenLaunchAt, rate: launchRate)
        } else if flow.stage == .done {
            playback.showStill()  // straight into Training; the V is only the app switcher's cover
        } else {
            playback.showStill(animated: flow.reduceMotion && !introOff)
        }
        noteStage()
    }

    /// The test build's status line lists the intro's stages ("launch>unlock>done"), so a test can check the order.
    private func noteStage() {
        Engine.shared.introSeen.append(flow.stage.rawValue)
        Engine.shared.onChange?()
    }

    private var frozen: Bool { frozenLaunchAt != nil || frozenUnlockAt != nil }

    // MARK: - The intro (Intro.swift)

    /// A tap during the launch clip: straight to its last frame, the lock screen.
    func skipIntro() {
        guard flow.stage == .launch, !flow.hurrying, !frozen else { return }
        playback.skipLaunch()
        flow.skip()
        playback.holdLaunchEnd()
    }

    private func launchEnded() {
        guard flow.stage == .launch, !frozen else { return }
        flow.launchEnded()
        if flow.stage == .unlock {
            playback.playUnlock()
        } else {
            playback.holdLaunchEnd()
        }
        update()
    }

    private func unlockEnded() {
        guard flow.stage == .unlock, !frozen else { return }
        flow.unlockEnded()
        update()
    }

    /// Seconds on a clock that keeps running while the phone sleeps and can't be set in Settings.
    private var clock: TimeInterval {
        let d = ContinuousClock.now - Self.origin
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    // MARK: - The window

    /// Puts the lock window over the app's window. Called as the scene connects, so the very first frame is locked.
    func attach(to scene: UIWindowScene, over app: UIWindow) {
        appWindow = app
        let host = LockHost(rootView: LockView(lock: self))
        host.view.backgroundColor = .lockBlack
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.rootViewController = host
        w.backgroundColor = .lockBlack
        w.accessibilityViewIsModal = true
        window = w
        update()
    }

    private func update() {
        let was = mode
        if policy.locked {
            mode = .locked
        } else if flow.playingOut {
            mode = .unlocking
        } else {
            mode = inBackground ? .cover : .open
        }
        guard let w = window else { return }
        let hidden = mode == .open
        // VoiceOver (and the UI tests) can't read Training behind the lock
        appWindow?.accessibilityElementsHidden = !hidden
        if hidden {
            if !w.isHidden {
                appWindow?.makeKey()
                if was == .unlocking || was == .locked {
                    // unlocked: the clip has reached black (or, with Reduce Motion, there was none); fade into Training
                    UIView.animate(withDuration: IntroPlayback.fadeToTraining, delay: 0, options: [.curveEaseOut]) {
                        w.alpha = 0
                    } completion: { _ in
                        w.alpha = 1
                        if self.mode == .open {
                            w.isHidden = true
                            self.playback.showStill()  // the app switcher's cover is the V, not the clip's black
                        }
                    }
                } else {
                    w.isHidden = true
                }
            }
            return
        }
        w.layer.removeAllAnimations()
        w.alpha = 1
        if mode == .locked { appWindow?.endEditing(true) }  // no keyboard left up over the lock
        if w.isHidden || !w.isKeyWindow {
            if active { w.makeKeyAndVisible() } else { w.isHidden = false }
        }
        w.rootViewController?.setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: - The scene's comings and goings (SceneDelegate)

    /// A banner, Control Center, Notification Center, the Face ID sheet or a call: inactive only. No cover (Tyler,
    /// Nov 24: the V flashed every time he came back).
    func willResignActive() {
        active = false
        update()
    }

    func didEnterBackground() {
        active = false
        inBackground = true
        appWindow?.endEditing(true)  // the keyboard's suggestions stay out of the app switcher's picture
        policy.wentAway(at: clock)
        // a clip never resumes partway: back on the lock screen's V, or in Training if Face ID already said yes
        if !frozen, flow.stage == .launch || flow.stage == .unlock {
            flow.interrupted(locked: policy.locked)
            playback.showStill()
        }
        update()
    }

    func willEnterForeground() {
        inBackground = false  // the cover lifts now, before the app is even active, unless it's locked
        let wasLocked = policy.locked
        policy.cameBack(at: clock, midWorkout: Engine.shared.liveWorkout(now: Date()))
        if policy.locked {
            askWhenActive = true
            if !wasLocked {
                note = nil
                // locked again after time away: the V lock screen, no launch clip
                flow.relocked()
                playback.showStill()
            }
        }
        update()
    }

    func didBecomeActive() {
        active = true
        inBackground = false
        update()
        // the Face ID sheet itself makes the app inactive and active again; askWhenActive keeps that from looping
        if policy.locked, askWhenActive, answer == .faceID || askBySelf {
            askWhenActive = false
            unlock()
        }
    }

    // MARK: - Unlocking

    func unlock() {
        guard policy.locked, !checking else { return }
        askWhenActive = false
        switch answer {
        case .yes: return finish(true, nil)
        case .no: return finish(false, LAError(.userCancel))
        case .faceID: break
        }
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            note = problem?.code == LAError.Code.passcodeNotSet.rawValue
                ? "Set a passcode for this iPhone in Settings to open Virt."
                : "Face ID isn't available right now. Try again."
            skipIntro()  // the lock screen, so the note and Unlock show
            return
        }
        checking = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Virt to see your training.") { ok, error in
            Task { @MainActor in self.finish(ok, error) }
        }
    }

    private func finish(_ ok: Bool, _ error: Error?) {
        checking = false
        if ok {
            policy.unlocked()
            note = nil
            flow.unlocked()
            switch flow.stage {
            case .launch: playback.hurryLaunch()   // the V lands quickly, then the unlock clip
            case .unlock: playback.playUnlock()
            case .lock, .done: break               // .done: Reduce Motion, straight to the fade
            }
        } else {
            switch (error as? LAError)?.code {
            case .authenticationFailed?: note = "That didn't match. Try again."
            case .passcodeNotSet?: note = "Set a passcode for this iPhone in Settings to open Virt."
            default: note = "Still locked. Tap Unlock to try again."
            }
            skipIntro()  // the lock screen, so the note and Unlock show
        }
        update()
    }
}

extension AppLock {
    /// Virt's settings changed "Lock after": the next time away is measured against it (the test build's
    /// VIRT_LOCK_AFTER still wins).
    static func setLockAfter(_ l: LockAfter) {
        UserDefaults.standard.set(l.rawValue, forKey: LockAfter.key)
        guard testLimit == nil else { return }
        shared?.awayLimit = l.limit
    }
}

/// The lock window's controller: light status bar text on black.
final class LockHost: UIHostingController<LockView> {
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

/// The intro and the lock screen, on pure black. The launch clip (a tap skips it), then the large V with one Unlock
/// button and why the last try didn't work; the unlock clip; as a cover (the app switcher), the V alone.
struct LockView: View {
    @ObservedObject var lock: AppLock

    var body: some View {
        let locked = lock.mode == .locked
        let showsButton = locked && lock.flow.showsUnlockButton
        ZStack {
            Color.lockBlack.ignoresSafeArea()
            IntroStage(playback: lock.playback)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            if lock.flow.stage == .launch && !lock.flow.hurrying {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { lock.skipIntro() }
                    .accessibilityElement()
                    .accessibilityLabel("Skip intro")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("skip-intro")
            }
            if showsButton {
                VStack(spacing: 14) {
                    Spacer()
                    Button(action: lock.unlock) {
                        Label("Unlock", systemImage: "faceid")
                            .font(.headline)
                            .frame(maxWidth: 240)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(.virtGold)
                    .foregroundStyle(Color.virtBlack)
                    .disabled(lock.checking)
                    .accessibilityLabel("Unlock")
                    .accessibilityIdentifier("unlock")
                    Text(lock.note ?? " ")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 36, alignment: .top)
                        .accessibilityIdentifier("lock-note")
                        .accessibilityHidden(lock.note == nil)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
                .transition(.opacity)
            }
            #if DEBUG
            if Self.testBuild {
                // the test build's reading of where the intro is (the UI tests check it)
                Text("intro \(lock.flow.stage.rawValue)")
                    .font(.system(size: 2))
                    .foregroundStyle(.clear)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("intro-stage")
            }
            #endif
        }
        .animation(.easeOut(duration: 0.25), value: showsButton)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(locked ? "lock-screen" : (lock.mode == .unlocking ? "unlocking" : "privacy-cover"))
    }

    #if DEBUG
    static let testBuild = ProcessInfo.processInfo.arguments.contains("-uitest")
    #endif
}
