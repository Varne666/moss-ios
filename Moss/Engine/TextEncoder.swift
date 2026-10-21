import Foundation
import MLX

/// Qwen3.5-9B's text-only final hidden states. One layer is resident at a time.
final class MossTextEncoder {
    let store: TensorStore
    let control: RunControl
    let progress: (Int) -> Void
    init(store: TensorStore, control: RunControl, progress: @escaping (Int) -> Void) {
        self.store = store; self.control = control; self.progress = progress
    }
    /// Final-norm hidden states for each prompt. Each of the 32 layers is read from storage once and applied
    /// to every prompt (positive and negative) before the next layer is read.
    func encode(prompts: [[Int]]) throws -> [MLXArray] {
        try checkLayout()
        var states: [MLXArray] = try prompts.map { ids in try control.compute {
            var rows: [MLXArray] = []
            for id in ids {
                let w = try store.read("embed_tokens.weight", row: id)
                let s = try store.read("embed_tokens.scales", row: id)
                let b = try store.read("embed_tokens.biases", row: id)
                let row = dequantized(w, scales: s, biases: b, groupSize: 64, bits: 6).asType(.bfloat16)
                eval(row); rows.append(row)
            }
            let x = concatenated(rows, axis: 0).reshaped([1, ids.count, 4096]); eval(x); return x
        } }
        for index in 0..<32 {
            try control.check()
            try autoreleasepool {
                let w = try store.load(prefix: "layers.\(index).")
                for p in states.indices { states[p] = try control.compute {
                    let x = states[p]
                    let y = try w.norm(x, "input_layernorm", offset: true)
                    let attn = try (index % 4 == 3 ? fullAttention(y, w) : linearAttention(y, w))
                    let h = x + attn
                    let z = try w.norm(h, "post_attention_layernorm", offset: true)
                    let gate = try w.linear(z, "mlp.gate_proj", bits: 6)
                    let up = try w.linear(z, "mlp.up_proj", bits: 6)
                    let next = try h + w.linear(mossSilu(gate) * up, "mlp.down_proj", bits: 6)
                    eval(next); return next
                } }
            }
            Memory.clearCache()
            progress(index + 1)
        }
        let w = Weights(["norm.weight": try store.read("norm.weight")])
        return try states.map { x in try control.compute { let result = try w.norm(x, "norm", offset: true); eval(result); return result } }
    }
    /// The engine hard-codes the Qwen3.5 text encoder shape and 6-bit g64 packing; refuse anything else.
    private func checkLayout() throws {
        func shape(_ name: String) -> [Int]? { store.entries[name]?.shape }
        let expected: [(String, [Int])] = [
            ("embed_tokens.weight", [248320, 4096 * 6 / 32]),
            ("embed_tokens.scales", [248320, 4096 / 64]),
            ("layers.0.linear_attn.in_proj_qkv.weight", [8192, 4096 * 6 / 32]),
            ("layers.0.linear_attn.conv1d.weight", [8192, 4, 1]),
            ("layers.3.self_attn.q_proj.weight", [8192, 4096 * 6 / 32]),
            ("norm.weight", [4096]),
        ]
        for (name, value) in expected where shape(name) != value {
            throw MossError.model("The text encoder files do not match this version of Moss (\(name) is \(shape(name).map { "\($0)" } ?? "missing")). Re-download the model.")
        }
        guard shape("layers.32.input_layernorm.weight") == nil else { throw MossError.model("The text encoder has more layers than this version of Moss supports.") }
    }
    private func fullAttention(_ x: MLXArray, _ w: Weights) throws -> MLXArray {
        let n = x.shape[1], p = "self_attn."
        let qg = try w.linear(x, p + "q_proj", bits: 6).reshaped([1,n,16,512])
        let q = try w.norm(qg[0...,0...,0...,0..<256], p + "q_norm", offset: true).transposed(0,2,1,3)
        let gate = qg[0...,0...,0...,256..<512].reshaped([1,n,4096])
        let k = try w.norm(w.linear(x, p + "k_proj", bits: 6).reshaped([1,n,4,256]), p + "k_norm", offset: true).transposed(0,2,1,3)
        let v = try w.linear(x, p + "v_proj", bits: 6).reshaped([1,n,4,256]).transposed(0,2,1,3)
        var cosine: [Float] = [], sine: [Float] = []
        for t in 0..<n {
            var c: [Float] = [], s: [Float] = []
            for j in 0..<32 { let phase = Float(t) * (1 / powf(10000000, Float(j*2)/64)); c.append(cosf(phase)); s.append(sinf(phase)) }
            cosine += c+c; sine += s+s
        }
        let c = MLXArray(cosine, [1,1,n,64]).asType(.bfloat16), s = MLXArray(sine, [1,1,n,64]).asType(.bfloat16)
        func rope(_ a: MLXArray) -> MLXArray {
            let rot = a[0...,0...,0...,0..<64]
            let swapped = concatenated([-rot[0...,0...,0...,32..<64], rot[0...,0...,0...,0..<32]], axis: -1)
            return concatenated([rot*c + swapped*s, a[0...,0...,0...,64..<256]], axis: -1)
        }
        let out = MLXFast.scaledDotProductAttention(queries: rope(q), keys: rope(k), values: v, scale: 1/16, mask: .causal, forceFused: !control.usesCPU)
        return try w.linear(out.transposed(0,2,1,3).reshaped([1,n,4096]) * sigmoid(gate), p + "o_proj", bits: 6)
    }
    private func linearAttention(_ x: MLXArray, _ w: Weights) throws -> MLXArray {
        let n = x.shape[1], p = "linear_attn."
        let qkv = try w.linear(x, p + "in_proj_qkv", bits: 6)
        let z = try w.linear(x, p + "in_proj_z", bits: 6).reshaped([1,n,32,128])
        let a = try w.linear(x, p + "in_proj_a", bits: 6).asType(.float32)
        let b = try w.linear(x, p + "in_proj_b", bits: 6)
        let padded = concatenated([MLXArray.zeros([1,3,8192], dtype: x.dtype), qkv], axis: 1)
        let convolved = try mossSilu(conv1d(padded, w.get(p + "conv1d.weight"), groups: 8192))
        var q = convolved[0...,0...,0..<2048].reshaped([1,n,16,128]).asType(.float32)
        var k = convolved[0...,0...,2048..<4096].reshaped([1,n,16,128]).asType(.float32)
        let v = convolved[0...,0...,4096..<8192].reshaped([1,n,32,128]).asType(.float32)
        q = q * rsqrt(sum(q*q, axis: -1, keepDims: true) + 1e-6) * (1 / sqrtf(128))
        k = k * rsqrt(sum(k*k, axis: -1, keepDims: true) + 1e-6)
        q = broadcast(q.reshaped([1,n,16,1,128]), to: [1,n,16,2,128]).reshaped([1,n,32,128])
        k = broadcast(k.reshaped([1,n,16,1,128]), to: [1,n,16,2,128]).reshaped([1,n,32,128])
        let beta = sigmoid(b).asType(.float32)
        let u = try a + w.get(p + "dt_bias").asType(.float32)
        let soft = maximum(u, MLXArray(Float(0))) + log(1 + exp(-abs(u)))
        let decay = try exp(-exp(w.get(p + "A_log").asType(.float32)) * soft)
        eval(q,k,v,beta,decay,z)
        var state = MLXArray.zeros([1,32,128,128], dtype: .float32)
        var outputs: [MLXArray] = []
        for t in 0..<n {
            if t % 16 == 0 { try control.check() }
            let kt = k[0...,t,0...,0...].reshaped([1,32,1,128])
            let qt = q[0...,t,0...,0...].reshaped([1,32,1,128])
            state = state * decay[0...,t,0...].reshaped([1,32,1,1])
            let memory = sum(state * kt, axis: -1)
            let delta = (v[0...,t,0...,0...] - memory) * beta[0...,t,0...].reshaped([1,32,1])
            state = state + kt * delta.reshaped([1,32,128,1])
            let out = sum(state * qt, axis: -1)
            eval(state, out); outputs.append(out)
        }
        let out = stacked(outputs, axis: 1).asType(x.dtype)
        let f = out.asType(.float32)
        let norm = try (f * rsqrt(mean(f*f, axis: -1, keepDims: true) + 1e-6)).asType(x.dtype) * w.get(p + "norm.weight")
        let gated = (norm.asType(.float32) * mossSilu(z.asType(.float32))).asType(x.dtype)
        return try w.linear(gated.reshaped([1,n,4096]), p + "out_proj", bits: 6)
    }
}
