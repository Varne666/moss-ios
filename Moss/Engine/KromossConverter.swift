import Foundation
import MLX

/// Turns the original Kromoss checkpoint (bf16, ComfyUI layout, Apache-2.0) into the 8-bit g64 layout the engine
/// streams, on the device, one block at a time: same scheme as the MOSS-Image-Base 8-bit export (fused proj.qkv
/// split into q/k/v; conditioning layers kept bf16; every other linear quantized affine 8-bit, group 64).
enum KromossConverter {
    static let keepBF16 = ["video_embedder", "time_embedding", "shared_block_modulation", "video_head_modulation",
                           "final_linear_video", "text_embedder.proj"]
    static let marker = "converted.json"

    struct Marker: Codable { var source: String; var files: [String: Int64] }

    /// Files of a finished conversion in `folder`, or nil if it is missing or incomplete.
    static func converted(in folder: URL, sourceSHA: String) -> [URL]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(marker)),
              let m = try? JSONDecoder().decode(Marker.self, from: data), m.source == sourceSHA, !m.files.isEmpty else { return nil }
        var urls: [URL] = []
        for (name, bytes) in m.files.sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent(name)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == bytes else { return nil }
            urls.append(url)
        }
        return urls
    }

    /// Converts `source` into `folder` (base.safetensors + layer-NN.safetensors + marker). `progress(done, total)`.
    static func convert(source: URL, into folder: URL, sourceSHA: String, control: RunControl? = nil,
                        progress: (Int, Int) -> Void) throws {
        let store = try TensorStore(files: [source])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(marker))
        var groups: [String: [String]] = [:]
        for name in store.entries.keys where name != "rope.bands" {
            let group = name.hasPrefix("layers.") ? "layer-" + String(format: "%02d", Int(name.split(separator: ".")[1]) ?? 0) : "base"
            groups[group, default: []].append(name)
        }
        guard groups.count == MossTransformer.layerCount + 1, store.entries["layers.0.proj.qkv.weight"] != nil else {
            throw MossError.model("This file is not the Kromoss checkpoint Moss expects. Delete it and download again.")
        }
        var written: [String: Int64] = [:]
        for (index, group) in groups.keys.sorted().enumerated() {
            try control?.check()
            try autoreleasepool {
                var out: [String: MLXArray] = [:]
                for name in groups[group]!.sorted() {
                    let value = try store.read(name)
                    let key = name.replacingOccurrences(of: "time_embedding.2.", with: "time_embedding.1.")
                    if key.hasSuffix(".proj.qkv.weight") {
                        let stem = String(key.dropLast("qkv.weight".count)), d = value.shape[0] / 3
                        for (i, part) in ["q", "k", "v"].enumerated() { quantize(value[(i * d)..<((i + 1) * d)], as: stem + part, into: &out) }
                    } else if key.hasSuffix(".weight"), value.ndim == 2, value.shape[1] % 64 == 0, !keepBF16.contains(where: { key.hasPrefix($0) }) {
                        quantize(value, as: String(key.dropLast(".weight".count)), into: &out)
                    } else {
                        out[key] = value
                    }
                }
                eval(Array(out.values))
                let file = group + ".safetensors", tmp = folder.appendingPathComponent(group + ".partial.safetensors")
                try save(arrays: out, metadata: ["format": "mlx"], url: tmp)
                let final = folder.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: final)
                try FileManager.default.moveItem(at: tmp, to: final)
                written[file] = Int64(try final.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            Memory.clearCache()
            progress(index + 1, groups.count)
        }
        let data = try JSONEncoder().encode(Marker(source: sourceSHA, files: written))
        try data.write(to: folder.appendingPathComponent(marker), options: .atomic)
    }

    private static func quantize(_ w: MLXArray, as stem: String, into out: inout [String: MLXArray]) {
        let q = quantized(w, groupSize: 64, bits: 8)
        out[stem + ".weight"] = q.wq
        out[stem + ".scales"] = q.scales
        if let biases = q.biases as MLXArray? { out[stem + ".biases"] = biases }
    }
}
