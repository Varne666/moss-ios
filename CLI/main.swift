// MossCLI — macOS harness that runs the exact iOS engine sources (Moss/Engine) against the real weights.
// Used by CI to validate inference on Apple silicon; it is not shipped in the iPhone app.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MLX
import Darwin

func footprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

final class PeakSampler {
    private(set) var peak: UInt64 = 0
    private var timer: DispatchSourceTimer?
    func start() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "peak"))
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in guard let self else { return }; self.peak = max(self.peak, footprintBytes()) }
        t.resume(); timer = t
    }
}

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }
func gib(_ bytes: UInt64) -> String { String(format: "%.2f GiB", Double(bytes) / 1_073_741_824) }

if flag("--selftest") {
    let a = MLXRandom.normal([512, 512]), b = MLXRandom.normal([512, 512])
    let c = matmul(a, b).sum(); eval(c)
    print("MLX selftest OK on \(Device.defaultDevice()) result=\(c.item(Float.self))")
    exit(0)
}

if let source = argument("--convert-kromoss"), let modelPath = argument("--models"), let manifestPath = argument("--manifest") {
    do {
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        guard let file = manifest.files.first(where: { $0.component == "kromoss" }) else { print("FAILED: manifest has no kromoss entry"); exit(1) }
        let start = Date(); let sampler = PeakSampler(); sampler.start()
        try KromossConverter.convert(source: URL(fileURLWithPath: source), into: URL(fileURLWithPath: modelPath).appendingPathComponent("kromoss"), sourceSHA: file.sha256) { done, total in
            if done % 6 == 0 || done == total { print(String(format: "converted %d/%d  %.0fs  footprint=%@", done, total, Date().timeIntervalSince(start), gib(footprintBytes()))) }
        }
        print(String(format: "CONVERTED in %.0fs, peak footprint %@", Date().timeIntervalSince(start), gib(sampler.peak)))
        exit(0)
    } catch { print("FAILED: \(error.localizedDescription)"); exit(1) }
}

guard let modelPath = argument("--models"), let manifestPath = argument("--manifest"), let outPath = argument("--out") else {
    print("usage: MossCLI --models DIR --manifest model-manifest.json --out image.png [--prompt TEXT] [--negative TEXT] [--width N] [--height N] [--preset fast|balanced|best] [--steps N] [--guidance G] [--shift S] [--seed N] [--no-skip]")
    exit(2)
}
do {
    let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
    var s = GenerationSettings()
    s.preset(Quality(rawValue: (argument("--preset") ?? "best").capitalized) ?? .best)
    s.prompt = argument("--prompt") ?? "A red fox sitting in fresh snow, golden hour, photograph"
    s.negativePrompt = argument("--negative") ?? ""
    s.width = Int(argument("--width") ?? "") ?? 512
    s.height = Int(argument("--height") ?? "") ?? 512
    if let v = argument("--steps").flatMap(Int.init) { s.steps = v }
    if let v = argument("--guidance").flatMap(Float.init) { s.guidance = v }
    if let v = argument("--shift").flatMap(Float.init) { s.shift = v }
    s.seed = UInt32(argument("--seed") ?? "") ?? 42
    if flag("--no-skip") { s.skipLayer = false }
    if argument("--model") == "kromoss" { s.model = .kromoss }
    if flag("--snapshot") { s.snapshotStyle = true }
    // --lora /path/file.safetensors:0.8 (repeatable)
    var userLoRAs: [(url: URL, name: String, strength: Float)] = []
    for (i, a) in CommandLine.arguments.enumerated() where a == "--lora" && i + 1 < CommandLine.arguments.count {
        let spec = CommandLine.arguments[i + 1]; let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        userLoRAs.append((URL(fileURLWithPath: parts[0]), URL(fileURLWithPath: parts[0]).lastPathComponent, parts.count > 1 ? Float(parts[1]) ?? 1 : 1))
    }
    print("model: \(s.model.rawValue) snapshot=\(s.snapshotStyle) loras=\(userLoRAs.map { "\($0.name)@\($0.strength)" })")
    print("settings: \(s.width)x\(s.height) quality=\(s.quality.rawValue) steps=\(s.steps) guidance=\(s.guidance) shift=\(s.shift) skip22=\(s.skipLayer) seed=\(s.seed)")
    print("prompt: \(s.prompt)")
    let sampler = PeakSampler(); sampler.start()
    let control = RunControl()
    // --cpu-steps A-B runs sampling steps A..B (1-based) on the CPU, as the iPhone app does in the background.
    let cpuRange: ClosedRange<Int>? = argument("--cpu-steps").flatMap { text in
        let parts = text.split(separator: "-").compactMap { Int($0) }; return parts.count == 2 ? parts[0]...parts[1] : nil }
    let start = Date()
    var last = Date()
    let image = try MossPipeline().generate(settings: s, folder: URL(fileURLWithPath: modelPath), manifest: manifest, control: control, userLoRAs: userLoRAs) { p in
        let now = Date()
        if let cpuRange, p.stage == .sample {
            let cpu = cpuRange.contains(p.index + 1)
            if cpu != control.usesCPU { control.useCPU(cpu); print("device -> \(cpu ? "CPU" : "GPU") before step \(p.index + 1)") }
        }
        print(String(format: "[%7.1fs +%6.1fs] %@ footprint=%@", now.timeIntervalSince(start), now.timeIntervalSince(last), p.message, gib(footprintBytes())))
        last = now
    }
    let total = Date().timeIntervalSince(start)
    let url = URL(fileURLWithPath: outPath) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { throw MossError.model("Cannot write PNG") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw MossError.model("Cannot finalize PNG") }
    print(String(format: "DONE total=%.1fs", total))
    print("peak process footprint (50 ms sampling): \(gib(sampler.peak))")
    print("layer cache budget: \(ProcessInfo.processInfo.environment["MOSS_LAYER_CACHE_MB"] ?? "0") MB")
    print("MLX peak active memory: \(gib(UInt64(Memory.peakMemory)))")
} catch {
    print("FAILED: \(error.localizedDescription)")
    exit(1)
}
