import AppIntents
import SwiftUI
import VirtCore

// The Live Activity's views, compiled into both the timer extension and the app (the test build's widget gallery
// draws them at real size for the screenshots).

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
    /// Dimmed (StandBy at night, the always-on screen): the clock alone, as big as it goes.
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        if dimmed { dimmedBody } else { fullBody }
    }

    /// StandBy scales this whole view up to fill the screen, so the clock gets most of the room.
    private var dimmedBody: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label(d.label, systemImage: symbol(d.kind)).font(.headline).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                NextLine(d: d)
            }
            Spacer(minLength: 4)
            ClockText(d: d).font(.system(size: 58, weight: .bold, design: .rounded)).foregroundStyle(Color.virtGold)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(16)
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Color.virtGold.opacity(0.8))
                    Label(d.label, systemImage: symbol(d.kind)).font(.headline).foregroundStyle(.white).lineLimit(1)
                    NextLine(d: d)
                }
                Spacer(minLength: 8)
                ClockText(d: d).font(.system(size: 46, weight: .bold, design: .rounded)).foregroundStyle(Color.virtGold)
                    .lineLimit(1).minimumScaleFactor(0.6)
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
