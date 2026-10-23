import Foundation
import UIKit
import Combine

@MainActor final class AppModel: ObservableObject {
    @Published var settings = GenerationSettings()
    @Published var running = false
    @Published var progress = GenerationProgress(message:"")
    @Published var preview: UIImage?
    @Published var message: String?
    @Published var error: String?
    @Published var tab = 0
    /// Countdown for the current image: when it started (pauses excluded) and when it should finish.
    @Published var runStart = Date()
    @Published var estimatedEnd: Date?
    @Published var paused = false
    /// The iPhone reported critical heat; work waits until it cools (countdown stopped).
    @Published var cooling = false
    private var ticker: Task<Void, Never>?
    @Published var imageNumber = 1
    private var clock: GenerationClock?
    private let activity = LiveActivityController()
    private let continuation = BackgroundContinuation()
    /// Moss is off screen and the engine has moved to the CPU under the continued-processing task.
    @Published var backgroundCPU = false
    let models: ModelManager
    let gallery: GalleryStore
    let loras: LoRAStore
    private var control: RunControl?
    private let worker = DispatchQueue(label:"Moss.generation",qos:.userInitiated)
    init(models: ModelManager, gallery: GalleryStore, loras: LoRAStore = LoRAStore()) {
        self.models = models; self.gallery = gallery; self.loras = loras
        if let quality = UserDefaults.standard.string(forKey:"defaultQuality"), let q = Quality(rawValue:quality) { settings.preset(q) }
        let width = UserDefaults.standard.integer(forKey:"defaultWidth"), height = UserDefaults.standard.integer(forKey:"defaultHeight")
        if width > 0 && height > 0 { settings.width = width; settings.height = height }
        if UserDefaults.standard.bool(forKey:"generationInProgress") {
            message = "The previous image did not finish. iOS may have closed Moss, or the app stopped. Keep Moss open while it works; try a smaller size or close other apps if it happens again. Your saved images are safe."
            UserDefaults.standard.set(false,forKey:"generationInProgress")
        }
    }
    func generate() {
        guard !running else { return }
        do {
            try settings.validate()
            guard models.ready, !models.busy, let manifest = models.manifest else { throw MossError.model("Finish downloading and verifying the model first.") }
            guard settings.quality != .fast || models.fastReady else { throw MossError.model("Download the Fast add-on (DMD2) in Settings → Models before using Fast.") }
            guard settings.model != .kromoss || models.kromossReady else { throw MossError.model("Download the Kromoss realism model in Settings → Models, or switch the model to MOSS Base.") }
            settings.loras = settings.loras.filter { loras.item($0.id) != nil }
            let userLoRAs = settings.loras.compactMap { c in loras.item(c.id).map { (url: loras.url($0), name: $0.name, strength: c.strength) } }
            models.refreshSpace()
            guard models.freeBytes > 500_000_000 else { throw MossError.model("Free at least 500 MB so Moss can save your images.") }
            let folder = models.folder, requested = settings, run = RunControl()
            control = run; running = true; error = nil; message = nil; preview = nil
            progress = .init(message:"Preparing model"); imageNumber = 1; paused = false
            UserDefaults.standard.set(true,forKey:"generationInProgress")
            UIApplication.shared.isIdleTimerDisabled = true
            haptic()
            run.notice = { [weak self] text in Task { @MainActor in self?.message = text } }
            continuation.expired = { [weak self] in self?.continuationExpired() }
            continuation.begin(subtitle: "\(requested.width) × \(requested.height) · \(requested.quality.rawValue)")
            run.coolingChanged = { [weak self] hot in let now = Date(); Task { @MainActor in self?.coolingTookEffect(hot, at: now) } }
            ticker?.cancel()
            ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self else { return }
                    if self.running && !self.paused && !self.cooling { self.refreshEstimate() }
                }
            }
            run.pauseChanged = { [weak self] isPaused in let now = Date(); Task { @MainActor in self?.pauseTookEffect(isPaused, at: now) } }
            worker.async {
                do {
                    for index in 0..<requested.count {
                        try run.check()
                        var actual = requested; actual.count = 1
                        actual.seed = requested.lockedSeed ? requested.seed &+ UInt32(index) : UInt32.random(in:0...UInt32.max)
                        actual.lockedSeed = true
                        let start = Date()
                        let semaphoreStart = DispatchSemaphore(value:0)
                        Task { @MainActor in self.begin(actual, number:index+1, of:requested.count); semaphoreStart.signal() }
                        semaphoreStart.wait()
                        let image = UIImage(cgImage: try autoreleasepool {
                            try MossPipeline().generate(settings:actual,folder:folder,manifest:manifest,control:run,userLoRAs:userLoRAs) { value in
                                let now = Date()
                                Task { @MainActor in self.advance(value, at:now) }
                            }
                        })
                        let finishedAt = Date()
                        Task { @MainActor in self.complete(at:finishedAt) }
                        let duration = Date().timeIntervalSince(start)
                        // Save each completed image before starting the next one.
                        let semaphore = DispatchSemaphore(value:0)
                        Task { @MainActor in
                            defer { semaphore.signal() }
                            do {
                                let item = try self.gallery.save(image:image,settings:actual,seconds:duration,identity:manifest.identity)
                                self.preview = image; self.settings.seed = actual.seed; self.haptic()
                                if UserDefaults.standard.bool(forKey:"autoSave") {
                                    Task { do { try await self.gallery.saveToPhotos([item]) } catch { self.error = "Image saved in Moss. Photos export failed: \(error.localizedDescription)" } }
                                }
                            } catch { self.error = "The image finished but could not be saved: \(error.localizedDescription)"; run.cancel() }
                        }
                        semaphore.wait()
                    }
                    Task { @MainActor in self.finish(nil) }
                } catch { Task { @MainActor in self.finish(error) } }
            }
        } catch { self.error = error.localizedDescription }
    }
    // MARK: Countdown and Live Activity

    private func begin(_ settings: GenerationSettings, number: Int, of count: Int) {
        clock = GenerationClock(plan:.init(settings:settings),calibration:.load())
        imageNumber = number; runStart = Date(); estimatedEnd = nil
        progress = .init(message:count > 1 ? "Image \(number) of \(count)" : "Preparing model")
        let state = activityState()
        if number == 1 { activity.start(settings:settings,state:state) } else { activity.update(state,force:true) }
        refreshEstimate()
    }
    private func advance(_ value: GenerationProgress, at now: Date) {
        clock?.record(value, at:now.timeIntervalSinceReferenceDate)
        progress = value
        refreshEstimate()
    }
    private func complete(at now: Date) {
        guard var c = clock else { return }
        c.record(.init(stage:.done,index:1,total:1,message:"Done"), at:now.timeIntervalSinceReferenceDate)
        c.calibrated().save()
        clock = nil
    }
    private func refreshEstimate() {
        guard let clock else { estimatedEnd = nil; return }
        let now = Date()
        if let left = clock.remaining(at:now.timeIntervalSinceReferenceDate) {
            let end = now.addingTimeInterval(left)
            // Keep the countdown steady: only move the finish time for changes over 3 s or 3 %.
            if let old = estimatedEnd, abs(old.timeIntervalSince(end)) < max(3, left * 0.03) {} else { estimatedEnd = end }
            if let f = clock.fraction(at:now.timeIntervalSinceReferenceDate), f > 0, f < 1 {
                runStart = now.addingTimeInterval(-(left * f / (1 - f)))
            }
        } else { estimatedEnd = nil }
        activity.update(activityState())
        continuation.update(fraction: clock.fraction(at:now.timeIntervalSinceReferenceDate) ?? stageFraction, subtitle: activityState().detail)
    }
    private var stageFraction: Double {
        let p = progress
        switch p.stage {
        case .encode: return 0.1 * Double(p.index) / Double(max(1,p.total))
        case .prepare: return 0.1
        case .sample: return 0.1 + 0.8 * Double(p.index) / Double(max(1,p.total))
        case .decode: return 0.9 + 0.1 * Double(p.index) / Double(max(1,p.total))
        default: return 0
        }
    }
    private func activityState() -> GenerationActivityAttributes.ContentState {
        let detail = progress.stage == .sample ? "Step \(min(progress.index+1,progress.total)) of \(progress.total)" :
            progress.stage == .decode ? "Finishing" : progress.stage == .encode ? "Reading prompt" : "Preparing"
        var label = settings.count > 1 ? "Image \(imageNumber) · \(detail)" : detail
        if backgroundCPU { label += " · slower in background" }
        let fraction = clock?.fraction(at:Date().timeIntervalSinceReferenceDate) ?? 0
        if cooling { label = "Cooling down" }
        return .init(phase: paused || cooling ? .paused : (estimatedEnd == nil ? .estimating : .running), detail:label, start:runStart, end:estimatedEnd, fraction:fraction)
    }
    private func coolingTookEffect(_ hot: Bool, at now: Date) {
        guard running else { return }
        cooling = hot
        if hot { clock?.pause(at:now.timeIntervalSinceReferenceDate) } else if !paused { clock?.resume(at:now.timeIntervalSinceReferenceDate) }
        refreshEstimate(); activity.update(activityState(),force:true)
    }
    private func pauseTookEffect(_ isPaused: Bool, at now: Date) {
        paused = isPaused
        if isPaused { clock?.pause(at:now.timeIntervalSinceReferenceDate) } else { clock?.resume(at:now.timeIntervalSinceReferenceDate) }
        if isPaused { activity.update(activityState(),force:true) } else { refreshEstimate(); activity.update(activityState(),force:true) }
    }
    /// Moss left the screen (or is about to). With iOS's continued-processing task the run keeps going on the
    /// CPU; without it, it stops at the next layer boundary and waits.
    func leftScreen() {
        control?.onScreen = false
        guard running, !backgroundCPU, !paused else { return }
        let now = Date().timeIntervalSinceReferenceDate
        if continuation.granted {
            control?.useCPU(true); backgroundCPU = true
            clock?.deviceChanged(at:now); estimatedEnd = nil
            activity.update(activityState(),force:true)
        } else {
            control?.pause(); paused = true
            clock?.pause(at:now)
            activity.update(activityState(),force:true)
        }
    }
    func returnedToScreen() {
        control?.onScreen = true
        guard running else { return }
        let now = Date().timeIntervalSinceReferenceDate
        if backgroundCPU {
            control?.useCPU(false); backgroundCPU = false
            clock?.deviceChanged(at:now); estimatedEnd = nil
        }
        if paused { control?.resume(); clock?.resume(at:now); paused = false }
        refreshEstimate(); activity.update(activityState(),force:true)
    }
    /// iOS withdrew the background allowance: fall back to waiting until Moss is opened again.
    private func continuationExpired() {
        guard running, backgroundCPU else { return }
        control?.pause(); control?.useCPU(false); backgroundCPU = false; paused = true
        clock?.pause(at:Date().timeIntervalSinceReferenceDate)
        activity.update(activityState(),force:true)
    }

    private func finish(_ error: Error?) {
        let ok = error == nil
        activity.end(state:.init(phase: ok ? .finished : .failed, detail: ok ? "Saved to your gallery" : "Stopped", start:runStart, end:Date(), fraction: ok ? 1 : 0))
        continuation.end(success: ok)
        ticker?.cancel(); ticker = nil; cooling = false
        clock = nil; estimatedEnd = nil; paused = false; backgroundCPU = false
        running = false; control = nil; UIApplication.shared.isIdleTimerDisabled = false
        UserDefaults.standard.set(false,forKey:"generationInProgress")
        progress = .init(message:error == nil ? "Image saved in your gallery" : "Generation stopped")
        if let error { self.error = error.localizedDescription }
    }
    func cancel() { control?.cancel(); progress = .init(message:"Stopping after the current operation") }
    func memoryWarning() { if running { control?.trimMemory() } }
    func reuse(_ item: GalleryItem) {
        guard !running else { error = "Wait for this image to finish before reusing settings."; return }
        settings = item.settings; settings.lockedSeed = true; settings.count = 1
        preview = UIImage(contentsOfFile:gallery.file(item).path); tab = 0
    }
    private func haptic() {
        if !UserDefaults.standard.objectExists("haptics") || UserDefaults.standard.bool(forKey:"haptics") { UIImpactFeedbackGenerator(style:.soft).impactOccurred() }
    }
}
extension UserDefaults { func objectExists(_ key: String) -> Bool { object(forKey:key) != nil } }
