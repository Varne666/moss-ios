import Foundation
import os

final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped: MossError?
    private var announcedHeat = false
    private var paused = false
    var notice: ((String) -> Void)?
    /// Called on the worker thread when a pause takes effect (true) and when work resumes (false).
    var pauseChanged: ((Bool) -> Void)?
    func cancel(_ reason: MossError = .cancelled) { lock.lock(); stopped = reason; lock.unlock() }
    /// iOS forbids GPU work while the app is in the background, so generation waits at the next layer
    /// boundary until Moss is on screen again instead of being cancelled.
    func pause() { lock.lock(); paused = true; lock.unlock() }
    func resume() { lock.lock(); paused = false; lock.unlock() }
    func check() throws {
        lock.lock(); let error = stopped; let isPaused = paused; lock.unlock()
        if let error { throw error }
        if isPaused {
            pauseChanged?(true)
            while true {
                lock.lock(); let cancelled = stopped; let still = paused; lock.unlock()
                if let cancelled { throw cancelled }
                if !still { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            pauseChanged?(false)
        }
        #if os(iOS)
        let available = os_proc_available_memory()
        if available > 0 && available < 256 * 1024 * 1024 { throw MossError.memory }
        #endif
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical {
            notice?("iPhone needs to cool down. Paused; keep Moss open.")
            while ProcessInfo.processInfo.thermalState == .critical {
                lock.lock(); let cancelled = stopped; lock.unlock()
                if let cancelled { throw cancelled }; Thread.sleep(forTimeInterval:0.5)
            }
        } else if thermal == .serious {
            if !announcedHeat { notice?("iPhone is warm. Slowing down to let it cool."); announcedHeat = true }
            Thread.sleep(forTimeInterval:0.15)
        } else { announcedHeat = false }
    }
}
