import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import Photos
import Combine

final class GalleryStore: ObservableObject {
    @Published private(set) var items: [GalleryItem] = []
    @Published var error: String?
    init() { reload() }
    func file(_ item: GalleryItem) -> URL { AppPaths.gallery.appendingPathComponent(item.id.uuidString+".png") }
    func thumbnail(_ item: GalleryItem) -> URL { AppPaths.gallery.appendingPathComponent(item.id.uuidString+"-thumb.jpg") }
    private func record(_ item: GalleryItem) -> URL { AppPaths.gallery.appendingPathComponent(item.id.uuidString+".json") }
    func reload() {
        do {
            try FileManager.default.createDirectory(at:AppPaths.gallery,withIntermediateDirectories:true)
            let urls = try FileManager.default.contentsOfDirectory(at:AppPaths.gallery,includingPropertiesForKeys:nil)
            var loaded: [GalleryItem] = []; var damaged = 0
            for url in urls where url.pathExtension == "json" {
                do {
                    let item = try JSONDecoder().decode(GalleryItem.self,from:Data(contentsOf:url))
                    if FileManager.default.fileExists(atPath:file(item).path) { loaded.append(item) }
                } catch { damaged += 1 }
            }
            items = loaded.sorted { $0.created > $1.created }
            if damaged > 0 { error = "\(damaged) gallery records could not be read. Your image files have been kept." }
        } catch { self.error = "The gallery could not be opened: \(error.localizedDescription)" }
    }
    @discardableResult func save(image: UIImage, settings: GenerationSettings, seconds: Double, identity: String) throws -> GalleryItem {
        let item = GalleryItem(id:UUID(),created:Date(),settings:settings,seconds:seconds,modelIdentity:identity,favorite:false)
        guard let cg = image.cgImage else { throw MossError.model("The generated image could not be saved.") }
        let json = try JSONEncoder().encode(item)
        let png = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(png,UTType.png.identifier as CFString,1,nil) else { throw MossError.model("The image writer could not start.") }
        let metadata: [CFString:Any] = [kCGImagePropertyPNGDictionary:[kCGImagePropertyPNGDescription:String(decoding:json,as:UTF8.self)]]
        CGImageDestinationAddImage(output,cg,metadata as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw MossError.model("The image could not be encoded.") }
        try (png as Data).write(to:file(item),options:.atomic)
        do { try json.write(to:record(item),options:.atomic) }
        catch { try? FileManager.default.removeItem(at:file(item)); throw error }
        let scale = min(1,400/max(image.size.width,image.size.height))
        let size = CGSize(width:image.size.width*scale,height:image.size.height*scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let thumb = UIGraphicsImageRenderer(size:size,format:format).image { _ in image.draw(in:CGRect(origin:.zero,size:size)) }
        try? thumb.jpegData(compressionQuality:0.8)?.write(to:thumbnail(item),options:.atomic)
        items.insert(item,at:0); return item
    }
    func toggleFavorite(_ item: GalleryItem) {
        guard let index = items.firstIndex(where:{$0.id == item.id}) else { return }
        var changed = items[index]; changed.favorite.toggle()
        do { try JSONEncoder().encode(changed).write(to:record(changed),options:.atomic); items[index] = changed }
        catch { self.error = "The favorite could not be saved: \(error.localizedDescription)" }
    }
    func delete(_ ids: Set<UUID>) {
        do {
            for item in items where ids.contains(item.id) {
                try FileManager.default.removeItem(at:file(item))
                try? FileManager.default.removeItem(at:record(item)); try? FileManager.default.removeItem(at:thumbnail(item))
            }
            items.removeAll { ids.contains($0.id) }
        } catch { self.error = "An image could not be deleted: \(error.localizedDescription)"; reload() }
    }
    func saveToPhotos(_ selected: [GalleryItem]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for:.addOnly)
        guard status == .authorized || status == .limited else { throw MossError.model("Allow Moss to add photos in iPhone Settings → Apps → Moss → Photos, then try again.") }
        let urls = selected.map(file)
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls { PHAssetCreationRequest.forAsset().addResource(with:.photo,fileURL:url,options:nil) }
        }
    }
}
