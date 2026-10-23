import Foundation
import Combine

/// LoRAs the user imported from Files (for example Realistic Snapshot from Civitai). Stored inside Moss.
final class LoRAStore: ObservableObject {
    struct Item: Codable, Identifiable, Equatable {
        let id: String
        var name: String
        let bytes: Int64
        let layers: Int
        let rank: Int?
        var file: String { id + ".safetensors" }
    }
    @Published private(set) var items: [Item] = []
    @Published var error: String?
    @Published var importing = false
    static let folder: URL = {
        let url = AppPaths.support.appendingPathComponent("LoRAs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private var index: URL { Self.folder.appendingPathComponent("loras.json") }
    init() {
        if let data = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved.filter { FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent($0.file).path) }
        }
    }
    func url(_ item: Item) -> URL { Self.folder.appendingPathComponent(item.file) }
    func item(_ id: String) -> Item? { items.first { $0.id == id } }

    /// Copies a .safetensors LoRA into Moss after checking it targets MOSS-Image blocks.
    func importFile(_ source: URL) {
        let access = source.startAccessingSecurityScopedResource()
        importing = true
        DispatchQueue.global(qos: .userInitiated).async {
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                let name = source.deletingPathExtension().lastPathComponent
                let probe = try LoRAFile(url: source, name: name, strength: 1)
                let id = UUID().uuidString
                let target = Self.folder.appendingPathComponent(id + ".safetensors")
                try FileManager.default.copyItem(at: source, to: target)
                let bytes = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let item = Item(id: id, name: Self.friendlyName(name), bytes: bytes, layers: probe.layerCount, rank: probe.rank)
                DispatchQueue.main.async { self.items.append(item); self.save(); self.importing = false }
            } catch {
                DispatchQueue.main.async { self.error = "Import failed: \(error.localizedDescription)"; self.importing = false }
            }
        }
    }
    func rename(_ item: Item, to name: String) {
        guard let i = items.firstIndex(of: item) else { return }
        items[i].name = name; save()
    }
    func delete(_ item: Item) {
        try? FileManager.default.removeItem(at: url(item))
        items.removeAll { $0.id == item.id }; save()
    }
    private func save() { if let data = try? JSONEncoder().encode(items) { try? data.write(to: index, options: .atomic) } }

    /// "MOSSRealisticSnapshotV1_3311349" → "Realistic Snapshot V1".
    static func friendlyName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "_", with: " ")
        if let range = name.range(of: #"\s\d{5,}$"#, options: .regularExpression) { name.removeSubrange(range) }
        if name.hasPrefix("MOSS") && name.count > 4 { name.removeFirst(4) }
        let spaced = name.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"([a-zA-Z])(V\d)"#, with: "$1 $2", options: .regularExpression)
        return spaced.trimmingCharacters(in: .whitespaces).isEmpty ? raw : spaced.trimmingCharacters(in: .whitespaces)
    }
}
