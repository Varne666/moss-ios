import ActivityKit
import Foundation

/// Owns the Dynamic Island / Lock Screen activity for one generation run.
@MainActor final class LiveActivityController {
    private var activity: Activity<GenerationActivityAttributes>?
    private var lastState: GenerationActivityAttributes.ContentState?
    private var lastPush = Date.distantPast

    func start(settings: GenerationSettings, state: GenerationActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end(state: nil)
        let attributes = GenerationActivityAttributes(size: "\(settings.width) × \(settings.height)", quality: settings.quality.rawValue)
        do {
            activity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil), pushType: nil)
            lastState = state; lastPush = Date()
        } catch { activity = nil }
    }

    /// Pushes a new state when something visible changed: phase, status text, or a finish time that moved
    /// by more than a few seconds (small corrections are not worth an update; the countdown runs on its own).
    func update(_ state: GenerationActivityAttributes.ContentState, force: Bool = false) {
        guard let activity else { return }
        if !force, let last = lastState, last.phase == state.phase, last.detail == state.detail {
            let moved = abs((last.end ?? .distantPast).timeIntervalSince(state.end ?? .distantPast))
            if moved < 5 || Date().timeIntervalSince(lastPush) < 2 { return }
        }
        lastState = state; lastPush = Date()
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end(state: GenerationActivityAttributes.ContentState?) {
        guard let activity else { return }
        self.activity = nil; lastState = nil
        Task {
            if let state { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(8))) }
            else { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
