import ActivityKit
import AppIntents
import SwiftUI
import VirtCore
import WidgetKit

@main
struct VirtWidgets: WidgetBundle {
    var body: some Widget {
        TimerLiveActivity()
        TodayWidget()
        WeekWidget()
        if #available(iOS 18.0, *) { LogSetControl() }
    }
}

/// Log set in Control Center, on the Lock Screen's controls or the Action button (iOS 18, #573): the same intent as the
/// Live Activity's Log set, which the system runs in the app, so it logs the open exercise's next set and starts its
/// rest. With no workout open it does nothing.
@available(iOS 18.0, *)
struct LogSetControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.tyleralocke.virt.log-set") {
            ControlWidgetButton(action: TimerCommandIntent(.log)) {
                Label("Log set", systemImage: "checkmark.circle.fill")
            }
        }
        .displayName("Log set")
        .description("Logs the next set of the workout that's open in Virt, and starts its rest.")
    }
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
            LockScreenTimer(title: context.attributes.title, d: context.state.current(at: Date()))
                .activityBackgroundTint(Color.virtBlack.opacity(0.92))
                .activitySystemActionForegroundColor(.virtAccent)
        } dynamicIsland: { context in
            let d = context.state.current(at: Date())
            let between = d.betweenSets == true
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(between ? (d.setExercise ?? d.label) : d.label, systemImage: between ? "dumbbell.fill" : symbol(d.kind))
                        .font(.headline).foregroundStyle(Color.virtAccent).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !between { ClockText(d: d).font(.title2.weight(.semibold)).foregroundStyle(.white) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if between {
                        // between sets: the next set and Log set (#573)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(d.setDetail ?? "").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                            if let words = d.logButton { LogButton(words: words, big: true) }
                        }
                    } else {
                        VStack(spacing: 8) {
                            Bar(d: d)
                            Buttons(d: d)
                            NextLine(d: d, full: true)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: between ? "dumbbell.fill" : symbol(d.kind)).foregroundStyle(Color.virtAccent)
            } compactTrailing: {
                if between {
                    Text(d.logButton.map { $0.replacingOccurrences(of: "Log set", with: "Set") } ?? "Done").font(.caption.weight(.semibold))
                        .foregroundStyle(Color.virtAccent)
                } else {
                    ClockText(d: d).foregroundStyle(Color.virtAccent).frame(maxWidth: 52)
                }
            } minimal: {
                if between {
                    Image(systemName: "dumbbell.fill").foregroundStyle(Color.virtAccent)
                } else {
                    ClockText(d: d).font(.caption2).foregroundStyle(Color.virtAccent)
                }
            }
            .keylineTint(.virtAccent)
        }
    }
}
