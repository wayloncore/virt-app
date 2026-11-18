import AVFoundation
import SwiftUI
import UIKit
import VirtCore

/// The video intro (Tyler's Kling clips, Nov 18; App/Intro/, made by scripts/intro_video.py). It replaces the drawn
/// wordmark intro of Nov 17. The order of events is VirtCore's `IntroFlow`; this plays it:
///
/// - the launch clip (VIRT, the I, R and T wipe away, the V grows; about 3.5 s) on a fresh launch, while Face ID asks;
/// - the lock screen: the launch clip's last frame (VirtLock.png is that exact frame, so the V never jumps);
/// - the unlock clip (the camera flies into the V until it's black; about 1.7 s) when Face ID says yes.
///
/// The clips and the still are on pure black and are all drawn the same way (fit to the screen's width, centered), so
/// they line up exactly. The launch clip and the still are 1080 x 1920; the unlock clip is drawn on a taller 1080 x 2400
/// canvas so its fly-in runs off the real screen's top and bottom (its first frame is the still's, with black above
/// and below, off screen). No sound: the clips have no audio track and the players are muted. With
/// Reduce Motion nothing plays: the still fades in, and unlocking fades straight to Training.
@MainActor final class IntroPlayback {
    /// The lock screen's V: the launch clip's last frame.
    static let still = UIImage(named: "VirtLock")
    /// How long the window takes to fade into Training after the unlock clip (or straight away with Reduce Motion).
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
        }
    }

    /// Face ID said yes partway through: the rest of the V landing, quickly.
    func hurryLaunch() {
        guard let launch, launchStarted else { return onLaunchEnded?() ?? () }
        launch.rate = launch.currentItem?.canPlayFastForward == false ? 2 : IntroFlow.hurryRate
    }

    /// A tap: straight to the launch clip's last frame, which is the lock screen.
    func skipLaunch() {
        guard let launch, launchStarted else { return }
        launch.pause()
        if launchEnd.isValid {
            launch.seek(to: launchEnd, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            // not loaded yet: the still is the same frame
            view.show(still: true, launch: false, unlock: false)
        }
    }

    /// The launch clip is over: it holds its last frame (the still is the same frame, underneath).
    func holdLaunchEnd() {
        view.show(still: true, launch: launchStarted, unlock: false)
    }

    // MARK: - The unlock clip

    /// Plays the unlock clip (or, in the test build, holds it still `frozenAt` seconds in). Its first frame is the
    /// lock screen's own, so it can start over the V without a jump; its layer shows once that frame is ready.
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
        }
    }

    // MARK: - The still

    /// The lock screen's V alone, with nothing playing: locked again after time away, the app switcher's cover, or
    /// after the app went to the background mid-clip. Each clip starts over from its beginning next time.
    func showStill(animated: Bool = false) {
        launch?.pause()
        unlock?.pause()
        readyWatch = nil
        launchStarted = false
        unlockStarted = false
        view.show(still: true, launch: false, unlock: false)
        if animated {
            view.still.alpha = 0
            UIView.animate(withDuration: 0.4) { self.view.still.alpha = 1 }
        }
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
        backgroundColor = .lockBlack
        isUserInteractionEnabled = false
        still.contentMode = .scaleAspectFit
        still.isHidden = true
        addSubview(still)
        // the player layers switch by opacity, not isHidden: a hidden player layer may never get its first frame ready
        for l in [launchLayer, unlockLayer] {
            l.videoGravity = .resizeAspect
            l.backgroundColor = UIColor.clear.cgColor
            l.opacity = 0
            layer.addSublayer(l)
        }
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

/// The intro's picture in the lock screen's SwiftUI view.
struct IntroStage: UIViewRepresentable {
    let playback: IntroPlayback
    func makeUIView(context: Context) -> IntroStageView { playback.view }
    func updateUIView(_ uiView: IntroStageView, context: Context) {}
}

extension UIColor {
    /// The launch screen, the intro and the lock screen: pure black, to match the clips. The rest of the app keeps
    /// `virtBlack`.
    static let lockBlack = UIColor.black
}

extension Color {
    static let lockBlack = Color.black
}
