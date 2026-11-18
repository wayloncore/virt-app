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
