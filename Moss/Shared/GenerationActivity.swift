#if os(iOS)
import ActivityKit
import Foundation

/// Shared by the app and the MossActivity widget extension (Dynamic Island and Lock Screen).
struct GenerationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable { case estimating, running, paused, finished, failed }
        var phase: Phase
        /// Short status, e.g. "Step 3 of 8" or "Finishing the image".
        var detail: String
        /// When the estimate says the image will be done; the views count down to it on their own.
        var start: Date
        var end: Date?
        /// Completion when `end` is unknown or the run is paused (0...1).
        var fraction: Double
    }
    var size: String       // "1024 × 1024"
    var quality: String    // "Fast"
}
#endif
