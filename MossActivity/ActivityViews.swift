import SwiftUI

let mossActivityTint = Color(red: 0.55, green: 0.68, blue: 0.47)


/// Ring that fills smoothly toward the estimated finish time without needing app updates.
struct ProgressRing: View {
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
            ProgressRing(state: state, lineWidth: 4).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.phase == .finished ? "Your image is ready" : "Moss is creating your image").font(.headline)
                Text(state.phase == .paused ? "Paused · open Moss to continue" : "\(state.detail) · \(size)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Countdown(state: state).font(.title3.weight(.semibold)).foregroundStyle(mossActivityTint)
                .multilineTextAlignment(.trailing).frame(maxWidth: 90, alignment: .trailing)
        }
        .padding(16)
    }
}
