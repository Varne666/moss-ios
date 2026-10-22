import SwiftUI

let mossActivityTint = Color(red: 0.79, green: 0.95, blue: 0.36)


/// Ring that fills smoothly toward the estimated finish time without needing app updates.
struct ProgressRing: View {
    let state: GenerationActivityAttributes.ContentState
    var body: some View {
        Group {
            if state.phase == .running, let end = state.end, end > state.start {
                ProgressView(timerInterval: state.start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: state.phase == .finished ? 1 : state.fraction) { EmptyView() } currentValueLabel: { EmptyView() }
            }
        }
        .progressViewStyle(.circular)
        .tint(state.phase == .failed ? .red : mossActivityTint)
    }
}

/// "4:12" counting down, or a short word when there is no estimate.
struct Countdown: View {
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


struct LockScreenView: View {
    let state: GenerationActivityAttributes.ContentState
    let size: String
    var body: some View {
        HStack(spacing: 14) {
            ProgressRing(state: state).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.phase == .finished ? "Image ready" : "Creating image").font(.headline).lineLimit(1)
                Text(state.phase == .paused ? "Paused · open Moss" : "\(state.detail) · \(size)")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            Countdown(state: state).font(.title2.weight(.semibold)).foregroundStyle(mossActivityTint)
                .lineLimit(1).multilineTextAlignment(.trailing).frame(maxWidth: 96, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}
