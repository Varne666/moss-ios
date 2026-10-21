import Foundation
import CoreGraphics
import MLX

struct GenerationProgress {
    let message: String
    var fraction: Double? = nil
    var remaining: Double? = nil
}
final class MossPipeline {
    func generate(settings s: GenerationSettings, folder: URL, manifest: ModelManifest, control: RunControl,
                  progress: @escaping (GenerationProgress) -> Void) throws -> CGImage {
        try s.validate(); try control.check()
        Memory.cacheLimit = 64 * 1024 * 1024
        // Leave headroom for UIKit, decoding, and the operating system. This is not a guarantee against jetsam.
        Memory.memoryLimit = min(Int(ProcessInfo.processInfo.physicalMemory / 2), 5 * 1024 * 1024 * 1024)
        defer { Memory.clearCache() }
        func store(_ component: String) throws -> TensorStore {
            let urls = manifest.files.filter { $0.component == component && $0.path.hasSuffix(".safetensors") }.map { folder.appendingPathComponent($0.path) }
            guard !urls.isEmpty else { throw MossError.model("The model is missing its \(component) files.") }
            return try TensorStore(files:urls)
        }
        progress(.init(message:"Reading your prompt"))
        let contexts: (MLXArray,MLXArray?) = try autoreleasepool {
            let tokenizer = try MossTokenizer(url:folder.appendingPathComponent("tokenizer/tokenizer.json"))
            let positive = try tokenizer.encode(s.prompt)
            let negative = s.guidance != 1 ? try tokenizer.encode(s.negativePrompt) : nil
            // Long prompts need proportionally more activations even with streamed weights.
            guard positive.count <= 1024, (negative?.count ?? 0) <= 1024 else {
                throw MossError.model("This prompt is too long for the phone memory limit. Shorten it to roughly 600 words or simplify the JSON layout. Your text has not been truncated.")
            }
            let encoder = try MossTextEncoder(store:store("text"),control:control,progress:{ progress(.init(message:$0)) })
            let p = try encoder.encode(ids:positive)
            let n = try negative.map { try encoder.encode(ids:$0) }
            return (p,n)
        }
        Memory.clearCache(); try control.check()
        let h = s.height/16, w = s.width/16
        var noise = MossNoise(seed:s.seed)
        var latent = MLXArray(noise.normal(count:128*h*w),[1,128,h,w]); eval(latent)
        let schedule = MossSchedule.sigmas(steps:s.steps,shift:s.shift)
        try autoreleasepool {
            let adapter = s.quality == .fast ? try store("adapter") : nil
            let transformer = try MossTransformer(store:store("transformer"),adapter:adapter,control:control)
            let start = Date()
            for i in 0..<(schedule.count-1) {
                try control.check()
                let elapsed = Date().timeIntervalSince(start)
                progress(.init(message:"Step \(i+1) of \(schedule.count-1)",fraction:Double(i)/Double(schedule.count-1),remaining:i > 0 ? elapsed/Double(i)*Double(schedule.count-1-i) : nil))
                let velocity: MLXArray = try autoreleasepool {
                    let positive = try transformer.predict(latent,time:schedule[i]*1000,context:contexts.0,skip22:false)
                    if let negative = contexts.1 {
                        let unconditional = try transformer.predict(latent,time:schedule[i]*1000,context:negative,skip22:s.skipLayer)
                        let result = unconditional + s.guidance*(positive-unconditional); eval(result); return result
                    }
                    return positive
                }
                latent = latent + velocity*(schedule[i+1]-schedule[i]); eval(latent); Memory.clearCache()
            }
        }
        Memory.clearCache(); try control.check()
        progress(.init(message:"Decoding image",fraction:1))
        return try autoreleasepool {
            let decoder = try MossDecoder(store:store("vae"),control:control,progress:{ progress(.init(message:$0,fraction:1)) })
            let decoded = try decoder.decode(latent)
            let pixels = decoded.asArray(Float.self)
            var rgba = [UInt8](repeating:255,count:s.width*s.height*4)
            for i in 0..<(s.width*s.height) { for c in 0..<3 {
                let value = pixels[i*3+c]
                guard value.isFinite else { throw MossError.model("The model produced an invalid image. Restart Moss and try a smaller image.") }
                rgba[i*4+c] = UInt8((min(1,max(0,(value+1)/2))*255).rounded(.toNearestOrEven))
            } }
            let data = Data(rgba)
            guard let provider = CGDataProvider(data:data as CFData), let cg = CGImage(width:s.width,height:s.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:s.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { throw MossError.model("The image could not be created. Try a smaller size.") }
            return cg
        }
    }
}
