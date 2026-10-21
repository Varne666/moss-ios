import Foundation
import MLX

/// MOSS-Image diffusion transformer (42 joint blocks, 24×128 heads, 8-bit g64 MLX export).
///
/// Weights for the 42 blocks are streamed from storage one layer at a time. Each layer is read once per
/// sampling step and applied to every guidance branch before the next layer is read, so a guided step reads
/// the ~5.05 GB of block weights once instead of twice. Non-layer weights (~0.44 GB) stay resident for the
/// whole generation, and the text embedder output and RoPE tables are computed once per branch, because
/// neither depends on the timestep or the latent.
final class MossTransformer {
    struct Branch {
        let text: MLXArray
        let rope: (MLXArray, MLXArray)
        let skipped: Set<Int>
    }
    static let layerCount = 42, heads = 24, headDim = 128, hidden = 3072, ffn = 8192, latentChannels = 128

    let store: TensorStore
    let adapter: TensorStore?
    let control: RunControl
    private let base: Weights

    init(store: TensorStore, adapter: TensorStore?, control: RunControl) throws {
        self.store = store; self.adapter = adapter; self.control = control
        base = try store.load(prefix: "", excluding: "layers.")
        try Self.checkLayout(store)
    }

    /// Fails early, with a readable message, if the checkpoint is not the 8-bit g64 export this code expects.
    private static func checkLayout(_ store: TensorStore) throws {
        func shape(_ name: String) -> [Int]? { store.entries[name]?.shape }
        let expected: [(String, [Int])] = [
            ("layers.0.proj.q.weight", [hidden, hidden * 8 / 32]),
            ("layers.0.proj.q.scales", [hidden, hidden / 64]),
            ("layers.0.proj.ffn_up_gate.weight", [2 * ffn, hidden * 8 / 32]),
            ("layers.0.proj.ffn_down.weight", [hidden, ffn * 8 / 32]),
            ("layers.\(layerCount - 1).proj.o.weight", [hidden, hidden * 8 / 32]),
            ("layers.0.q_norm.weight", [headDim]),
        ]
        for (name, value) in expected where shape(name) != value {
            throw MossError.model("The image model files do not match this version of Moss (\(name)). Re-download the model.")
        }
        guard shape("layers.\(layerCount).proj.q.weight") == nil else {
            throw MossError.model("The image model has more layers than this version of Moss supports.")
        }
    }

    private func rope(height: Int, width: Int, text: Int) -> (MLXArray, MLXArray) {
        var sine: [Float] = [], cosine: [Float] = []
        sine.reserveCapacity((height * width + text) * 128); cosine.reserveCapacity((height * width + text) * 128)
        for i in 0..<(height * width + text) {
            let image = i < height * width
            let coords: [Float] = image
                ? [0, Float(text), Float(i / width) - Float(height - 1) / 2, Float(i % width) - Float(width - 1) / 2]
                : [0, Float(i - height * width), 0, 0]
            var s: [Float] = [], c: [Float] = []
            for coordinate in coords { for j in 0..<16 { let phase = coordinate / powf(10000, Float(j) / 16); s.append(sinf(phase)); c.append(cosf(phase)) } }
            sine += s + s; cosine += c + c
        }
        let shape = [1, height * width + text, 1, 128]
        return (MLXArray(sine, shape).asType(.bfloat16), MLXArray(cosine, shape).asType(.bfloat16))
    }

    private func attention(_ q: MLXArray, _ k: MLXArray, _ v: MLXArray, _ rope: (MLXArray, MLXArray)) -> MLXArray {
        let n = q.shape[1]
        func rotate(_ a: MLXArray) -> MLXArray {
            let x = a.reshaped([1, n, Self.heads, Self.headDim])
            let r = concatenated([-x[0..., 0..., 0..., 64..<128], x[0..., 0..., 0..., 0..<64]], axis: -1)
            return (x * rope.1 + r * rope.0).transposed(0, 2, 1, 3)
        }
        let queries = rotate(q), keys = rotate(k)
        let values = v.reshaped([1, n, Self.heads, Self.headDim]).transposed(0, 2, 1, 3)
        let scale = 1 / sqrtf(Float(Self.headDim))
        let out: MLXArray
        if control.usesCPU {
            // The CPU path materialises the full score matrix, so split the queries to bound memory.
            var parts: [MLXArray] = []
            for start in stride(from: 0, to: n, by: 512) {
                let chunk = queries[0..., 0..., start..<min(start + 512, n), 0...]
                let part = MLXFast.scaledDotProductAttention(queries: chunk, keys: keys, values: values, scale: scale, mask: MLXFast.ScaledDotProductAttentionMaskMode.none)
                eval(part); parts.append(part)
            }
            out = concatenated(parts, axis: 2)
        } else {
            out = MLXFast.scaledDotProductAttention(queries: queries, keys: keys, values: values, scale: scale, mask: MLXFast.ScaledDotProductAttentionMaskMode.none, forceFused: true)
        }
        return out.transposed(0, 2, 1, 3).reshaped([1, n, Self.hidden])
    }

    private func headNorm(_ x: MLXArray, _ w: Weights, _ name: String) throws -> MLXArray {
        try w.norm(x.reshaped([1, x.shape[1], Self.heads, Self.headDim]), name).reshaped(x.shape)
    }

    /// Text embedder output and RoPE tables for one guidance branch. Independent of the timestep and latent.
    func prepare(context: MLXArray, height: Int, width: Int, skipped: Set<Int>) throws -> Branch {
        try control.compute { try prepareBody(context: context, height: height, width: width, skipped: skipped) }
    }
    private func prepareBody(context: MLXArray, height: Int, width: Int, skipped: Set<Int>) throws -> Branch {
        let count = height * width
        let r = rope(height: height, width: width, text: context.shape[1])
        let tr = (r.0[0..., count..., 0..., 0...], r.1[0..., count..., 0..., 0...])
        var text = try base.linear(context, "text_embedder.proj", bits: 8)
        for i in 0..<2 {
            let p = "text_embedder.blocks.\(i)."
            let y = try base.norm(text, p + "norm1")
            let qkv = try base.linear(y, p + "qkv", bits: 8)
            let q = try headNorm(qkv[0..., 0..., 0..<3072], base, p + "q_norm")
            let k = try headNorm(qkv[0..., 0..., 3072..<6144], base, p + "k_norm")
            text = try text + base.linear(attention(q, k, qkv[0..., 0..., 6144..<9216], tr), p + "proj", bits: 8)
            let h = try base.norm(text, p + "norm2")
            let up = try base.linear(h, p + "ffn_up", bits: 8), gate = try base.linear(h, p + "ffn_gate", bits: 8)
            text = try text + base.linear(mossSitu(up, gate), p + "ffn_down", bits: 8)
        }
        eval(text, r.0, r.1)
        return Branch(text: text, rope: r, skipped: skipped)
    }

    private func block(_ x: MLXArray, _ w: Weights, _ a: Weights?, _ rope: (MLXArray, MLXArray), _ mod: MLXArray) throws -> MLXArray {
        let y = try w.norm(x, "norm1") * (1 + mod[0..., 1..<2, 0...]) + mod[0..., 0..<1, 0...]
        let q = try headNorm(w.linear(y, "proj.q", bits: 8, adapter: a), w, "q_norm")
        let k = try headNorm(w.linear(y, "proj.k", bits: 8, adapter: a), w, "k_norm")
        let v = try w.linear(y, "proj.v", bits: 8, adapter: a)
        let h = try x + w.linear(attention(q, k, v, rope), "proj.o", bits: 8, adapter: a) * mod[0..., 2..<3, 0...]
        let z = try w.norm(h, "norm2") * (1 + mod[0..., 4..<5, 0...]) + mod[0..., 3..<4, 0...]
        let hg = try w.linear(z, "proj.ffn_up_gate", bits: 8, adapter: a)
        return try h + w.linear(mossSitu(hg[0..., 0..., 0..<Self.ffn], hg[0..., 0..., Self.ffn..<(2 * Self.ffn)]), "proj.ffn_down", bits: 8, adapter: a) * mod[0..., 5..<6, 0...]
    }

    /// One velocity prediction per branch for the shared latent at `time` (σ × 1000). Returns FP32 [1,128,H,W].
    func predict(_ latent: MLXArray, time: Float, branches: [Branch]) throws -> [MLXArray] {
        let height = latent.shape[2], width = latent.shape[3], count = height * width
        let (mod, head, video) = try control.compute { () throws -> (MLXArray, MLXArray, MLXArray) in
        var embedding: [Float] = []
        let angles = (0..<128).map { Double(time) * pow(10000.0, -Double($0) / 128) }
        embedding += angles.map { Float(cos($0)) }; embedding += angles.map { Float(sin($0)) }
        let time0 = try base.linear(MLXArray(embedding, [1, 256]).asType(.bfloat16), "time_embedding.0", bits: 8)
        let t = try base.linear(mossSilu(time0), "time_embedding.1", bits: 8)
        let mod = try base.linear(t, "shared_block_modulation", bits: 8).reshaped([1, 6, Self.hidden])
        let head = try base.linear(t, "video_head_modulation", bits: 8).reshaped([1, 2, Self.hidden])
        let video = try base.linear(latent.reshaped([1, Self.latentChannels, count]).transposed(0, 2, 1).asType(.bfloat16), "video_embedder", bits: 8)
        eval(mod, head, video); return (mod, head, video)
        }
        var states = try control.compute { () -> [MLXArray] in
            let s = branches.map { concatenated([video, $0.text], axis: 1) }; eval(s); return s
        }
        for i in 0..<Self.layerCount {
            try control.check()
            let active = branches.indices.filter { !branches[$0].skipped.contains(i) }
            if active.isEmpty { continue }
            try autoreleasepool {
                let w = try store.load(prefix: "layers.\(i).")
                let a = try adapter?.load(prefix: "diffusion_model.layers.\(i).")
                for b in active {
                    states[b] = try control.compute {
                        let next = try block(states[b], w, a, branches[b].rope, mod); eval(next); return next
                    }
                }
            }
            Memory.clearCache()
        }
        return try states.map { x in try control.compute {
            let normalized = try base.norm(x[0..., 0..<count, 0...], "final_norm_video")
            let y = normalized * (1 + head[0..., 1..<2, 0...]) + head[0..., 0..<1, 0...]
            let out = try base.linear(y, "final_linear_video", bits: 8).transposed(0, 2, 1)
                .reshaped([1, Self.latentChannels, height, width]).asType(.float32)
            eval(out); return out
        } }
    }
}
