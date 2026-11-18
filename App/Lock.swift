import LocalAuthentication
import SwiftUI
import UIKit
import VirtCore

/// The Face ID lock. Training is Tyler's health data and the studio's sign-in lasts a month, so Virt keeps it behind
/// Face ID (the iPhone's passcode is the fallback):
///
/// - a fresh launch shows the lock screen before Training shows anything;
/// - coming back after 15 minutes or more away locks it again, but never in the middle of a workout
///   (VirtCore's `LockPolicy` and `TimerBoard.midWorkout`);
/// - while the app isn't active (the app switcher, Control Center, the Face ID sheet), a plain cover hides Training,
///   so the app switcher's picture never shows it.
///
/// The lock is its own window above the app's, so the web view keeps loading underneath and unlocking is instant.
/// The lock-screen and Dynamic Island buttons and the alerts at zero don't go through here, so they keep working while
/// it's locked. There's no setting to turn it off, and no way around it.
@MainActor final class AppLock: ObservableObject {
    enum Mode { case open, cover, locked }

    @Published private(set) var mode: Mode = .locked
    /// Why the last try didn't unlock, shown under the button.
    @Published private(set) var note: String?
    @Published private(set) var checking = false
    /// The intro (Intro.swift) plays over the lock screen's V on a fresh launch only.
    @Published private(set) var introPlaying = true
    private(set) var introStart = Date()
    /// The test build's still frames of the intro (VIRT_INTRO_AT, seconds in).
    private(set) var introFrozenAt: TimeInterval?

    private var policy: LockPolicy
    private var active = false
    /// Ask for Face ID by itself the next time the app is active (a fresh launch, or coming back to a locked app).
    private var askWhenActive = true
    private var window: UIWindow?
    private weak var appWindow: UIWindow?
    private let origin = ContinuousClock.now

    /// How the test build answers instead of Face ID (Debug only; a Release build always asks Face ID).
    private enum Answer { case faceID, yes, no }
    private let answer: Answer

    init() {
        var limit = LockPolicy.standardAwayLimit
        var answer = Answer.faceID
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-uitest-skip-faceid") { answer = .yes }
        if args.contains("-uitest-faceid-fails") { answer = .no }
        if let s = ProcessInfo.processInfo.environment["VIRT_LOCK_AFTER"], let n = TimeInterval(s) { limit = n }
        if let s = ProcessInfo.processInfo.environment["VIRT_INTRO_AT"], let n = TimeInterval(s) { introFrozenAt = n }
        #endif
        self.answer = answer
        policy = LockPolicy(awayLimit: limit)
        if introFrozenAt == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + IntroView.length + 0.05) { [weak self] in self?.endIntro() }
        }
    }

    /// The intro is over (or a tap skipped it): the lock screen's own V takes over in the same spot.
    func endIntro() {
        guard introPlaying, introFrozenAt == nil else { return }
        introPlaying = false
    }

    /// Seconds on a clock that keeps running while the phone sleeps and can't be set in Settings.
    private var clock: TimeInterval {
        let d = ContinuousClock.now - origin
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    // MARK: - The window

    /// Puts the lock window over the app's window. Called as the scene connects, so the very first frame is locked.
    func attach(to scene: UIWindowScene, over app: UIWindow) {
        appWindow = app
        let host = LockHost(rootView: LockView(lock: self))
        host.view.backgroundColor = .virtBlack
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.rootViewController = host
        w.backgroundColor = .virtBlack
        w.accessibilityViewIsModal = true
        window = w
        update()
    }

    private func update() {
        mode = policy.locked ? .locked : (active ? .open : .cover)
        guard let w = window else { return }
        let hidden = mode == .open
        // VoiceOver (and the UI tests) can't read Training behind the lock
        appWindow?.accessibilityElementsHidden = !hidden
        if hidden {
            if !w.isHidden {
                w.isHidden = true
                appWindow?.makeKey()
            }
            return
        }
        if mode == .locked { appWindow?.endEditing(true) }  // no keyboard left up over the lock
        if w.isHidden || !w.isKeyWindow {
            if active { w.makeKeyAndVisible() } else { w.isHidden = false }
        }
        w.rootViewController?.setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: - The scene's comings and goings (SceneDelegate)

    func willResignActive() {
        active = false
        update()
    }

    func didEnterBackground() {
        active = false
        appWindow?.endEditing(true)  // the keyboard's suggestions stay out of the app switcher's picture
        policy.wentAway(at: clock)
        update()
    }

    func willEnterForeground() {
        let wasLocked = policy.locked
        policy.cameBack(at: clock, midWorkout: Engine.shared.board.midWorkout(now: Date()))
        if policy.locked {
            askWhenActive = true
            if !wasLocked { note = nil }
        }
        update()
    }

    func didBecomeActive() {
        active = true
        update()
        // the Face ID sheet itself makes the app inactive and active again; askWhenActive keeps that from looping
        if policy.locked, askWhenActive, answer == .faceID {
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
        } else {
            switch (error as? LAError)?.code {
            case .authenticationFailed?: note = "That didn't match. Try again."
            case .passcodeNotSet?: note = "Set a passcode for this iPhone in Settings to open Virt."
            default: note = "Still locked. Tap Unlock to try again."
            }
        }
        update()
    }
}

/// The lock window's controller: light status bar text on black.
final class LockHost: UIHostingController<LockView> {
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

/// The gold V on black. Locked: one Unlock button, and why the last try didn't work. As a cover (the app switcher):
/// the V alone.
struct LockView: View {
    @ObservedObject var lock: AppLock

    var body: some View {
        let locked = lock.mode == .locked
        ZStack {
            Color.virtBlack.ignoresSafeArea()
            if lock.introPlaying {
                IntroView(frozenAt: lock.introFrozenAt, reduceMotion: UIAccessibility.isReduceMotionEnabled, start: lock.introStart)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { lock.endIntro() } }
                    .ignoresSafeArea()
            } else {
                // centered on the whole screen, exactly where the launch screen puts it
                Image("VirtMark").resizable().scaledToFit().frame(width: IntroView.markSize, height: IntroView.markSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            if locked {
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
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(locked ? "lock-screen" : "privacy-cover")
    }
}
