import AVFoundation
import SwiftUI
import UIKit
import VirtCore

/// The video intro (Tyler's Kling clips, Nov 18; App/Intro/, made by scripts/intro_video.py). It replaces the drawn
/// wordmark intro of Nov 17. The order of events is VirtCore's `IntroFlow`; App/Cover.swift drives it and this plays it:
///
/// - the launch clip (VIRT, the I, R and T wipe away, the V grows; about 4 s) on a fresh launch. It ends on the large V
///   (VirtLock.png is that exact frame, so the V never jumps);
/// - straight on, the unlock clip (the camera flies into the V until it's black; about 1.7 s), then Training fades in.
///   Nothing waits for Face ID or the passcode: Virt has no lock of its own since Nov 28.
///
/// The clips and the still are on pure black and are all drawn the same way (fit to the screen's width, centered), so
/// they line up exactly. The launch clip and the still are 1080 x 1920; the unlock clip is drawn on a taller 1080 x 2400
/// canvas so its fly-in runs off the real screen's top and bottom (its first frame is the still's, with black above
/// and below, off screen). No sound: the clips have no audio track and the players are muted. With Reduce Motion
/// nothing plays: Virt opens straight into Training.
@MainActor final class IntroPlayback {
    /// The V on black: the launch clip's last frame, under the clips and as the app switcher's cover.
    static let still = UIImage(named: "VirtLock")
    /// How long the intro's window takes to fade into Training after the unlock clip.
    static let fadeToTraining: TimeInterval = 0.3

    let view = IntroStageView()
    var onLaunchEnded: (() -> Void)?
    var onUnlockEnded: (() -> Void)?

    private let launch: AVPlayer?
    private let unlock: AVPlayer?
    private var launchEnd: CMTime = .invalid
    private var launchStarted = false
    private var unlockStarted = false
    private var readyWatch: NSKeyValueObservation?
    private var statusWatches: [NSKeyValueObservation] = []
    /// Each clip's safety net: if a clip fails or never says it reached its end, it counts as ended a moment after it
    /// should have, so the intro's window can never be left stuck on a clip. A new play or a stop cancels the old one.
    private var launchToken = 0
    private var unlockToken = 0
    static let launchLength: TimeInterval = 4.0
    static let unlockLength: TimeInterval = 1.6

    init() {
        launch = Self.player("virt-launch")
        unlock = Self.player("virt-unlock")
        view.launchLayer.player = launch
        view.unlockLayer.player = unlock
        view.still.image = Self.still
        if let item = launch?.currentItem {
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onLaunchEnded?() }
            }
            Task { [weak self] in
                guard let d = try? await item.asset.load(.duration) else { return }
                // the last frame starts 1/60 s before the end; a seek just inside it shows that frame
                self?.launchEnd = CMTimeSubtract(d, CMTime(value: 1, timescale: 120))
            }
        }
        if let item = unlock?.currentItem {
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onUnlockEnded?() }
            }
        }
        // a clip that can't play counts as ended at once
        for (item, isLaunch) in [(launch?.currentItem, true), (unlock?.currentItem, false)] {
            guard let item else { continue }
            statusWatches.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if isLaunch, self.launchStarted { self.onLaunchEnded?() }
                    if !isLaunch, self.unlockStarted { self.onUnlockEnded?() }
                }
            })
        }
    }

    private func launchSafetyNet(after seconds: TimeInterval) {
        launchToken += 1
        let token = launchToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.launchToken == token, self.launchStarted else { return }
            self.onLaunchEnded?()
        }
    }

    private func unlockSafetyNet(after seconds: TimeInterval) {
        unlockToken += 1
        let token = unlockToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.unlockToken == token, self.unlockStarted else { return }
            self.onUnlockEnded?()
        }
    }

    private static func player(_ name: String) -> AVPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp4") else { return nil }
        let p = AVPlayer(playerItem: AVPlayerItem(url: url))
        p.isMuted = true
        p.actionAtItemEnd = .pause   // holds the last frame
        p.preventsDisplaySleepDuringVideoPlayback = false
        p.allowsExternalPlayback = false
        return p
    }

    // MARK: - The launch clip

    /// Plays the launch clip from the start (or, in the test build, holds it still `frozenAt` seconds in, or plays it
    /// at `rate`).
    func playLaunch(frozenAt: TimeInterval? = nil, rate: Float = 1) {
        guard let launch else { return onLaunchEnded?() ?? () }
        launchStarted = true
        view.show(still: false, launch: true, unlock: false)
        if let t = frozenAt {
            launch.pause()
            launch.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            launch.seek(to: .zero)
            launch.playImmediately(atRate: rate)
            launchSafetyNet(after: Self.launchLength / Double(rate) + 1.5)
        }
    }

    /// A tap: straight to the launch clip's last frame, the V (the unlock clip plays from there).
    func skipLaunch() {
        guard let launch, launchStarted else { return }
        launchToken += 1
        launch.pause()
        if launchEnd.isValid {
            launch.seek(to: launchEnd, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            // not loaded yet: the still is the same frame
            view.show(still: true, launch: false, unlock: false)
        }
    }

    // MARK: - The unlock clip

    /// Plays the unlock clip (or, in the test build, holds it still `frozenAt` seconds in). Its first frame is the launch
    /// clip's last, the V, so it starts over it without a jump; its layer shows once that frame is ready.
    func playUnlock(frozenAt: TimeInterval? = nil) {
        guard let unlock else { return onUnlockEnded?() ?? () }
        launch?.pause()
        unlockStarted = true
        let start = { [weak self] in
            guard let self, self.unlockStarted else { return }
            self.view.show(still: true, launch: self.launchStarted, unlock: true)
        }
        if view.unlockLayer.isReadyForDisplay {
            start()
        } else {
            readyWatch = view.unlockLayer.observe(\.isReadyForDisplay, options: [.new]) { layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async { start() }
            }
            // never left waiting: its first frame is the still's own, so showing it a moment early can't jump
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { start() }
        }
        if let t = frozenAt {
            unlock.pause()
            unlock.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            unlock.seek(to: .zero)
            unlock.play()
            unlockSafetyNet(after: Self.unlockLength + 1.5)
        }
    }

    // MARK: - The still

    /// The V alone, with nothing playing: the app switcher's cover, Training opened straight in, or after the app went
    /// to the background mid-clip. Each clip starts over from its beginning next time.
    func showStill() {
        launch?.pause()
        unlock?.pause()
        readyWatch = nil
        launchToken += 1
        unlockToken += 1
        launchStarted = false
        unlockStarted = false
        view.show(still: true, launch: false, unlock: false)
        unlock?.seek(to: .zero)
    }
}

/// The intro's picture: the still, then the launch clip over it, then the unlock clip over that, all the full screen,
/// fit to its width and centered, on pure black.
final class IntroStageView: UIView {
    let still = UIImageView()
    let launchLayer = AVPlayerLayer()
    let unlockLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .introBlack
        isUserInteractionEnabled = false
        still.contentMode = .scaleAspectFit
        still.isHidden = true
        addSubview(still)
        // the player layers switch by opacity, not isHidden: a hidden player layer may never get its first frame ready
        for l in [launchLayer, unlockLayer] {
            l.backgroundColor = UIColor.clear.cgColor
            l.opacity = 0
            layer.addSublayer(l)
        }
        // the launch clip (9:16) fits the screen's width like the still. The unlock clip's canvas is taller than any
        // iPhone screen, so filling the screen also scales it by the width: the same size as the still, with the
        // extra height off screen.
        launchLayer.videoGravity = .resizeAspect
        unlockLayer.videoGravity = .resizeAspectFill
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.frame = bounds
        launchLayer.frame = bounds
        unlockLayer.frame = bounds
        CATransaction.commit()
    }

    func show(still s: Bool, launch: Bool, unlock: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.isHidden = !s
        still.alpha = 1
        launchLayer.opacity = launch ? 1 : 0
        unlockLayer.opacity = unlock ? 1 : 0
        CATransaction.commit()
    }
}

/// The intro's picture in the intro window's SwiftUI view (App/Cover.swift).
struct IntroStage: UIViewRepresentable {
    let playback: IntroPlayback
    func makeUIView(context: Context) -> IntroStageView { playback.view }
    func updateUIView(_ uiView: IntroStageView, context: Context) {}
}

extension UIColor {
    /// The launch screen, the intro and the app switcher's cover: pure black, to match the clips. The rest of the app
    /// keeps `virtBlack`.
    static let introBlack = UIColor.black
}

extension Color {
    static let introBlack = Color.black
}
