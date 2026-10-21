import Foundation
import MLX

/// FLUX.2 small decoder. Global normalization statistics preserve continuity between strips.
final class MossDecoder {
    private let w: Weights
    private let control: RunControl
    private let progress: (String) -> Void
    init(store: TensorStore, control: RunControl, progress: @escaping (String) -> Void) throws {
        w = try store.load(prefix: ""); self.control = control; self.progress = progress
    }
    private func rows(_ x: MLXArray) -> Int { max(1, min(x.shape[1], 16 * 1024 * 1024 / (x.shape[2] * x.shape[3] * 4))) }
    private func statistics(_ x: MLXArray) throws -> (MLXArray, MLXArray) {
        let b = x.shape[0], h = x.shape[1], c = x.shape[3], stride = rows(x)
        let n = Float(h * x.shape[2] * (c/32))
        var total = MLXArray.zeros([b,32])
        for r in Swift.stride(from: 0, to: h, by: stride) {
            try control.check()
            total = total + sum(x[0...,r..<min(r+stride,h),0...,0...].reshaped([b,-1,32,c/32]), axes: [1,3]); eval(total)
        }
        let average = total / n
        var squares = MLXArray.zeros([b,32])
        for r in Swift.stride(from: 0, to: h, by: stride) {
            let d = x[0...,r..<min(r+stride,h),0...,0...].reshaped([b,-1,32,c/32]) - average.reshaped([b,1,32,1])
            squares = squares + sum(d*d, axes: [1,3]); eval(squares)
        }
        return (average,rsqrt(squares/n + 1e-6))
    }
    private func normalize(_ x: MLXArray, _ name: String, _ stats: (MLXArray,MLXArray)) throws -> MLXArray {
        let b = x.shape[0], h = x.shape[1], width = x.shape[2], c = x.shape[3]
        let y = (x.reshaped([b,h,width,32,c/32]) - stats.0.reshaped([b,1,1,32,1])) * stats.1.reshaped([b,1,1,32,1])
        return try y.reshaped(x.shape) * w.get(name+".weight") + w.get(name+".bias")
    }
    private func conv(_ x: MLXArray, _ name: String, padding: Int) throws -> MLXArray {
        let weight = try w.get(name+".weight")
        var y = conv2d(x, weight, padding: .init(padding))
        if let bias = w.values[name+".bias"] { y = y + bias }; return y
    }
    private func strips(_ x: MLXArray, _ name: String, pre: ((MLXArray) throws -> MLXArray)? = nil,
                        post: ((MLXArray,Int,Int) throws -> MLXArray)? = nil) throws -> MLXArray {
        let h = x.shape[1], stride = rows(x)
        var parts: [MLXArray] = []
        for r in Swift.stride(from:0,to:h,by:stride) {
            try control.check()
            let a = max(r-1,0), e = min(r+stride+1,h), length = min(stride,h-r)
            let slice = x[0...,a..<e,0...,0...]
            let input = try pre?(slice) ?? slice
            var y = try conv(input,name,padding:1)[0...,(r-a)..<(r-a+length),0...,0...]
            if let post { y = try post(y,r,r+length) }; eval(y); parts.append(y)
        }
        let y = concatenated(parts,axis:1); eval(y); return y
    }
    private func resnet(_ x: MLXArray, _ name: String) throws -> MLXArray {
        let s1 = try statistics(x)
        let h = try strips(x,name+".conv1",pre: { try mossSilu(self.normalize($0,name+".norm1",s1)) })
        let s2 = try statistics(h)
        return try strips(h,name+".conv2",pre: { try mossSilu(self.normalize($0,name+".norm2",s2)) },post: { y,a,e in
            let residual = x[0...,a..<e,0...,0...]
            if self.w.values[name+".conv_shortcut.weight"] != nil { return try y + self.conv(residual,name+".conv_shortcut",padding:0) }
            return y + residual
        })
    }
    private func attention(_ x: MLXArray) throws -> MLXArray {
        let p = "decoder.mid_block.attentions.0", c = x.shape[3], length = x.shape[1]*x.shape[2]
        let h = try normalize(x,p+".group_norm",statistics(x)).reshaped([1,1,length,c])
        let q = try w.linear(h,p+".to_q",bits:8), k = try w.linear(h,p+".to_k",bits:8), v = try w.linear(h,p+".to_v",bits:8)
        var parts: [MLXArray] = []
        for r in Swift.stride(from:0,to:length,by:128) {
            try control.check()
            let y = MLXFast.scaledDotProductAttention(queries:q[0...,0...,r..<min(r+128,length),0...],keys:k,values:v,scale:1/sqrtf(Float(c)),mask:MLXFast.ScaledDotProductAttentionMaskMode.none)
            eval(y); parts.append(y)
        }
        let y = try x + w.linear(concatenated(parts,axis:2),p+".to_out.0",bits:8).reshaped(x.shape)
        eval(y); return y
    }
    private func upsample(_ x: MLXArray, _ name: String) throws -> MLXArray {
        let h = x.shape[1], width = x.shape[2], c = x.shape[3], stride = max(1,rows(x)/4)
        var parts: [MLXArray] = []
        for r in Swift.stride(from:0,to:h,by:stride) {
            try control.check()
            let length = min(stride,h-r), a = max(r-1,0), e = min(r+length+1,h)
            let up = broadcast(x[0...,a..<e,0...,0...].reshaped([1,e-a,1,width,1,c]),to:[1,e-a,2,width,2,c]).reshaped([1,2*(e-a),2*width,c])
            let y = try conv(up,name+".conv",padding:1)[0...,2*(r-a)..<(2*(r-a)+2*length),0...,0...]
            eval(y); parts.append(y)
        }
        let y = concatenated(parts,axis:1); eval(y); return y
    }
    func decode(_ latent: MLXArray) throws -> MLXArray {
        let h = latent.shape[2], width = latent.shape[3]
        let z = try latent.asType(.float32) * sqrt(w.get("running_var")+1e-4).reshaped([1,128,1,1]) + w.get("running_mean").reshaped([1,128,1,1])
        let unpacked = z.reshaped([1,32,2,2,h,width]).transposed(0,4,2,5,3,1).reshaped([1,2*h,2*width,32])
        var x = try conv(unpacked,"post_quant_conv",padding:0)
        x = try strips(x,"decoder.conv_in")
        x = try resnet(x,"decoder.mid_block.resnets.0")
        x = try attention(x)
        x = try resnet(x,"decoder.mid_block.resnets.1")
        for i in 0..<4 {
            progress("Decoding image · stage \(i+1) of 4")
            for j in 0..<3 { x = try resnet(x,"decoder.up_blocks.\(i).resnets.\(j)"); Memory.clearCache() }
            if i < 3 { x = try upsample(x,"decoder.up_blocks.\(i).upsamplers.0") }
        }
        let stats = try statistics(x)
        let out = try strips(x,"decoder.conv_out",pre:{ try mossSilu(self.normalize($0,"decoder.conv_norm_out",stats)) })
        eval(out); return out
    }
}
