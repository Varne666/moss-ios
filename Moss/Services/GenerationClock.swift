import Foundation

/// Estimates how long the current image still needs, from this run's own measured stage timings and from
/// timings this iPhone recorded on earlier images (scaled to the new image's size, step count and guidance).
/// It never invents a number: before any measurement exists it returns nil and the UI says "Estimating".
struct GenerationClock {
    /// Work of one sampling step, in "token passes": image+text tokens × transformer branches (×1.2 with the
    /// unmerged Fast adapter, which adds ~1.19 GB of weights per pass).
    struct Plan: Codable, Equatable {
        var imageTokens: Int
        var steps: Int
        var branches: Int
        var adapter: Bool
        var prompts: Int
        var pixels: Int
        init(settings s: GenerationSettings) {
            imageTokens = (s.width / 16) * (s.height / 16)
            steps = max(1, s.steps)
            branches = s.guidance != 1 ? 2 : 1
            adapter = s.quality == .fast
            prompts = branches
            pixels = s.width * s.height
        }
        var stepWork: Double { Double(branches) * Double(imageTokens + 64) * (adapter ? 1.2 : 1) }
    }
    /// Per-device history, persisted between launches.
    struct Calibration: Codable, Equatable {
        struct Sample: Codable, Equatable { var work: Double; var seconds: Double }
        var encode: [Int: Double] = [:]          // prompts → seconds for the whole text encoder pass
        var prepare: Double?
        var steps: [Sample] = []                  // most recent runs, one median step each
        var decodePerMegapixel: Double?

        static let key = "generationCalibration.v1"
        static func load(_ defaults: UserDefaults = .standard) -> Calibration {
            guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(Calibration.self, from: data) else { return Calibration() }
            return value
        }
        func save(_ defaults: UserDefaults = .standard) { if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) } }

        /// Seconds per step for `work`, from a least-squares line through past samples (fixed storage-read cost
        /// plus a per-token cost). With one sample, assumes half the time is fixed cost.
        func stepSeconds(work: Double) -> Double? {
            guard !steps.isEmpty else { return nil }
            let xs = steps.map(\.work), ys = steps.map(\.seconds)
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
            if steps.count >= 2, sxx > mx * mx * 0.01 {
                let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
                let intercept = my - slope * mx
                if slope > 0, intercept >= 0 { return intercept + slope * work }
            }
            let last = steps[steps.count - 1]
            return last.seconds * (0.5 + 0.5 * work / max(1, last.work))
        }
    }

    let plan: Plan
    private(set) var calibration: Calibration
    private var current = GenerationProgress(message: "")
    private var stageStart: [GenerationProgress.Stage: TimeInterval] = [:]
    private var stageEnd: [GenerationProgress.Stage: TimeInterval] = [:]
    private var stepDurations: [Double] = []
    private var lastStepMark: TimeInterval?
    private var decodeMarks: [TimeInterval] = []
    private var pausedAt: TimeInterval?
    private var pausedTotal: TimeInterval = 0
    private var encodeMarks: [TimeInterval] = []

    init(plan: Plan, calibration: Calibration) { self.plan = plan; self.calibration = calibration }

    /// Monotonic run time excluding pauses.
    private func clock(_ now: TimeInterval) -> TimeInterval { now - pausedTotal - (pausedAt.map { now - $0 } ?? 0) }

    mutating func pause(at now: TimeInterval) { if pausedAt == nil { pausedAt = now } }
    mutating func resume(at now: TimeInterval) { if let p = pausedAt { pausedTotal += now - p; pausedAt = nil } }
    var paused: Bool { pausedAt != nil }

    mutating func record(_ p: GenerationProgress, at now: TimeInterval) {
        let t = clock(now)
        if p.stage != current.stage {
            stageEnd[current.stage] = t
            stageStart[p.stage] = t
        }
        switch p.stage {
        case .encode: encodeMarks.append(t)
        case .sample:
            if p.stage == current.stage, p.index > current.index, let mark = lastStepMark {
                stepDurations.append((t - mark) / Double(p.index - current.index))
            }
            lastStepMark = t
        case .decode: decodeMarks.append(t)
        default: break
        }
        current = p
    }

    /// Typical recent step time from this run. The first step includes one-off GPU kernel set-up, so it is
    /// dropped once later steps exist.
    private var measuredStep: Double? {
        let usable = stepDurations.count >= 2 ? Array(stepDurations.dropFirst()) : stepDurations
        guard !usable.isEmpty else { return nil }
        let recent = usable.suffix(6).sorted()
        return recent[recent.count / 2]
    }
    private var predictedStep: Double? { measuredStep ?? calibration.stepSeconds(work: plan.stepWork) }
    private var predictedDecode: Double? {
        if let perMP = calibration.decodePerMegapixel { return perMP * Double(plan.pixels) / 1_000_000 }
        return predictedStep.map { $0 * 0.6 }
    }

    /// Seconds still needed, or nil while there is nothing measured to base it on.
    func remaining(at now: TimeInterval) -> Double? {
        let t = clock(now)
        guard let step = predictedStep else {
            // No step time yet: only the text-encoder stage can be timed from its own layers.
            return nil
        }
        let decode = predictedDecode ?? step * 0.6
        let sampling = { (doneSteps: Int, sinceMark: Double) in max(0, Double(plan.steps - doneSteps) * step - sinceMark) }
        switch current.stage {
        case .starting:
            guard let encode = calibration.encode[plan.prompts] else { return nil }
            return encode + (calibration.prepare ?? 0) + sampling(0, 0) + decode
        case .encode:
            let done = current.index
            var encodeLeft: Double?
            if done >= 2, let first = encodeMarks.first { encodeLeft = (t - first) / Double(done) * Double(32 - done) }
            else if let total = calibration.encode[plan.prompts], let start = stageStart[.encode] { encodeLeft = max(0, total - (t - start)) }
            guard let left = encodeLeft else { return nil }
            return left + (calibration.prepare ?? 0) + sampling(0, 0) + decode
        case .prepare:
            let since = stageStart[.prepare].map { t - $0 } ?? 0
            return max(0, (calibration.prepare ?? 0) - since) + sampling(0, 0) + decode
        case .sample:
            let since = lastStepMark.map { t - $0 } ?? 0
            return sampling(current.index, since) + decode
        case .decode:
            let since = stageStart[.decode].map { t - $0 } ?? 0
            return max(1, decode - since)
        case .done: return 0
        }
    }

    /// Overall completion between 0 and 1, consistent with `remaining`.
    func fraction(at now: TimeInterval) -> Double? {
        guard let left = remaining(at: now) else { return nil }
        let elapsed = clock(now) - (stageStart[.encode] ?? stageStart[.starting] ?? 0)
        let total = elapsed + left
        return total > 0 ? min(1, max(0, elapsed / total)) : nil
    }

    /// Stores this run's measured stage times so the next image can be estimated before it starts.
    func calibrated() -> Calibration {
        var c = calibration
        if let s = stageStart[.encode], let e = stageEnd[.encode] ?? stageStart[.prepare] { c.encode[plan.prompts] = e - s }
        if let s = stageStart[.prepare], let e = stageEnd[.prepare] ?? stageStart[.sample] { c.prepare = e - s }
        if let step = measuredStep {
            c.steps.append(.init(work: plan.stepWork, seconds: step))
            c.steps = Array(c.steps.suffix(8))
        }
        if let s = stageStart[.decode], let e = stageEnd[.decode], e > s { c.decodePerMegapixel = (e - s) / (Double(plan.pixels) / 1_000_000) }
        return c
    }
}
