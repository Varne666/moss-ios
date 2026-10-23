import Foundation

/// Timestamped diagnostics for the current and previous runs (generation, downloads, conversion).
/// The iPhone app writes it to Application Support so Settings → Diagnostics can show and share it;
/// the macOS harness prints it. Keeps the newest ~600 lines.
enum RunLog {
    private static let lock = NSLock()
    private static var lines: [String] = []
    private static var loaded = false
    /// Set by the app at launch. Nil (the CLI) prints to standard output instead.
    static var file: URL?
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    static func add(_ text: String) {
        let line = "\(stamp.string(from: Date())) \(text)"
        lock.lock(); defer { lock.unlock() }
        guard let file else { print("log: " + line); return }
        if !loaded {
            loaded = true
            if let saved = try? String(contentsOf: file, encoding: .utf8) { lines = saved.split(separator: "\n").map(String.init) }
        }
        lines.append(line)
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    static var text: String {
        lock.lock(); defer { lock.unlock() }
        if !loaded, let file, let saved = try? String(contentsOf: file, encoding: .utf8) { lines = saved.split(separator: "\n").map(String.init); loaded = true }
        return lines.joined(separator: "\n")
    }
    static var last: String? { lock.lock(); defer { lock.unlock() }; return lines.last }
    static func clear() { lock.lock(); lines = []; if let file { try? FileManager.default.removeItem(at: file) }; lock.unlock() }
}
