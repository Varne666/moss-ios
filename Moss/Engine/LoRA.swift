import Foundation
import MLX

/// One projection's low-rank update for one block: y += scale · (x · downᵀ) · upᵀ, computed in FP32.
struct LoRADelta {
    let down: MLXArray
    let up: MLXArray
    let scale: Float
}

/// A LoRA file mapped onto the transformer block projections (proj.q/k/v/o/ffn_up_gate/ffn_down).
///
/// Accepts the layouts MOSS-Image LoRAs ship in: ComfyUI/kohya (`lora_down`/`lora_up`/`alpha`), PEFT
/// (`lora_A`/`lora_B`), optional `diffusion_model.` / `transformer.` / `base_model.model.` prefixes, kohya
/// underscore names, and LoRAs trained on the reference model's fused `proj.qkv`, which are split into q, k, v.
/// Updates are applied unmerged, as the model authors recommend.
final class LoRAFile {
    struct Target { let down: String; let up: String; let alpha: String?; let rows: Range<Int>? }
    static let projections = ["q", "k", "v", "o", "qkv", "ffn_up_gate", "ffn_down"]

    let name: String
    let strength: Float
    private let store: TensorStore
    private(set) var targets: [Int: [String: Target]] = [:]
    /// Tensors that are not block projections (for example text-embedder layers); not applied.
    private(set) var ignored = 0
    var layerCount: Int { targets.count }
    var rank: Int? {
        guard let first = targets.values.first?.values.first else { return nil }
        return try? store.shape(first.down).first
    }

    init(url: URL, name: String, strength: Float, hidden: Int = 3072) throws {
        self.name = name; self.strength = strength
        store = try TensorStore(files: [url])
        var parts: [Int: [String: (down: String?, up: String?, alpha: String?)]] = [:]
        for key in store.entries.keys {
            guard let (layer, proj, kind) = Self.parse(key) else { ignored += 1; continue }
            var entry = parts[layer, default: [:]][proj] ?? (nil, nil, nil)
            switch kind {
            case "down": entry.down = key
            case "up": entry.up = key
            default: entry.alpha = key
            }
            parts[layer, default: [:]][proj] = entry
        }
        for (layer, projs) in parts {
            for (proj, e) in projs {
                guard let down = e.down, let up = e.up else { ignored += 1; continue }
                if proj == "qkv" {
                    for (i, name) in ["q", "k", "v"].enumerated() {
                        targets[layer, default: [:]]["proj." + name] = Target(down: down, up: up, alpha: e.alpha, rows: (i * hidden)..<((i + 1) * hidden))
                    }
                } else {
                    targets[layer, default: [:]]["proj." + proj] = Target(down: down, up: up, alpha: e.alpha, rows: nil)
                }
            }
        }
        guard !targets.isEmpty else {
            throw MossError.model("\(name) doesn't contain MOSS-Image LoRA layers, so it can't be used with Moss.")
        }
        guard targets.keys.allSatisfy({ (0..<MossTransformer.layerCount).contains($0) }) else {
            throw MossError.model("\(name) was made for a different model (it has more than 42 layers).")
        }
    }

    /// (layer, projection, "down" | "up" | "alpha") for a recognised key.
    static func parse(_ raw: String) -> (Int, String, String)? {
        var key = raw
        for prefix in ["base_model.model.", "model.diffusion_model.", "diffusion_model.", "transformer.", "unet."] where key.hasPrefix(prefix) {
            key.removeFirst(prefix.count)
        }
        if key.hasPrefix("lora_unet_layers_") {
            // kohya: lora_unet_layers_12_proj_ffn_up_gate.lora_down.weight
            let rest = key.dropFirst("lora_unet_layers_".count)
            guard let underscore = rest.firstIndex(of: "_"), let layer = Int(rest[..<underscore]) else { return nil }
            let tail = rest[rest.index(after: underscore)...]
            guard tail.hasPrefix("proj_"), let dot = tail.firstIndex(of: ".") else { return nil }
            let proj = String(tail[tail.index(tail.startIndex, offsetBy: 5)..<dot])
            return kind(String(tail[tail.index(after: dot)...])).flatMap { projections.contains(proj) ? (layer, proj, $0) : nil }
        }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, parts[0] == "layers", let layer = Int(parts[1]), parts[2] == "proj", projections.contains(parts[3]) else { return nil }
        return kind(parts[4...].joined(separator: ".")).map { (layer, parts[3], $0) }
    }
    private static func kind(_ suffix: String) -> String? {
        switch suffix {
        case "lora_down.weight", "lora_A.weight", "lora_A.default.weight": return "down"
        case "lora_up.weight", "lora_B.weight", "lora_B.default.weight": return "up"
        case "alpha": return "alpha"
        default: return nil
        }
    }

    /// Updates for one block, read from storage.
    func deltas(layer: Int) throws -> [String: LoRADelta] {
        guard let projs = targets[layer] else { return [:] }
        var out: [String: LoRADelta] = [:]
        var cache: [String: MLXArray] = [:]
        func read(_ key: String) throws -> MLXArray {
            if let hit = cache[key] { return hit }
            let value = try store.read(key); cache[key] = value; return value
        }
        for (proj, t) in projs {
            let down = try read(t.down)
            var up = try read(t.up)
            if let rows = t.rows { up = up[rows.lowerBound..<rows.upperBound] }
            let rank = Float(down.shape[0])
            let alpha = try t.alpha.map { try read($0).asType(.float32).item(Float.self) } ?? rank
            out[proj] = LoRADelta(down: down, up: up, scale: strength * alpha / rank)
        }
        return out
    }
}
