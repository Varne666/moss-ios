import Foundation
import CryptoKit
import Network
import Combine
import UIKit

final class ModelManager: NSObject, ObservableObject, URLSessionDataDelegate {
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
    /// File currently streaming, its bytes on disk, and a smoothed download speed (bytes/s).
    @Published var currentPath: String?
    @Published var currentReceived: Int64 = 0
    @Published var speed: Double = 0
    /// File being SHA-256 checked after download.
    @Published var checkingPath: String?
    @Published private(set) var wantedFast = false
    /// Earlier builds used a background URLSession; iOS may still deliver its events once. Nothing to finish.
    var backgroundCompletion: (() -> Void)? { didSet { backgroundCompletion?(); backgroundCompletion = nil } }
    private var completed = Set<String>()
    var completedPaths: Set<String> { completed }
    private var active: URLSessionDataTask?
    private var handle: FileHandle?
    private var currentFile: ModelFile?
    private var received: Int64 = 0
    private var retries = 0
    private var lastUIUpdate = Date.distantPast
    private var lastUIBytes: Int64 = 0
    private var resumeWhenActive = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var queue: [ModelFile] = []
    private var allowCellular = false
    private var paused = false
    private var securityURL: URL?
    private var started = Date()
    private var initialBytes: Int64 = 0
    private var pendingVerification = 0
    private let io = DispatchQueue(label:"Moss.modelIO",qos:.utility)
    private let monitor = NWPathMonitor()
    /// Moss writes downloads straight into its own model folder as `<file>.part` and resumes them with HTTP
    /// Range requests. (iOS's background download service could not create its temporary files for re-signed
    /// installs, which stopped downloads with "Cannot create file".)
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.name = "Moss.download"
        return URLSession(configuration:config,delegate:self,delegateQueue:queue)
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
        verify()
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
    /// The app's own storage path contains a container ID that can change when iOS updates or re-signs the
    /// app, so it is keyed by name; otherwise unchanged files would be re-verified as if new.
    static func folderKey(_ folder: URL) -> String {
        folder.standardizedFileURL.path == AppPaths.models.standardizedFileURL.path ? "moss-app-models" : folder.standardizedFileURL.path
    }
    private static func remember(_ path: String, folder: URL) {
        var records = UserDefaults.standard.dictionary(forKey:"verifiedFingerprints") as? [String:String] ?? [:]
        records[folderKey(folder) + "|" + path] = fingerprint(folder.appendingPathComponent(path))
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
                let key = Self.folderKey(location) + "|" + file.path
                // Earlier builds keyed records by the full container path; accept those too (same size and date).
                let known = records[key] ?? records.first { $0.key.hasSuffix("|" + file.path) && $0.value == Self.fingerprint(url) }?.value
                if !full, let known, let current = Self.fingerprint(url), known == current,
                   current.hasPrefix("\(file.bytes):") { good.insert(file.path); Self.remember(file.path,folder:location); continue }
                DispatchQueue.main.async { self.message = "Checking \(file.path)"; self.checkingPath = file.path }
                do { if try Self.valid(file,in:location) { good.insert(file.path); Self.remember(file.path,folder:location) } } catch { /* An unreadable file remains missing and can be downloaded again. */ }
                DispatchQueue.main.async { self.fraction = Double(i+1)/Double(manifest.files.count) }
            }
            DispatchQueue.main.async {
                self.completed = good; UserDefaults.standard.set(Array(good),forKey:"verifiedPaths"); self.busy = false; self.checkingPath = nil; self.refreshStatus(); self.refreshSpace()
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
        let needed = queue.reduce(Int64(0)) { total, file in total + max(0, file.bytes - partialBytes(file)) }
        guard freeBytes > needed + 1_500_000_000 else { error = "Free at least \(AppPaths.bytes(needed+1_500_000_000)) before downloading. Moss needs room for checking the files too."; return }
        busy = true; downloading = true; retries = 0; resumeWhenActive = false
        UIApplication.shared.isIdleTimerDisabled = true
        next()
    }
    private func partURL(_ file: ModelFile) -> URL { folder.appendingPathComponent(file.path + ".part") }
    func partialBytes(_ file: ModelFile) -> Int64 {
        Int64((try? partURL(file).resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)
    }
    private func next() {
        guard !paused else { return }
        guard let file = queue.first else {
            downloading = false; busy = false; active = nil; currentFile = nil; currentPath = nil; speed = 0
            UIApplication.shared.isIdleTimerDisabled = false; endBackgroundTime(); verify(); return
        }
        message = "Downloading \(file.path)"; started = Date()
        // A complete file already in place (from an earlier install or an interrupted check) is verified,
        // never downloaded again.
        let destination = folder.appendingPathComponent(file.path)
        if let size = try? destination.resourceValues(forKeys:[.fileSizeKey]).fileSize, Int64(size) == file.bytes {
            adoptExisting(file); return
        }
        do {
            let part = partURL(file)
            try FileManager.default.createDirectory(at:part.deletingLastPathComponent(),withIntermediateDirectories:true)
            if !FileManager.default.fileExists(atPath:part.path) { FileManager.default.createFile(atPath:part.path,contents:nil) }
            var have = partialBytes(file)
            let writer = try FileHandle(forWritingTo:part)
            if have > file.bytes { try writer.truncate(atOffset:0); have = 0 }
            try writer.seekToEnd()
            received = have; initialBytes = have
            fraction = Double(have)/Double(max(1,file.bytes))
            if have == file.bytes { try writer.close(); finished(file); return }
            handle = writer; currentFile = file
            currentPath = file.path; currentReceived = have; lastUIBytes = have; lastUIUpdate = Date()
            var request = URLRequest(url:file.url)
            request.allowsCellularAccess = allowCellular
            if have > 0 { request.setValue("bytes=\(have)-",forHTTPHeaderField:"Range") }
            let task = session.dataTask(with:request); task.taskDescription = file.path
            active = task; beginBackgroundTime(); task.resume()
        } catch { fail(MossError.model("Moss could not write \(file.path): \(error.localizedDescription)")) }
    }
    func pause() {
        guard let task = active else { return }
        paused = true; task.cancel(); currentPath = nil; speed = 0
        active = nil; downloading = false; busy = false; message = "Download paused. Tap Download to resume."
        UIApplication.shared.isIdleTimerDisabled = false; endBackgroundTime()
    }
    /// Called when Moss returns to the screen: a download that iOS interrupted in the background continues.
    func resumeIfInterrupted() {
        guard resumeWhenActive, !busy else { return }
        resumeWhenActive = false; error = nil
        download(includeFast:wantedFast,allowCellular:allowCellular)
    }
    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName:"Moss model download") { [weak self] in self?.endBackgroundTime() }
    }
    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }

    // MARK: URLSession (runs on the serial download queue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        if http.statusCode == 200, received > 0 {
            // The server ignored the Range request and is sending the whole file: start the part file over.
            do { try handle?.truncate(atOffset:0); received = 0 } catch { completionHandler(.cancel); return }
        } else if !(http.statusCode == 200 || http.statusCode == 206) {
            DispatchQueue.main.async { self.fail(MossError.model("The download server returned \(http.statusCode). Tap Download to try again.")) }
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle else { return }
        do { try handle.write(contentsOf:data); received += Int64(data.count) }
        catch { dataTask.cancel(); DispatchQueue.main.async { self.fail(MossError.model("Moss could not save the download: \(error.localizedDescription)")) }; return }
        let now = Date()
        guard now.timeIntervalSince(lastUIUpdate) > 0.3, let file = currentFile else { return }
        let interval = now.timeIntervalSince(lastUIUpdate), delta = received - lastUIBytes
        lastUIUpdate = now; lastUIBytes = received
        let got = received, base = initialBytes, since = started
        DispatchQueue.main.async {
            self.fraction = Double(got)/Double(max(1,file.bytes))
            self.currentReceived = got
            self.bytesPerSecond = Double(max(0,got-base))/max(1,now.timeIntervalSince(since))
            let instant = Double(max(0,delta))/max(0.05,interval)
            self.speed = self.speed == 0 ? instant : self.speed * 0.9 + instant * 0.1
            self.remainingSeconds = self.speed > 0 ? Double(file.bytes-got)/self.speed : nil
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize(); try? handle?.close(); handle = nil
        let got = received
        DispatchQueue.main.async {
            guard self.active === task else { return }
            self.active = nil
            guard let file = self.currentFile else { return }
            if self.paused { return }
            if let error {
                let inBackground = UIApplication.shared.applicationState != .active
                if inBackground {
                    self.resumeWhenActive = true; self.downloading = false; self.busy = false; self.endBackgroundTime()
                    self.message = "Download paused while Moss was closed. It continues when you open Moss."
                } else if self.retries < 6 {
                    self.retries += 1; self.message = "Connection interrupted. Retrying…"
                    DispatchQueue.main.asyncAfter(deadline:.now() + Double(self.retries * 3)) { if self.downloading && !self.paused { self.next() } }
                } else {
                    self.fail(MossError.model("Download stopped: \(error.localizedDescription) Tap Download to resume; finished parts are kept."))
                }
                return
            }
            if got == file.bytes { self.retries = 0; self.finished(file) }
            else { self.retries += 1; if self.retries < 6 { self.next() } else { self.fail(MossError.model("The download ended early. Tap Download to resume.")) } }
        }
    }
    private func adoptExisting(_ file: ModelFile) {
        let destinationFolder = folder, path = file.path
        pendingVerification += 1; checkingPath = path; message = "Checking \(path)"
        io.async {
            let ok = (try? Self.valid(file,in:destinationFolder)) ?? false
            if ok { Self.remember(path,folder:destinationFolder) } else { try? FileManager.default.removeItem(at:destinationFolder.appendingPathComponent(path)) }
            DispatchQueue.main.async {
                self.pendingVerification -= 1; self.checkingPath = nil
                if ok { self.completed.insert(path); UserDefaults.standard.set(Array(self.completed),forKey:"verifiedPaths"); self.queue.removeAll { $0.path == path } }
                self.next()
            }
        }
    }
    private func finished(_ file: ModelFile) {
        let part = partURL(file), destinationFolder = folder, path = file.path
        pendingVerification += 1; message = "Checking \(file.path)"; currentFile = nil; checkingPath = file.path; currentPath = nil
        io.async {
            do {
                let size = try part.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                guard Int64(size) == file.bytes, try Self.digest(part) == file.sha256 else {
                    try? FileManager.default.removeItem(at:part)
                    throw MossError.model("\(path) did not pass its integrity check, so it was discarded. Tap Download to fetch it again.")
                }
                let destination = destinationFolder.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath:destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt:part) }
                else { try FileManager.default.moveItem(at:part,to:destination) }
                Self.remember(path,folder:destinationFolder)
                DispatchQueue.main.async {
                    self.pendingVerification -= 1; self.checkingPath = nil
                    self.completed.insert(path); UserDefaults.standard.set(Array(self.completed),forKey:"verifiedPaths")
                    self.queue.removeAll { $0.path == path }
                    self.refreshSpace(); self.next()
                }
            } catch { DispatchQueue.main.async { self.pendingVerification -= 1; self.checkingPath = nil; self.fail(error) } }
        }
    }
    private func fail(_ error: Error) {
        currentPath = nil; speed = 0
        self.error = error.localizedDescription; busy = false; downloading = false; active?.cancel(); active = nil; currentFile = nil
        message = "Download needs attention"; UIApplication.shared.isIdleTimerDisabled = false; endBackgroundTime()
    }
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
                try? FileManager.default.removeItem(at:partURL(file))
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

extension ModelManager {
    enum FileState: Equatable { case done, downloading(Int64), checking, queued(Int64), missing(Int64) }
    /// Display state of one manifest file for the download list.
    func state(of file: ModelFile) -> FileState {
        if completedPaths.contains(file.path) { return .done }
        if checkingPath == file.path { return .checking }
        if currentPath == file.path { return .downloading(currentReceived) }
        let partial = partialBytes(file)
        return downloading && (!file.optional || wantedFast) ? .queued(partial) : .missing(partial)
    }
}
