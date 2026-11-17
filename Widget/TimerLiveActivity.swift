import ActivityKit
import AppIntents
import SwiftUI
import VirtCore
import WidgetKit

@main
struct VirtWidgets: WidgetBundle {
    var body: some Widget { TimerLiveActivity() }
}

/// In the extension the buttons' intent never runs (the system runs it in the app); this only lets it compile here.
enum CommandSink {
    static func run(_ c: TimerCommand) async {}
}

/// The timer on the lock screen and in the Dynamic Island. It counts by itself (the system's timer text), so it stays
/// right while the app and the page are asleep.
struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VirtTimerAttributes.self) { context in
            LockScreenTimer(title: context.attributes.title, d: context.state)
                .activityBackgroundTint(Color.virtBlack.opacity(0.92))
                .activitySystemActionForegroundColor(.virtGold)
        } dynamicIsland: { context in
            let d = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(d.label, systemImage: symbol(d.kind)).font(.headline).foregroundStyle(Color.virtGold).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ClockText(d: d).font(.title2.weight(.semibold)).foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        Bar(d: d)
                        Buttons(d: d)
                        NextLine(d: d)
                    }
                }
            } compactLeading: {
                Image(systemName: symbol(d.kind)).foregroundStyle(Color.virtGold)
            } compactTrailing: {
                ClockText(d: d).foregroundStyle(Color.virtGold).frame(maxWidth: 52)
            } minimal: {
                ClockText(d: d).font(.caption2).foregroundStyle(Color.virtGold)
            }
            .keylineTint(.virtGold)
        }
    }
}

func symbol(_ k: TimerKind) -> String {
    switch k {
    case .rest: return "hourglass"
    case .hold: return "figure.core.training"
    case .work: return "flame.fill"
    case .intervalRest: return "wind"
    case .other: return "timer"
    }
}

struct LockScreenTimer: View {
    let title: String
    let d: TimerDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Color.virtGold.opacity(0.8))
                    Label(d.label, systemImage: symbol(d.kind)).font(.headline).foregroundStyle(.white).lineLimit(1)
                    NextLine(d: d)
                }
                Spacer(minLength: 8)
                ClockText(d: d).font(.system(size: 40, weight: .semibold, design: .rounded)).foregroundStyle(Color.virtGold)
            }
            Bar(d: d)
            Buttons(d: d).frame(maxWidth: .infinity)
        }
        .padding(16)
    }
}

/// The countdown (or a stopwatch counting up), drawn by the system so it keeps time with the app asleep.
struct ClockText: View {
    let d: TimerDisplay

    var body: some View {
        Group {
            if let from = d.countsUpFrom {
                if d.paused { Text(TimerDisplay.clock(d.elapsed ?? 0)) } else { Text(from, style: .timer) }
            } else if let end = d.endsAt {
                Text(timerInterval: min(d.progressFrom ?? end, end)...end, countsDown: true, showsHours: false)
            } else {
                Text(TimerDisplay.clock(d.remaining ?? 0))
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
}

struct Bar: View {
    let d: TimerDisplay

    var body: some View {
        Group {
            if let end = d.endsAt, let from = d.progressFrom, from < end {
                ProgressView(timerInterval: from...end, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
            } else if let f = d.fraction {
                ProgressView(value: f)
            } else {
                ProgressView(value: d.countsUpFrom == nil ? 1 : 0)
            }
        }
        .progressViewStyle(.linear)
        .tint(.virtGold)
    }
}

struct NextLine: View {
    let d: TimerDisplay

    var body: some View {
        HStack(spacing: 4) {
            if d.paused { Text("Paused ·").foregroundStyle(Color.virtGold) }
            Text(d.next.isEmpty || d.next == "Done" ? (d.next == "Done" ? "Last one" : " ") : "Next: \(d.next)")
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            if let n = d.nextEndsAt, let end = d.endsAt, end < n {
                Text(timerInterval: end...n, countsDown: true, showsHours: false).monospacedDigit().foregroundStyle(.white.opacity(0.5))
            }
        }
        .font(.subheadline)
    }
}

/// −15, pause or resume, +15, and skip (Stop for a stopwatch hold).
struct Buttons: View {
    let d: TimerDisplay

    var body: some View {
        HStack(spacing: 10) {
            if d.countsUpFrom == nil {
                Button(intent: TimerCommandIntent(.minus15)) { Image(systemName: "gobackward.15") }
            }
            Button(intent: TimerCommandIntent(d.paused ? .resume : .pause)) { Image(systemName: d.paused ? "play.fill" : "pause.fill") }
            if d.countsUpFrom == nil {
                Button(intent: TimerCommandIntent(.add15)) { Image(systemName: "goforward.15") }
            }
            Button(intent: TimerCommandIntent(.skip)) { Image(systemName: d.countsUpFrom == nil ? "forward.end.fill" : "stop.fill") }
        }
        .buttonStyle(.bordered)
        .tint(.virtGold)
        .font(.body.weight(.semibold))
    }
}
