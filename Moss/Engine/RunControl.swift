import Foundation
import UIKit
import os

final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped: MossError?
    private var announcedHeat = false
    var notice: ((String) -> Void)?
    func cancel(_ reason: MossError = .cancelled) { lock.lock(); stopped = reason; lock.unlock() }
    func check() throws {
        lock.lock(); let error = stopped; lock.unlock()
        if let error { throw error }
        let available = os_proc_available_memory()
        if available > 0 && available < 256 * 1024 * 1024 { throw MossError.memory }
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
