import ActivityKit
import SwiftUI
import WidgetKit

private let moss = Color(red: 0.55, green: 0.68, blue: 0.47)

@main
struct MossActivityBundle: WidgetBundle {
    var body: some Widget { GenerationLiveActivity() }
}

/// Ring that fills smoothly toward the estimated finish time without needing app updates.
private struct ProgressRing: View {
    let state: GenerationActivityAttributes.ContentState
    var lineWidth: CGFloat = 3
    var body: some View {
        Group {
            if state.phase == .running, let end = state.end, end > state.start {
                ProgressView(timerInterval: state.start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: state.phase == .finished ? 1 : state.fraction) { EmptyView() } currentValueLabel: { EmptyView() }
            }
        }
        .progressViewStyle(.circular)
        .tint(state.phase == .failed ? .red : moss)
    }
}

/// "4:12" counting down, or a short word when there is no estimate.
private struct Countdown: View {
    let state: GenerationActivityAttributes.ContentState
    var body: some View {
        switch state.phase {
        case .running:
            if let end = state.end, end > Date() {
                Text(timerInterval: Date()...end, countsDown: true, showsHours: true).monospacedDigit()
            } else { Text("Almost") }
        case .estimating: Text("Timing…")
        case .paused: Text("Paused")
        case .finished: Text("Done")
        case .failed: Text("Stopped")
        }
    }
}

struct GenerationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GenerationActivityAttributes.self) { context in
            // Lock Screen / banner
            HStack(spacing: 14) {
                ProgressRing(state: context.state, lineWidth: 4).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.phase == .finished ? "Your image is ready" : "Moss is creating your image").font(.headline)
                    Text(context.state.phase == .paused ? "Paused · open Moss to continue" : "\(context.state.detail) · \(context.attributes.size)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Countdown(state: context.state).font(.title3.weight(.semibold)).foregroundStyle(moss)
                    .multilineTextAlignment(.trailing).frame(maxWidth: 90, alignment: .trailing)
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(moss)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text("Moss").font(.headline) } icon: { Image(systemName: "leaf.fill").foregroundStyle(moss) }
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(state: context.state).font(.title3.weight(.semibold)).foregroundStyle(moss)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 96, alignment: .trailing).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if context.state.phase == .running, let end = context.state.end, end > context.state.start {
                            ProgressView(timerInterval: context.state.start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                                .tint(moss)
                        } else {
                            ProgressView(value: context.state.phase == .finished ? 1 : context.state.fraction).tint(moss)
                        }
                        Text(context.state.phase == .paused ? "Paused · open Moss to continue" : "\(context.state.detail) · \(context.attributes.size) · \(context.attributes.quality)")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 4)
                }
            } compactLeading: {
                ProgressRing(state: context.state).frame(width: 18, height: 18)
            } compactTrailing: {
                Countdown(state: context.state).font(.caption.weight(.semibold)).foregroundStyle(moss)
                    .frame(maxWidth: 52, alignment: .trailing)
            } minimal: {
                ProgressRing(state: context.state).frame(width: 18, height: 18)
            }
            .keylineTint(moss)
        }
    }
}
