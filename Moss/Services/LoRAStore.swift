import Foundation
import Combine
import Security

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
    /// 0…1 while Realistic Snapshot downloads from Civitai.
    @Published var downloadFraction: Double?
    private var downloader: LoRADownloader?

    /// Realistic Snapshot V1 for MOSS-Image (Civitai model 2268008, version 3417962). Civitai only serves it to
    /// signed-in accounts, so the download uses the user's own Civitai API key, kept in this iPhone's Keychain.
    static let snapshot = (name: "Realistic Snapshot V1", versionURL: URL(string: "https://civitai.com/api/download/models/3417962?type=Model&format=SafeTensor")!,
                           bytes: Int64(580_458_124), sha256: "67d6eca47c4a01b5ae03791916cce86226defe44598a66b4bb246f24d3772bb4")
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
        importing = true; error = nil
        RunLog.add("lora: import \(source.lastPathComponent)")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                let name = source.deletingPathExtension().lastPathComponent
                let id = UUID().uuidString
                let target = Self.folder.appendingPathComponent(id + ".safetensors")
                // Files from iCloud Drive or another app's folder may need to be fetched first; the coordinator does it.
                var coordinationError: NSError?, copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
                    do { try FileManager.default.copyItem(at: readable, to: target) } catch { copyError = error }
                }
                if let e = coordinationError ?? (copyError as NSError?) { throw e }
                let probe: LoRAFile
                do { probe = try LoRAFile(url: target, name: Self.friendlyName(name), strength: 1) }
                catch { try? FileManager.default.removeItem(at: target); throw error }
                let bytes = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let item = Item(id: id, name: Self.friendlyName(name), bytes: bytes, layers: probe.layerCount, rank: probe.rank)
                DispatchQueue.main.async { self.items.append(item); self.save(); self.importing = false }
            } catch {
                RunLog.add("lora: import failed: \(error.localizedDescription)")
                DispatchQueue.main.async { self.error = "Import failed: \(error.localizedDescription)"; self.importing = false }
            }
        }
    }

    // MARK: Civitai download

    var civitaiKey: String? {
        get { Keychain.read("civitai-api-key") }
        set { if let newValue, !newValue.isEmpty { Keychain.write("civitai-api-key", newValue) } else { Keychain.delete("civitai-api-key") }; objectWillChange.send() }
    }
    func downloadSnapshot() {
        guard downloader == nil else { return }
        guard let key = civitaiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { error = "Paste your Civitai API key first."; return }
        error = nil; downloadFraction = 0
        RunLog.add("lora: Civitai download start")
        var request = URLRequest(url: Self.snapshot.versionURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let d = LoRADownloader(expected: Self.snapshot.bytes) { [weak self] f in DispatchQueue.main.async { self?.downloadFraction = f } } done: { [weak self] result in
            DispatchQueue.main.async { self?.downloader = nil }
            guard let self else { return }
            switch result {
            case .failure(let e):
                RunLog.add("lora: Civitai download failed: \(e.localizedDescription)")
                DispatchQueue.main.async { self.downloadFraction = nil; self.error = e.localizedDescription }
            case .success(let file):
                DispatchQueue.global(qos: .userInitiated).async { self.install(downloaded: file) }
            }
        }
        downloader = d; d.start(request)
    }
    func cancelDownload() { downloader?.cancel(); downloader = nil; downloadFraction = nil }
    private func install(downloaded file: URL) {
        do {
            let size = Int64((try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard size == Self.snapshot.bytes, try ModelManager.digest(file) == Self.snapshot.sha256 else {
                throw MossError.model("The Realistic Snapshot download did not match Civitai's checksum (\(AppPaths.bytes(size))). Try again.")
            }
            let id = UUID().uuidString, target = Self.folder.appendingPathComponent(id + ".safetensors")
            try FileManager.default.moveItem(at: file, to: target)
            let probe: LoRAFile
            do { probe = try LoRAFile(url: target, name: Self.snapshot.name, strength: 1) }
            catch { try? FileManager.default.removeItem(at: target); throw error }
            let item = Item(id: id, name: Self.snapshot.name, bytes: size, layers: probe.layerCount, rank: probe.rank)
            RunLog.add("lora: Realistic Snapshot installed, \(probe.layerCount) blocks, rank \(probe.rank ?? 0), \(probe.ignored) ignored")
            DispatchQueue.main.async { self.items.append(item); self.save(); self.downloadFraction = nil }
        } catch {
            try? FileManager.default.removeItem(at: file)
            RunLog.add("lora: install failed: \(error.localizedDescription)")
            DispatchQueue.main.async { self.downloadFraction = nil; self.error = error.localizedDescription }
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

/// Downloads one file to a temporary location with progress; maps Civitai's error responses to plain messages.
final class LoRADownloader: NSObject, URLSessionDownloadDelegate {
    private let expected: Int64
    private let progress: (Double) -> Void
    private let done: (Result<URL, Error>) -> Void
    private var session: URLSession?
    private var finished = false
    init(expected: Int64, progress: @escaping (Double) -> Void, done: @escaping (Result<URL, Error>) -> Void) {
        self.expected = expected; self.progress = progress; self.done = done
    }
    func start(_ request: URLRequest) {
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s; s.downloadTask(with: request).resume()
    }
    func cancel() { finished = true; session?.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The file itself comes from Civitai's storage host via a signed link; the API key stays with Civitai.
        var next = request
        if request.url?.host != task.originalRequest?.url?.host { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        progress(min(1, Double(totalBytesWritten) / Double(max(1, total))))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !finished else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            finished = true
            let message: String
            switch status {
            case 401, 403: message = "Civitai refused the API key (\(status)). Check the key in Civitai → Account settings → API Keys and paste it again."
            case 404: message = "Civitai no longer offers this file (404)."
            case 429: message = "Civitai is rate-limiting downloads (429). Wait a minute and try again."
            default: message = "Civitai returned \(status). Try again later."
            }
            done(.failure(MossError.model(message))); session.finishTasksAndInvalidate(); return
        }
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".safetensors")
        do { try FileManager.default.moveItem(at: location, to: keep); finished = true; done(.success(keep)) }
        catch { finished = true; done(.failure(error)) }
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        done(.failure(error.map { MossError.model("The download stopped: \($0.localizedDescription)") } ?? MossError.model("The download stopped.")))
    }
}

/// Minimal Keychain storage for the user's Civitai API key (this device only, never synced or logged).
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.mossios.app", kSecAttrAccount as String: account]
    }
    static func read(_ account: String) -> String? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ account: String, _ value: String) {
        delete(account)
        var q = query(account); q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}
