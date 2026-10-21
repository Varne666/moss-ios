import Foundation
import CryptoKit
import Network
import Combine

final class ModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var manifest: ModelManifest?
    @Published var ready = false
    @Published var fastReady = false
    @Published var busy = false
    @Published var downloading = false
    @Published var message = "Checking model files"
    @Published var error: String?
    @Published var fraction = 0.0
    @Published var bytesPerSecond = 0.0
    @Published var remainingSeconds: Double?
    @Published var cellular = false
    @Published var folder = AppPaths.models
    @Published var freeBytes: Int64 = 0
    var backgroundCompletion: (() -> Void)? { didSet { finishBackgroundIfPossible() } }
    private var backgroundEventsFinished = false
    private var completed = Set<String>()
    private var active: URLSessionDownloadTask?
    private var queue: [ModelFile] = []
    private var wantedFast = false
    private var allowCellular = false
    private var paused = false
    private var securityURL: URL?
    private var started = Date()
    private var initialBytes: Int64 = 0
    private var pendingVerification = 0
    private let io = DispatchQueue(label:"Moss.modelIO",qos:.utility)
    private let monitor = NWPathMonitor()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier:"org.mossios.models.v1")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        return URLSession(configuration:config,delegate:self,delegateQueue:.main)
    }()
    override init() {
        super.init()
        do {
            if let data = UserDefaults.standard.data(forKey:"manifest") {
                let saved = try JSONDecoder().decode(ModelManifest.self,from:data); try saved.validate(); manifest = saved
            } else { manifest = try .bundled() }
            if let bookmark = UserDefaults.standard.data(forKey:"modelBookmark") {
                var stale = false
                let url = try URL(resolvingBookmarkData:bookmark,options:[.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
                guard url.startAccessingSecurityScopedResource() else { throw MossError.model("Moss cannot open your model folder. Choose that folder again in Settings.") }
                securityURL = url; folder = url
                if stale { try saveBookmark(url) }
            }
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            refreshSpace()
        } catch { self.error = error.localizedDescription; message = "Model setup needs attention" }
        monitor.pathUpdateHandler = { [weak self] path in DispatchQueue.main.async { self?.cellular = path.isExpensive } }
        monitor.start(queue:DispatchQueue(label:"Moss.network"))
        _ = session
        session.getAllTasks { tasks in DispatchQueue.main.async {
            if let task = tasks.compactMap({$0 as? URLSessionDownloadTask}).first {
                self.completed = Set(UserDefaults.standard.stringArray(forKey:"verifiedPaths") ?? []); self.wantedFast = UserDefaults.standard.bool(forKey:"downloadFast"); self.active = task; self.downloading = true; self.busy = true; self.message = "Resuming model download"
                self.started = Date(); self.initialBytes = task.countOfBytesReceived; task.resume()
            } else { self.verify() }
        } }
    }
    deinit { securityURL?.stopAccessingSecurityScopedResource(); monitor.cancel() }
    var totalBytes: Int64 { manifest?.requiredBytes ?? 0 }
    var storedBytes: Int64 { manifest?.files.filter { completed.contains($0.path) }.reduce(0) { $0+$1.bytes } ?? 0 }
    var adapterBytes: Int64 { manifest?.files.filter(\.optional).reduce(0) { $0+$1.bytes } ?? 0 }
    func refreshSpace() {
        let values = try? folder.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey,.volumeAvailableCapacityKey])
        freeBytes = values?.volumeAvailableCapacityForImportantUsage ?? Int64(values?.volumeAvailableCapacity ?? 0)
    }
    private func saveBookmark(_ url: URL) throws {
        let data = try url.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)
        UserDefaults.standard.set(data,forKey:"modelBookmark")
    }
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount:8*1024*1024), !data.isEmpty { hash.update(data:data) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    static func valid(_ file: ModelFile, in folder: URL) throws -> Bool {
        let url = folder.appendingPathComponent(file.path)
        guard FileManager.default.fileExists(atPath:url.path) else { return false }
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard Int64(size) == file.bytes else { return false }
        return try digest(url) == file.sha256
    }
    /// Size and modification date of a file whose SHA-256 has already been checked. Re-hashing 12 GB on every
    /// launch would block generation for a minute or more, so unchanged files are trusted after one full check.
    static func fingerprint(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else { return nil }
        return "\(size):\(date.timeIntervalSince1970)"
    }
    private static func remember(_ path: String, folder: URL) {
        var records = UserDefaults.standard.dictionary(forKey:"verifiedFingerprints") as? [String:String] ?? [:]
        records[folder.standardizedFileURL.path + "|" + path] = fingerprint(folder.appendingPathComponent(path))
        UserDefaults.standard.set(records,forKey:"verifiedFingerprints")
    }
    func verify(full: Bool = false) {
        guard !downloading, let manifest else { return }
        busy = true; ready = false; fastReady = false; message = full ? "Verifying every model file. This can take several minutes." : "Checking model files"
        let location = folder
        io.async {
            var good = Set<String>()
            let records = UserDefaults.standard.dictionary(forKey:"verifiedFingerprints") as? [String:String] ?? [:]
            for (i,file) in manifest.files.enumerated() {
                let url = location.appendingPathComponent(file.path)
                let key = location.standardizedFileURL.path + "|" + file.path
                if !full, let known = records[key], let current = Self.fingerprint(url), known == current,
                   current.hasPrefix("\(file.bytes):") { good.insert(file.path); continue }
                DispatchQueue.main.async { self.message = "Verifying \(file.path)" }
                do { if try Self.valid(file,in:location) { good.insert(file.path); Self.remember(file.path,folder:location) } } catch { /* An unreadable file remains missing and can be downloaded again. */ }
                DispatchQueue.main.async { self.fraction = Double(i+1)/Double(manifest.files.count) }
            }
            DispatchQueue.main.async {
                self.completed = good; UserDefaults.standard.set(Array(good),forKey:"verifiedPaths"); self.busy = false; self.refreshStatus(); self.refreshSpace()
            }
        }
    }
    private func refreshStatus() {
        guard let manifest else { return }
        ready = manifest.files.filter { !$0.optional }.allSatisfy { completed.contains($0.path) }
        fastReady = manifest.files.filter(\.optional).allSatisfy { completed.contains($0.path) }
        message = ready ? "Model verified · ready offline" : "Model setup required"
    }
    func download(includeFast: Bool = false, allowCellular: Bool = false) {
        guard !busy, let manifest else { return }
        self.allowCellular = allowCellular; wantedFast = includeFast; UserDefaults.standard.set(includeFast,forKey:"downloadFast"); paused = false; refreshSpace()
        queue = manifest.files.filter { (!($0.optional) || includeFast) && !completed.contains($0.path) }
        let needed = queue.reduce(Int64(0)) { $0+$1.bytes }
        guard freeBytes > needed + 1_500_000_000 else { error = "Free at least \(AppPaths.bytes(needed+1_500_000_000)) before downloading. Moss needs room for temporary files too."; return }
        busy = true; downloading = true; next()
    }
    private func next() {
        guard !paused else { return }
        if queue.isEmpty {
            downloading = false; busy = false; active = nil; verify(); return
        }
        let file = queue.removeFirst()
        message = "Downloading \(file.path)"; fraction = 0; started = Date(); initialBytes = 0
        let resume = resumeURL(file.path)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf:resume) { task = session.downloadTask(withResumeData:data); try? FileManager.default.removeItem(at:resume) }
        else { var request = URLRequest(url:file.url); request.allowsCellularAccess = allowCellular; task = session.downloadTask(with:request) }
        task.taskDescription = file.path; active = task; task.resume()
    }
    private func resumeURL(_ path: String) -> URL {
        AppPaths.support.appendingPathComponent("resume-"+path.replacingOccurrences(of:"/",with:"_")+".data")
    }
    func pause() {
        guard let task = active else { return }
        paused = true
        task.cancel(byProducingResumeData: { data in
            if let data, let path = task.taskDescription { try? data.write(to:self.resumeURL(path),options:.atomic) }
            DispatchQueue.main.async { self.active = nil; self.downloading = false; self.busy = false; self.message = "Download paused. Tap Download to resume." }
        })
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten)/Double(totalBytesExpectedToWrite) : 0
        bytesPerSecond = Double(max(0,totalBytesWritten-initialBytes))/max(1,Date().timeIntervalSince(started))
        remainingSeconds = bytesPerSecond > 0 && totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite-totalBytesWritten)/bytesPerSecond : nil
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) { initialBytes = fileOffset; started = Date() }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let path = downloadTask.taskDescription, let file = manifest?.files.first(where:{$0.path == path}) else { return }
        let staged = AppPaths.support.appendingPathComponent(UUID().uuidString+".download")
        do {
            if let response = downloadTask.response as? HTTPURLResponse, !(200...299).contains(response.statusCode) { throw MossError.model("The download server returned \(response.statusCode). Try again later.") }
            try FileManager.default.moveItem(at:location,to:staged)
            pendingVerification += 1; message = "Checking \(file.path)"; active = nil
            let destinationFolder = folder
            io.async {
                do {
                    let size = try staged.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                    guard Int64(size) == file.bytes, try Self.digest(staged) == file.sha256 else { throw MossError.model("A downloaded file did not pass its integrity check. Tap Download to retry.") }
                    let destination = destinationFolder.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
                    if FileManager.default.fileExists(atPath:destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt:staged) }
                    else { try FileManager.default.moveItem(at:staged,to:destination) }
                    Self.remember(path,folder:destinationFolder)
                    DispatchQueue.main.async {
                        self.completed.insert(path); UserDefaults.standard.set(Array(self.completed),forKey:"verifiedPaths"); self.pendingVerification -= 1
                        self.refreshSpace(); self.finishBackgroundIfPossible()
                        if self.queue.isEmpty && self.downloading { self.queue = self.manifest?.files.filter { (!$0.optional || self.wantedFast) && !self.completed.contains($0.path) } ?? [] }
                        self.next()
                    }
                } catch {
                    try? FileManager.default.removeItem(at:staged)
                    DispatchQueue.main.async { self.pendingVerification -= 1; self.fail(error); self.finishBackgroundIfPossible() }
                }
            }
        } catch { try? FileManager.default.removeItem(at:staged); fail(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, !paused else { return }
        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data, let path = task.taskDescription { try? data.write(to:resumeURL(path),options:.atomic) }
        fail(MossError.model("Download stopped: \(error.localizedDescription) Tap Download to resume."))
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { backgroundEventsFinished = true; finishBackgroundIfPossible() }
    private func finishBackgroundIfPossible() { if backgroundEventsFinished && pendingVerification == 0, let completion = backgroundCompletion { backgroundEventsFinished = false; backgroundCompletion = nil; completion() } }
    private func fail(_ error: Error) { self.error = error.localizedDescription; busy = false; downloading = false; active = nil; message = "Download needs attention" }
    func chooseFolder(_ url: URL) {
        guard !busy else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        do {
            try saveBookmark(url)
            securityURL?.stopAccessingSecurityScopedResource(); securityURL = accessed ? url : nil
            folder = url; completed = []; verify()
        } catch { if accessed { url.stopAccessingSecurityScopedResource() }; self.error = error.localizedDescription }
    }
    func useAppFolder() {
        guard !busy else { return }
        securityURL?.stopAccessingSecurityScopedResource(); securityURL = nil
        UserDefaults.standard.removeObject(forKey:"modelBookmark"); folder = AppPaths.models
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); completed = []; verify()
    }
    func importFiles(from source: URL) {
        guard !busy, let manifest else { return }
        let access = source.startAccessingSecurityScopedResource(), target = folder
        busy = true; message = "Importing and verifying model files"
        io.async {
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                for file in manifest.files {
                    let origin = source.appendingPathComponent(file.path), destination = target.appendingPathComponent(file.path)
                    if origin.standardizedFileURL == destination.standardizedFileURL { continue }
                    guard FileManager.default.fileExists(atPath:origin.path) else { continue }
                    guard try Self.valid(file,in:source) else { throw MossError.model("The imported file \(file.path) is incomplete or belongs to a different model.") }
                    try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
                    let temporary = destination.appendingPathExtension("importing")
                    try? FileManager.default.removeItem(at:temporary)
                    try FileManager.default.copyItem(at:origin,to:temporary)
                    if FileManager.default.fileExists(atPath:destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt:temporary) }
                    else { try FileManager.default.moveItem(at:temporary,to:destination) }
                }
                DispatchQueue.main.async { self.busy = false; self.verify() }
            } catch { DispatchQueue.main.async { self.busy = false; self.error = "Import failed: \(error.localizedDescription) Check free space and make sure the source files are downloaded."; self.verify() } }
        }
    }
    func moveFiles(to target: URL) {
        guard !busy, let manifest else { return }
        let access = target.startAccessingSecurityScopedResource(), source = folder
        guard source.standardizedFileURL != target.standardizedFileURL else { if access { target.stopAccessingSecurityScopedResource() }; return }
        busy = true; message = "Moving model files"
        io.async {
            do {
                for file in manifest.files {
                    let origin = source.appendingPathComponent(file.path), destination = target.appendingPathComponent(file.path)
                    guard FileManager.default.fileExists(atPath:origin.path) else { continue }
                    guard !FileManager.default.fileExists(atPath:destination.path) else { throw MossError.model("The destination already contains model files. Choose an empty folder.") }
                    try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
                    try FileManager.default.copyItem(at:origin,to:destination)
                    guard try Self.valid(file,in:target) else { throw MossError.model("The moved file could not be verified. Your original files have been kept.") }
                }
                DispatchQueue.main.async {
                    do {
                        try self.saveBookmark(target)
                        self.securityURL?.stopAccessingSecurityScopedResource(); self.securityURL = access ? target : nil; self.folder = target
                        self.busy = false; self.verify()
                        self.io.async { for file in manifest.files { try? FileManager.default.removeItem(at:source.appendingPathComponent(file.path)) } }
                    } catch { if access { target.stopAccessingSecurityScopedResource() }; self.busy = false; self.error = error.localizedDescription }
                }
            } catch { if access { target.stopAccessingSecurityScopedResource() }; DispatchQueue.main.async { self.busy = false; self.error = "Move failed: \(error.localizedDescription) Your original files are still available." } }
        }
    }
    func deleteModel() {
        guard !busy, let manifest else { return }
        do {
            for file in manifest.files {
                let path = folder.appendingPathComponent(file.path)
                if FileManager.default.fileExists(atPath:path.path) { try FileManager.default.removeItem(at:path) }
                try? FileManager.default.removeItem(at:resumeURL(file.path))
            }
            completed = []; UserDefaults.standard.removeObject(forKey:"verifiedPaths"); refreshStatus(); refreshSpace()
        } catch { self.error = "Some files could not be deleted: \(error.localizedDescription)" }
    }
    func changeManifest(_ text: String) async {
        guard !busy else { return }
        guard let url = URL(string:text), url.scheme == "https", url.host == "huggingface.co", url.path.hasSuffix("/model-manifest.json") else { error = "Paste the full Hugging Face HTTPS address ending in /model-manifest.json."; return }
        busy = true
        do {
            let (data,response) = try await URLSession.shared.data(from:url)
            guard data.count < 128*1024, (response as? HTTPURLResponse)?.statusCode == 200 else { throw MossError.model("The model list could not be downloaded.") }
            let value = try JSONDecoder().decode(ModelManifest.self,from:data); try value.validate()
            await MainActor.run { UserDefaults.standard.set(data,forKey:"manifest"); self.manifest = value; self.busy = false; self.verify() }
        } catch { await MainActor.run { self.busy = false; self.error = error.localizedDescription } }
    }
}
