#if DEBUG
import SwiftUI
import VirtCore

/// The test build's widget gallery (`-uitest-widgets`): the widgets' own views at their real iPhone sizes, so the Mac
/// run can screenshot them (a UI test can't place a widget on the Home Screen). Sizes are Apple's for a 6.1-6.3 inch
/// iPhone: small 158 × 158, medium 338 × 158, Lock Screen circular 76 × 76, rectangular 172 × 76.
struct WidgetGallery: View {
    enum Page: String, CaseIterable { case home = "Home", lock = "Lock", standBy = "StandBy" }
    @State private var page = Page.home

    let now = Date()

    func info(_ change: (inout TodayInfo) -> Void = { _ in }) -> TodayInfo {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let wd = Calendar.current.component(.weekday, from: now) - 1
        var t = TodayInfo(date: f.string(from: now), title: "Legs A", kind: "workout", done: false, minutes: 45, weekDone: 2,
                          weekPlanned: 4, streakWeeks: 3, trainingDays: [wd, (wd + 2) % 7, (wd + 4) % 7, (wd + 5) % 7],
                          usualTime: "18:30", receivedAt: now)
        change(&t)
        return t
    }
    var workout: TodayStatus { info().status(now: now) }
    var done: TodayStatus { info { $0.done = true; $0.weekDone = 3 }.status(now: now) }
    var rest: TodayStatus { info { $0.kind = "rest"; $0.title = "Rest day"; $0.minutes = nil }.status(now: now) }
    var empty: TodayStatus { Optional<TodayInfo>.none.status(now: now) }

    var body: some View {
        VStack(spacing: 10) {
            Picker("Page", selection: $page) {
                ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0).accessibilityIdentifier("gallery-\($0.rawValue)") }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            ScrollView {
                switch page {
                case .home: home
                case .lock: lock
                case .standBy: standBy
                }
            }
        }
        .padding(.top, 8)
        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.3), Color(red: 0.32, green: 0.22, blue: 0.3)],
                                   startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    func homeTile<V: View>(_ v: V, w: CGFloat, h: CGFloat = 158, _ name: String) -> some View {
        VStack(spacing: 4) {
            v.padding(16).frame(width: w, height: h).background(Color.virtBlack)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text(name).font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
    }

    var home: some View {
        VStack(spacing: 14) {
            HStack(spacing: 20) {
                homeTile(TodaySmall(s: workout), w: 158, "Small: workout to do")
                homeTile(TodaySmall(s: done), w: 158, "Small: done")
            }
            HStack(spacing: 20) {
                homeTile(TodaySmall(s: rest), w: 158, "Small: rest day")
                homeTile(TodaySmall(s: empty), w: 158, "Small: before any data")
            }
            homeTile(TodayMedium(s: workout), w: 338, "Medium: workout to do")
            homeTile(TodayMedium(s: done), w: 338, "Medium: done")
        }
        .padding(.vertical, 8)
    }

    func lockTile<V: View>(_ v: V, w: CGFloat, h: CGFloat, _ name: String) -> some View {
        VStack(spacing: 4) {
            v.frame(width: w, height: h).foregroundStyle(.white)
            Text(name).font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
    }

    var circleBack: AnyView { AnyView(Circle().fill(.white.opacity(0.18))) }

    var lock: some View {
        VStack(spacing: 16) {
            Text("9:41").font(.system(size: 88, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
            HStack(spacing: 14) {
                lockTile(WeekCircular(s: workout), w: 76, h: 76, "Week")
                lockTile(NextCircular(s: workout, background: circleBack), w: 76, h: 76, "Next: today")
                lockTile(NextCircular(s: done, background: circleBack), w: 76, h: 76, "Next: later")
            }
            HStack(spacing: 12) {
                lockTile(NextRectangular(s: workout), w: 172, h: 76, "Next workout: today")
                lockTile(NextRectangular(s: done), w: 172, h: 76, "Next workout: done today")
            }
            HStack(spacing: 12) {
                lockTile(WeekRectangular(s: workout), w: 172, h: 76, "This week")
                lockTile(NextRectangular(s: empty), w: 172, h: 76, "Before any data")
            }
            lockTile(TodayInline(s: workout).font(.system(size: 17, weight: .semibold)), w: 300, h: 26, "Inline")
        }
        .padding(.vertical, 8)
    }

    /// StandBy shows widgets with no background, scaled up on the charging phone turned sideways; the Live Activity
    /// is its Lock Screen view, scaled up and dimmed at night.
    var standBy: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                lockTile(TodaySmall(s: workout, standBy: true).padding(16), w: 170, h: 170, "StandBy small")
                lockTile(TodaySmall(s: done, standBy: true).padding(16), w: 170, h: 170, "StandBy small: done")
            }
            .background(Color.black)
            let d = TimerDisplay(id: "rest:1", kind: .rest, label: "Rest", next: "set 2 of Squat", endsAt: now.addingTimeInterval(83),
                                 progressFrom: now.addingTimeInterval(-7))
            lockTile(LockScreenTimer(title: "Legs A", d: d).background(Color.virtBlack.opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)), w: 370, h: 168, "Live Activity, Lock Screen")
            lockTile(LockScreenTimer(title: "Legs A", d: d).environment(\.isLuminanceReduced, true).background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)), w: 370, h: 110, "Live Activity, StandBy at night (dimmed)")
        }
        .padding(.vertical, 8)
    }
}
#endif
