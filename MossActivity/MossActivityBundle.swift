import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MossActivityBundle: WidgetBundle {
    var body: some Widget { GenerationLiveActivity() }
}

struct GenerationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GenerationActivityAttributes.self) { context in
            LockScreenView(state: context.state, size: context.attributes.size)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(mossActivityTint)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text("Moss").font(.headline) } icon: { Image(systemName: "leaf.fill").foregroundStyle(mossActivityTint) }
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(state: context.state).font(.title3.weight(.semibold)).foregroundStyle(mossActivityTint)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 96, alignment: .trailing).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if context.state.phase == .running, let end = context.state.end, end > context.state.start {
                            ProgressView(timerInterval: context.state.start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                                .tint(mossActivityTint)
                        } else {
                            ProgressView(value: context.state.phase == .finished ? 1 : context.state.fraction).tint(mossActivityTint)
                        }
                        Text(context.state.phase == .paused ? "Paused · open Moss to continue" : "\(context.state.detail) · \(context.attributes.size) · \(context.attributes.quality)")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 4)
                }
            } compactLeading: {
                ProgressRing(state: context.state).frame(width: 18, height: 18)
            } compactTrailing: {
                Countdown(state: context.state).font(.caption.weight(.semibold)).foregroundStyle(mossActivityTint)
                    .frame(maxWidth: 52, alignment: .trailing)
            } minimal: {
                ProgressRing(state: context.state).frame(width: 18, height: 18)
            }
            .keylineTint(mossActivityTint)
        }
    }
}
