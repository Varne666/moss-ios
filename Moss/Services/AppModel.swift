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
    let models: ModelManager
    let gallery: GalleryStore
    private var control: RunControl?
    private let worker = DispatchQueue(label:"Moss.generation",qos:.userInitiated)
    init(models: ModelManager, gallery: GalleryStore) {
        self.models = models; self.gallery = gallery
        if let quality = UserDefaults.standard.string(forKey:"defaultQuality"), let q = Quality(rawValue:quality) { settings.preset(q) }
        let width = UserDefaults.standard.integer(forKey:"defaultWidth"), height = UserDefaults.standard.integer(forKey:"defaultHeight")
        if width > 0 && height > 0 { settings.width = width; settings.height = height }
        if UserDefaults.standard.bool(forKey:"generationInProgress") {
            message = "The previous image did not finish. iOS may have closed Moss, or the app stopped. Try 512 × 512 and keep Moss open. Your saved images are safe."
            UserDefaults.standard.set(false,forKey:"generationInProgress")
        }
    }
    func generate() {
        guard !running else { return }
        do {
            try settings.validate()
            guard models.ready, !models.busy, let manifest = models.manifest else { throw MossError.model("Finish downloading and verifying the model first.") }
            guard settings.quality != .fast || models.fastReady else { throw MossError.model("Download the Fast adapter in Settings before using Fast.") }
            models.refreshSpace()
            guard models.freeBytes > 500_000_000 else { throw MossError.model("Free at least 500 MB so Moss can save your images.") }
            let folder = models.folder, requested = settings, run = RunControl()
            control = run; running = true; error = nil; message = nil; preview = nil
            progress = .init(message:"Preparing model")
            UserDefaults.standard.set(true,forKey:"generationInProgress")
            UIApplication.shared.isIdleTimerDisabled = true
            haptic()
            run.notice = { [weak self] text in Task { @MainActor in self?.message = text } }
            worker.async {
                do {
                    for index in 0..<requested.count {
                        try run.check()
                        var actual = requested; actual.count = 1
                        actual.seed = requested.lockedSeed ? requested.seed &+ UInt32(index) : UInt32.random(in:0...UInt32.max)
                        actual.lockedSeed = true
                        let start = Date()
                        let image = try autoreleasepool {
                            try MossPipeline().generate(settings:actual,folder:folder,manifest:manifest,control:run) { value in
                                Task { @MainActor in self.progress = value }
                            }
                        }
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
    private func finish(_ error: Error?) {
        running = false; control = nil; UIApplication.shared.isIdleTimerDisabled = false
        UserDefaults.standard.set(false,forKey:"generationInProgress")
        progress = .init(message:error == nil ? "Image saved in your gallery" : "Generation stopped")
        if let error { self.error = error.localizedDescription }
    }
    func cancel() { control?.cancel(); progress = .init(message:"Stopping after the current operation") }
    func backgrounded() { if running { control?.cancel(.background) } }
    func memoryWarning() { if running { control?.cancel(.memory) } }
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
