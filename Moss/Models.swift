import Foundation
import SwiftUI

let mossAccent = Color(red: 0.36, green: 0.46, blue: 0.32)

enum MossError: LocalizedError {
    case model(String), cancelled, memory, background
    var errorDescription: String? {
        switch self {
        case .model(let text): return text
        case .cancelled: return "Generation cancelled. Your saved images are safe."
        case .memory: return "Not enough memory at this size. Close other apps and try 512 × 512 with a shorter prompt."
        case .background: return "Generation stopped when Moss left the screen or was interrupted. Keep Moss open while generating, then tap Generate to restart."
        }
    }
}
enum Quality: String, Codable, CaseIterable, Identifiable {
    case fast = "Fast", balanced = "Balanced", best = "Best"
    var id: String { rawValue }
}
struct GenerationSettings: Codable, Equatable {
    var prompt = ""
    var negativePrompt = ""
    var width = 512
    var height = 512
    var quality: Quality = .balanced
    var steps = 20
    var guidance: Float = 3
    var shift: Float = 5
    var skipLayer = true
    var seed: UInt32 = 42
    var lockedSeed = false
    var count = 1
    mutating func preset(_ q: Quality) {
        quality = q; shift = 5; skipLayer = true
        steps = q == .fast ? 8 : q == .best ? 50 : 20
        guidance = q == .fast ? 1 : 3
    }
    func validate() throws {
        guard width >= 256, height >= 256, width <= 1536, height <= 1536,
              width % 16 == 0, height % 16 == 0, width*height <= 1024*1024 else {
            throw MossError.model("Choose dimensions from 256 to 1,536, in multiples of 16, and no more than 1,048,576 pixels. Try 512 × 512 first.")
        }
        guard (1...100).contains(steps), guidance.isFinite, (0...10).contains(guidance), shift.isFinite,
              (0.1...20).contains(shift), (1...8).contains(count) else { throw MossError.model("Check your advanced settings. Use 1–100 steps, guidance 0–10, shift 0.1–20, and 1–8 images.") }
        guard !prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw MossError.model("Describe the image you want first.") }
    }
}
struct GalleryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let created: Date
    var settings: GenerationSettings
    let seconds: Double
    let modelIdentity: String
    var favorite: Bool
}
struct ModelFile: Codable, Identifiable {
    let path: String
    let url: URL
    let bytes: Int64
    let sha256: String
    let component: String
    var id: String { path }
    var optional: Bool { component == "adapter" }
}
struct ModelManifest: Codable {
    let format: Int
    let identity: String
    let name: String
    let files: [ModelFile]
    var requiredBytes: Int64 { files.filter { !$0.optional }.reduce(0) { $0+$1.bytes } }
    func validate() throws {
        guard format == 1, identity == "moss-base8-text6-v1", !files.isEmpty, files.count < 40,
              Set(files.map(\.path)).count == files.count else { throw MossError.model("This model list is incompatible with Moss. Use the supplied manifest or its exact mirror.") }
        let reference = try Self.bundled()
        guard files.count == reference.files.count else { throw MossError.model("The model list is incomplete.") }
        for f in files {
            guard !f.path.hasPrefix("/"), !f.path.split(separator:"/").contains(".."), !f.path.contains("\\"),
                  f.url.scheme == "https", f.bytes > 0,
                  f.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
                  let expected = reference.files.first(where: { $0.path == f.path }),
                  f.bytes == expected.bytes, f.sha256 == expected.sha256, f.component == expected.component else {
                throw MossError.model("This model list contains different or unsafe files. Only a byte-for-byte mirror of the supported model is accepted.")
            }
        }
    }
    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource:"model-manifest",withExtension:"json") else { throw MossError.model("The app is missing its model list. Rebuild and reinstall Moss.") }
        return try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
    }
}
enum AppPaths {
    static let support: URL = {
        let root = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Moss",isDirectory:true)
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var url = root; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? url.setResourceValues(values)
        return root
    }()
    static let gallery = support.appendingPathComponent("Gallery",isDirectory:true)
    static let models = support.appendingPathComponent("Models",isDirectory:true)
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount:count,countStyle:.decimal) }
}
