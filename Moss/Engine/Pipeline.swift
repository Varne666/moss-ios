import Foundation
import CoreGraphics
import MLX

/// A pipeline milestone. `index` counts completed units of `total` within the stage.
struct GenerationProgress: Equatable {
    enum Stage: Int, Codable { case starting, encode, prepare, sample, decode, done }
    var stage: Stage = .starting
    var index = 0
    var total = 1
    var message: String
}
final class MossPipeline {
    func generate(settings s: GenerationSettings, folder: URL, manifest: ModelManifest, control: RunControl,
                  progress: @escaping (GenerationProgress) -> Void) throws -> CGImage {
        try s.validate(); try control.check()
        Memory.cacheLimit = 64 * 1024 * 1024
        // Leave headroom for UIKit, decoding, and the operating system. This is not a guarantee against jetsam.
        Memory.memoryLimit = Int(ProcessInfo.processInfo.physicalMemory * 3 / 4)
        defer { Memory.clearCache() }
        func store(_ component: String) throws -> TensorStore {
            let urls = manifest.files.filter { $0.component == component && $0.path.hasSuffix(".safetensors") }.map { folder.appendingPathComponent($0.path) }
            guard !urls.isEmpty else { throw MossError.model("The model is missing its \(component) files.") }
            return try TensorStore(files:urls)
        }
        progress(.init(stage:.encode,index:0,total:32,message:"Reading your prompt"))
        let contexts: (MLXArray,MLXArray?) = try autoreleasepool {
            let tokenizer = try MossTokenizer(url:folder.appendingPathComponent("tokenizer/tokenizer.json"))
            let positive = try tokenizer.encode(s.prompt)
            let negative = s.guidance != 1 ? try tokenizer.encode(s.negativePrompt) : nil
            // Long prompts need proportionally more activations even with streamed weights.
            guard positive.count <= 1024, (negative?.count ?? 0) <= 1024 else {
                throw MossError.model("This prompt is too long for the phone memory limit. Shorten it to roughly 600 words or simplify the JSON layout. Your text has not been truncated.")
            }
            let encoder = try MossTextEncoder(store:store("text"),control:control,progress:{ done in progress(.init(stage:.encode,index:done,total:32,message:"Reading your prompt")) })
            let encoded = try encoder.encode(prompts: negative.map { [positive, $0] } ?? [positive])
            return (encoded[0], encoded.count > 1 ? encoded[1] : nil)
        }
        Memory.clearCache(); try control.check()
        let h = s.height/16, w = s.width/16
        var noise = MossNoise(seed:s.seed)
        var latent = MLXArray(noise.normal(count:128*h*w),[1,128,h,w]); eval(latent)
        let schedule = MossSchedule.sigmas(steps:s.steps,shift:s.shift)
        try autoreleasepool {
            let adapter = s.quality == .fast ? try store("adapter") : nil
            let transformer = try MossTransformer(store:store("transformer"),adapter:adapter,control:control,cacheBudget:control.layerCacheBudget(pixels:s.width*s.height))
            progress(.init(stage:.prepare,index:0,total:1,message:"Preparing the image model"))
            var branches = [try transformer.prepare(context:contexts.0,height:h,width:w,skipped:[])]
            if let negative = contexts.1 {
                branches.append(try transformer.prepare(context:negative,height:h,width:w,skipped:s.skipLayer ? [22] : []))
            }
            let stepCount = schedule.count-1
            for i in 0..<stepCount {
                try control.check()
                progress(.init(stage:.sample,index:i,total:stepCount,message:"Step \(i+1) of \(stepCount)"))
                let outputs: [MLXArray] = try autoreleasepool { try transformer.predict(latent,time:schedule[i]*1000,branches:branches) }
                latent = control.compute {
                    // FP32 guidance combination and Euler update, exactly as the reference.
                    let velocity = outputs.count == 2 ? outputs[1] + s.guidance*(outputs[0]-outputs[1]) : outputs[0]
                    let next = latent + velocity*(schedule[i+1]-schedule[i]); eval(next); return next
                }
                Memory.clearCache()
            }
            progress(.init(stage:.sample,index:stepCount,total:stepCount,message:"Step \(stepCount) of \(stepCount)"))
        }
        Memory.clearCache(); try control.check()
        progress(.init(stage:.decode,index:0,total:4,message:"Finishing the image"))
        return try autoreleasepool {
            let decoder = try MossDecoder(store:store("vae"),control:control,progress:{ done in progress(.init(stage:.decode,index:done,total:4,message:"Finishing the image")) })
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
