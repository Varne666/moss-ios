import Foundation
import os
import MLX

final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped: MossError?
    private var announcedHeat = false
    private var paused = false
    var notice: ((String) -> Void)?
    /// Called on the worker thread when a thermal pause starts (true) and ends (false).
    var coolingChanged: ((Bool) -> Void)?
    /// Called on the worker thread when a pause takes effect (true) and when work resumes (false).
    var pauseChanged: ((Bool) -> Void)?
    func cancel(_ reason: MossError = .cancelled) { RunLog.add("control: stop requested"); lock.lock(); stopped = reason; lock.unlock() }
    /// iOS forbids GPU work while the app is in the background, so generation waits at the next layer
    /// boundary until Moss is on screen again instead of being cancelled.
    func pause() { lock.lock(); paused = true; lock.unlock() }
    private var cpu = false
    private var trimRequested = false
    private var visible = true
    /// Moss is on screen (set by the app on every scene change).
    var onScreen: Bool { get { lock.lock(); defer { lock.unlock() }; return visible } set { lock.lock(); visible = newValue; lock.unlock() } }
    /// iOS sent a memory warning: release MLX's buffer cache at the next layer boundary instead of stopping.
    func trimMemory() { lock.lock(); trimRequested = true; dropLayers = true; lock.unlock() }
    private var dropLayers = false
    /// True once after a memory warning: the transformer releases its in-memory layer cache.
    func consumeDropLayers() -> Bool { lock.lock(); defer { dropLayers = false; lock.unlock() }; return dropLayers }
    /// Bytes of transformer weights that may stay in memory between sampling steps (0 = stream every step).
    /// On iPhone it is what iOS says this app can still use, minus room for activations and the system.
    func layerCacheBudget(pixels: Int) -> Int64 {
        if let override = ProcessInfo.processInfo.environment["MOSS_LAYER_CACHE_MB"], let mb = Int64(override) { return mb << 20 }
        // Measured on the macOS harness (Fast, 1024², 2.6 GB cached): no faster per step, because the system
        // file cache already keeps recently read weights in RAM, while peak memory rose from 2.7 to 4.9 GiB.
        // On iPhone that extra memory only adds jetsam risk, so streaming stays the default.
        #if os(iOS)
        return 0
        #else
        return 0
        #endif
    }
    /// While Moss is in the background under an iOS continued-processing task, work moves to the CPU:
    /// iOS does not allow GPU work from background apps on iPhone. Takes effect at the next `compute` scope.
    func useCPU(_ on: Bool) { RunLog.add("control: device -> \(on ? "CPU" : "GPU")"); lock.lock(); cpu = on; lock.unlock() }
    var usesCPU: Bool { lock.lock(); defer { lock.unlock() }; return cpu }
    /// Runs one unit of work (a layer, a decoder stage) on the currently selected device. Callers evaluate
    /// their results inside the closure, so no lazy GPU work is left pending when the device changes.
    func compute<R>(_ body: () throws -> R) rethrows -> R {
        if usesCPU { return try Device.withDefaultDevice(Device(.cpu), body) }
        return try body()
    }
    func resume() { lock.lock(); paused = false; lock.unlock() }
    func check() throws {
        lock.lock(); let error = stopped; let isPaused = paused; lock.unlock()
        if let error { throw error }
        if isPaused {
            RunLog.add("control: paused (Moss is not on screen)")
            pauseChanged?(true)
            while true {
                lock.lock(); let cancelled = stopped; let still = paused; lock.unlock()
                if let cancelled { throw cancelled }
                if !still { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            RunLog.add("control: resumed")
            pauseChanged?(false)
        }
        #if os(iOS)
        // Only a real shortage on screen ends the run. In the background iOS reports a much smaller
        // allowance (and sends memory warnings) even though the run can safely continue or pause, so it is
        // never treated as an error there.
        if trimRequested { Memory.clearCache(); lock.lock(); trimRequested = false; lock.unlock() }
        let available = os_proc_available_memory()
        if onScreen && available > 0 && available < 96 * 1024 * 1024 { RunLog.add("control: only \(available >> 20) MB memory left"); throw MossError.memory }
        #endif
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical {
            // Visible pause: the countdown stops and the card says the iPhone is cooling down.
            RunLog.add("control: iPhone critically hot, waiting")
            coolingChanged?(true)
            while ProcessInfo.processInfo.thermalState == .critical {
                lock.lock(); let cancelled = stopped; lock.unlock()
                if let cancelled { coolingChanged?(false); throw cancelled }; Thread.sleep(forTimeInterval:0.5)
            }
            coolingChanged?(false)
        } else if thermal == .serious {
            if !announcedHeat { notice?("iPhone is warm, so Moss is running a little slower."); announcedHeat = true }
            Thread.sleep(forTimeInterval:0.05)
        } else { announcedHeat = false }
    }
}
