import BackgroundTasks
import Foundation

/// iOS 26 continued-processing task: lets a generation the user started keep running after they leave Moss.
/// iPhone does not allow GPU work in the background (Apple only offers background GPU on M3+ iPads), so
/// while Moss is in the background the engine runs on the CPU, which is much slower, and returns to the
/// GPU as soon as Moss is on screen. If iOS refuses the task, generation pauses in the background instead.
@MainActor final class BackgroundContinuation {
    private var task: BGContinuedProcessingTask?
    private var identifier: String?
    private var title = "Creating your image"
    /// Called when iOS ends the background allowance (the user stopped it, or the system needed resources).
    var expired: (() -> Void)?
    /// True once iOS has granted the task, so leaving Moss can continue on the CPU.
    var granted: Bool { task != nil }

    func begin(subtitle: String) {
        end(success: false)
        guard let bundle = Bundle.main.bundleIdentifier else { return }
        let id = "\(bundle).generate.\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] launched in
            guard let continued = launched as? BGContinuedProcessingTask else { launched.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated {
                guard let self, self.identifier == id else { continued.setTaskCompleted(success: false); return }
                continued.progress.totalUnitCount = 1000
                continued.expirationHandler = { [weak self] in
                    DispatchQueue.main.async { self?.task = nil; self?.expired?() }
                }
                self.task = continued
            }
        }
        guard registered else { return }
        identifier = id
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: subtitle)
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch { identifier = nil }
    }

    func update(fraction: Double?, subtitle: String) {
        guard let task else { return }
        if let fraction { task.progress.completedUnitCount = Int64(max(0, min(1, fraction)) * 1000) }
        task.updateTitle(title, subtitle: subtitle)
    }

    func end(success: Bool) {
        task?.setTaskCompleted(success: success)
        task = nil; identifier = nil
    }
}
