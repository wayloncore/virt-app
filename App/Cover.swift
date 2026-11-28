import SwiftUI
import UIKit
import VirtCore

/// The intro and the app switcher's cover, in one window above Training's. Virt has no lock of its own (Tyler, Nov 28:
/// "Do we even need an app lock? ... Remove that"; "the phone might need the Face ID to log in with Apple, but not to
/// log into the app ever"): it never asks for Face ID or the passcode to open, on any phone. Sign in with Apple's own
/// sheet is Apple's and isn't touched here.
///
/// - A fresh launch plays the launch clip, then straight on the unlock clip into black, and Training fades in
///   (VirtCore's `IntroFlow`; Intro.swift plays the clips). Training loads underneath meanwhile. A tap skips the launch
///   clip. A signed-out phone gets the same intro before its first screen, as before.
/// - No clip, straight into Training: while a workout is live (Virt remembers it across a launch, `LiveWorkout`), with
///   Reduce Motion, and for a scene iOS builds again after discarding one (the intro is the app's, once a launch).
/// - While Virt is in the background, the cover (the V on black) hides Training, so the app switcher's picture never
///   shows it. A banner, Control Center or Notification Center only make Virt inactive: no cover then. The cover lifts
///   as Virt comes forward, with nothing to answer.
///
/// The lock-screen and Dynamic Island buttons and the zero sounds don't go through here.
@MainActor final class AppCover: ObservableObject {
    /// `intro`: a clip is playing. `cover`: in the background, the V hides Training. `open`: Training shows.
    enum Mode { case intro, cover, open }

    @Published private(set) var mode: Mode = .intro
    /// The video intro's order of events (VirtCore's IntroFlow; Intro.swift plays it).
    @Published private(set) var flow: IntroFlow {
        didSet { if flow.stage != oldValue.stage { noteStage() } }
    }
    let playback = IntroPlayback()

    /// The intro is the app's, once a launch: a scene iOS builds again goes straight to Training.
    private static var introDone = false
    private var active = false
    /// In the background (the app switcher): the cover is up. Merely inactive (a banner, Control Center) isn't.
    private var inBackground = false
    private var window: UIWindow?
    private weak var appWindow: UIWindow?
    /// The test build's still frames (VIRT_INTRO_AT, VIRT_UNLOCK_AT: seconds into the launch or unlock clip).
    private let frozenLaunchAt: TimeInterval?
    private let frozenUnlockAt: TimeInterval?

    init() {
        var reduceMotion = UIAccessibility.isReduceMotionEnabled
        var launchAt: TimeInterval?
        var unlockAt: TimeInterval?
        var rate: Float = 1
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        if args.contains("-uitest-reduce-motion") { reduceMotion = true }
        if let s = env["VIRT_INTRO_AT"], let n = TimeInterval(s) { launchAt = n }
        if let s = env["VIRT_UNLOCK_AT"], let n = TimeInterval(s) { unlockAt = n }
        // the launch clip's speed, so a test can tap during it on a slow simulator
        if let s = env["VIRT_INTRO_RATE"], let n = Float(s), n > 0 { rate = n }
        #endif
        frozenLaunchAt = launchAt
        frozenUnlockAt = unlockAt
        let rebuilt = Self.introDone
        Self.introDone = true
        if launchAt != nil || unlockAt != nil {
            flow = IntroFlow()  // the test build's still frames: the clips, held
        } else {
            flow = IntroFlow.atLaunch(liveWorkout: Engine.shared.liveAtLaunch(now: Date()), reduceMotion: reduceMotion,
                                      sceneRebuilt: rebuilt)
        }
        playback.onLaunchEnded = { [weak self] in self?.launchEnded() }
        playback.onUnlockEnded = { [weak self] in self?.unlockEnded() }
        if let t = unlockAt {
            flow.skip()  // the unlock clip's picture only
            playback.playUnlock(frozenAt: t)
        } else if flow.stage == .launch {
            playback.playLaunch(frozenAt: launchAt, rate: rate)
        } else {
            playback.showStill()  // straight into Training; the V is only the app switcher's cover
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

    /// A tap during the launch clip: straight to its last frame, and the unlock clip from there.
    func skipIntro() {
        guard flow.stage == .launch, !frozen else { return }
        playback.skipLaunch()
        launchEnded()
    }

    /// The launch clip reached its last frame (the V): the unlock clip flies into it.
    private func launchEnded() {
        guard flow.stage == .launch, !frozen else { return }
        flow.launchEnded()
        playback.playUnlock()
        update()
    }

    /// The unlock clip reached black: Training fades in.
    private func unlockEnded() {
        guard flow.stage == .unlock, !frozen else { return }
        flow.unlockEnded()
        update()
    }

    // MARK: - The window

    /// Puts the intro's window over the app's. Called as the scene connects, so the very first frame is the intro's.
    func attach(to scene: UIWindowScene, over app: UIWindow) {
        appWindow = app
        let host = CoverHost(rootView: CoverView(cover: self))
        host.view.backgroundColor = .introBlack
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.rootViewController = host
        w.backgroundColor = .introBlack
        w.accessibilityViewIsModal = true
        window = w
        update()
    }

    private func update() {
        let was = mode
        if inBackground {
            mode = .cover
        } else if flow.playing {
            mode = .intro
        } else {
            mode = .open
        }
        guard let w = window else { return }
        let hidden = mode == .open
        // VoiceOver (and the UI tests) can't read Training behind the intro or the cover
        appWindow?.accessibilityElementsHidden = !hidden
        if hidden {
            if !w.isHidden {
                appWindow?.makeKey()
                if was == .intro {
                    // the unlock clip has reached black: fade into Training
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
        if w.isHidden || !w.isKeyWindow {
            if active { w.makeKeyAndVisible() } else { w.isHidden = false }
        }
        w.rootViewController?.setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: - The scene's comings and goings (SceneDelegate)

    /// A banner, Control Center, Notification Center or a call: inactive only. No cover (Tyler, Nov 24: the V flashed
    /// every time he came back).
    func willResignActive() {
        active = false
        update()
    }

    func didEnterBackground() {
        active = false
        inBackground = true
        appWindow?.endEditing(true)  // the keyboard's suggestions stay out of the app switcher's picture
        // a clip never resumes partway: Training is there on return
        if !frozen, flow.playing {
            flow.interrupted()
            playback.showStill()
        }
        update()
    }

    /// Coming back: the cover lifts now, before the app is even active. Nothing to answer.
    func willEnterForeground() {
        inBackground = false
        update()
    }

    func didBecomeActive() {
        active = true
        inBackground = false
        update()
    }
}

/// The intro's window controller: light status bar text on black.
final class CoverHost: UIHostingController<CoverView> {
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

/// The intro and the cover, on pure black: the launch clip (a tap skips it), the unlock clip, and as the app switcher's
/// cover, the V alone. Nothing to answer and no button but the skip.
struct CoverView: View {
    @ObservedObject var cover: AppCover

    var body: some View {
        ZStack {
            Color.introBlack.ignoresSafeArea()
            IntroStage(playback: cover.playback)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            if cover.flow.stage == .launch {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { cover.skipIntro() }
                    .accessibilityElement()
                    .accessibilityLabel("Skip intro")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("skip-intro")
            }
            #if DEBUG
            if Self.testBuild {
                // the test build's reading of where the intro is (the UI tests check it)
                Text("intro \(cover.flow.stage.rawValue)")
                    .font(.system(size: 2))
                    .foregroundStyle(.clear)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("intro-stage")
            }
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(cover.mode == .cover ? "privacy-cover" : "intro")
    }

    #if DEBUG
    static let testBuild = ProcessInfo.processInfo.arguments.contains("-uitest")
    #endif
}
