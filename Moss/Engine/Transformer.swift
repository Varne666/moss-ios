import Foundation
import MLX

final class MossTransformer {
    let store: TensorStore
    let adapter: TensorStore?
    let control: RunControl
    init(store: TensorStore, adapter: TensorStore?, control: RunControl) { self.store = store; self.adapter = adapter; self.control = control }
    private func rope(height: Int, width: Int, text: Int) -> (MLXArray, MLXArray) {
        var sine: [Float] = [], cosine: [Float] = []
        for i in 0..<(height*width+text) {
            let image = i < height*width
            let coords: [Float] = image ? [0,Float(text),Float(i/width)-Float(height-1)/2,Float(i%width)-Float(width-1)/2] : [0,Float(i-height*width),0,0]
            var s: [Float] = [], c: [Float] = []
            for coordinate in coords { for j in 0..<16 { let phase = coordinate / powf(10000,Float(j)/16); s.append(sinf(phase)); c.append(cosf(phase)) } }
            sine += s+s; cosine += c+c
        }
        let shape = [1,height*width+text,1,128]
        return (MLXArray(sine,shape).asType(.bfloat16),MLXArray(cosine,shape).asType(.bfloat16))
    }
    private func attention(_ q: MLXArray, _ k: MLXArray, _ v: MLXArray, _ rope: (MLXArray, MLXArray)) -> MLXArray {
        let n = q.shape[1]
        func rotate(_ a: MLXArray) -> MLXArray {
            let x = a.reshaped([1,n,24,128])
            let r = concatenated([-x[0...,0...,0...,64..<128],x[0...,0...,0...,0..<64]],axis:-1)
            return (x*rope.1 + r*rope.0).transposed(0,2,1,3)
        }
        return MLXFast.scaledDotProductAttention(queries: rotate(q), keys: rotate(k), values: v.reshaped([1,n,24,128]).transposed(0,2,1,3), scale: 1/sqrtf(128), mask: MLXFast.ScaledDotProductAttentionMaskMode.none, forceFused: true).transposed(0,2,1,3).reshaped([1,n,3072])
    }
    private func headNorm(_ x: MLXArray, _ w: Weights, _ name: String) throws -> MLXArray {
        try w.norm(x.reshaped([1,x.shape[1],24,128]),name).reshaped(x.shape)
    }
    func predict(_ latent: MLXArray, time: Float, context: MLXArray, skip22: Bool) throws -> MLXArray {
        let height = latent.shape[2], width = latent.shape[3], count = height*width
        let base = try store.load(prefix: "", excluding: "layers.")
        var embedding: [Float] = []
        let angles = (0..<128).map { Double(time) * pow(10000.0,-Double($0)/128) }
        embedding += angles.map { Float(cos($0)) }; embedding += angles.map { Float(sin($0)) }
        let time0 = try base.linear(MLXArray(embedding,[1,256]).asType(.bfloat16),"time_embedding.0",bits:8)
        let t = try base.linear(mossSilu(time0),"time_embedding.1",bits:8)
        let mod = try base.linear(t,"shared_block_modulation",bits:8).reshaped([1,6,3072])
        let head = try base.linear(t,"video_head_modulation",bits:8).reshaped([1,2,3072])
        let video = try base.linear(latent.reshaped([1,128,count]).transposed(0,2,1).asType(.bfloat16),"video_embedder",bits:8)
        let r = rope(height:height,width:width,text:context.shape[1])
        let tr = (r.0[0...,count...,0...,0...],r.1[0...,count...,0...,0...])
        var text = try base.linear(context,"text_embedder.proj",bits:8)
        for i in 0..<2 {
            let p = "text_embedder.blocks.\(i)."
            let y = try base.norm(text,p+"norm1")
            let qkv = try base.linear(y,p+"qkv",bits:8)
            let q = try headNorm(qkv[0...,0...,0..<3072],base,p+"q_norm")
            let k = try headNorm(qkv[0...,0...,3072..<6144],base,p+"k_norm")
            text = try text + base.linear(attention(q,k,qkv[0...,0...,6144..<9216],tr),p+"proj",bits:8)
            let h = try base.norm(text,p+"norm2")
            let up = try base.linear(h,p+"ffn_up",bits:8), gate = try base.linear(h,p+"ffn_gate",bits:8)
            text = try text + base.linear(mossSitu(up,gate),p+"ffn_down",bits:8)
        }
        var x = concatenated([video,text],axis:1); eval(x,mod,head)
        for i in 0..<42 {
            if skip22 && i == 22 { continue }
            try control.check()
            x = try autoreleasepool {
                let w = try store.load(prefix:"layers.\(i).")
                let a = try adapter?.load(prefix:"diffusion_model.layers.\(i).")
                let y = try w.norm(x,"norm1") * (1 + mod[0...,1..<2,0...]) + mod[0...,0..<1,0...]
                let q = try headNorm(w.linear(y,"proj.q",bits:8,adapter:a),w,"q_norm")
                let k = try headNorm(w.linear(y,"proj.k",bits:8,adapter:a),w,"k_norm")
                let v = try w.linear(y,"proj.v",bits:8,adapter:a)
                let h = try x + w.linear(attention(q,k,v,r),"proj.o",bits:8,adapter:a) * mod[0...,2..<3,0...]
                let z = try w.norm(h,"norm2") * (1 + mod[0...,4..<5,0...]) + mod[0...,3..<4,0...]
                let hg = try w.linear(z,"proj.ffn_up_gate",bits:8,adapter:a)
                let result = try h + w.linear(mossSitu(hg[0...,0...,0..<8192],hg[0...,0...,8192..<16384]),"proj.ffn_down",bits:8,adapter:a) * mod[0...,5..<6,0...]
                eval(result); return result
            }
            Memory.clearCache()
        }
        let normalized = try base.norm(x[0...,0..<count,0...],"final_norm_video")
        let y = normalized * (1 + head[0...,1..<2,0...]) + head[0...,0..<1,0...]
        let out = try base.linear(y,"final_linear_video",bits:8).transposed(0,2,1).reshaped([1,128,height,width]).asType(.float32)
        eval(out); return out
    }
}
