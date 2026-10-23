import SwiftUI
import UniformTypeIdentifiers

struct ModelControls: View {
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var app: AppModel
    @State private var showFolder = false
    @State private var action = "choose"
    @State private var confirmCellular = false
    @State private var confirmDelete = false
    @State private var manifestURL = ""
    @State private var advanced = false
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            NavigationLink {
                ZStack { Theme.canvas.ignoresSafeArea(); ScrollView { SetupView().padding(16) } }
                    .navigationTitle("Models").navigationBarTitleDisplayMode(.inline)
            } label: {
                LabeledContent("Models and downloads") {
                    Text(models.kromossReady ? "Base · Kromoss · Fast" : models.fastReady ? "Base · Fast" : models.ready ? "Base" : "Not downloaded").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Free space",value:AppPaths.bytes(models.freeBytes))
            Text(models.folder == AppPaths.models ? "Stored inside Moss" : "Folder: \(models.folder.lastPathComponent)").font(.callout).foregroundStyle(.secondary)
            if !models.busy {
                Menu("Choose storage or import files") {
                    Button("Use a folder in Files") { action = "choose"; showFolder = true }
                    Button("Use storage inside Moss") { models.useAppFolder() }
                    Button("Import a model folder") { action = "import"; showFolder = true }
                    Button("Move model to a folder") { action = "move"; showFolder = true }
                }.disabled(app.running)
                Text("For a Files folder, choose a folder under On My iPhone and keep the files downloaded. Cloud-only files cannot work offline. iOS may ask you to choose a folder again if access is revoked.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Model options",isExpanded:$advanced) {
                    VStack(alignment:.leading,spacing:16) {
                        Button("Verify all files") { models.verify(full:true) }
                        Button("Delete model files",role:.destructive) { confirmDelete = true }
                        Text("Deleting the model keeps your gallery. Tap Download afterward to re-download it.").font(.caption).foregroundStyle(.secondary)
                        TextField("Optional mirror manifest URL",text:$manifestURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Button("Use mirror") { Task { await models.changeManifest(manifestURL.trimmingCharacters(in:.whitespacesAndNewlines)) } }.disabled(manifestURL.isEmpty)
                    }.padding(.top,12)
                }.disabled(app.running)
            }
        }
        .fileImporter(isPresented:$showFolder,allowedContentTypes:[.folder]) { result in
            do {
                let url = try result.get()
                switch action { case "import": models.importFiles(from:url); case "move": models.moveFiles(to:url); default: models.chooseFolder(url) }
            } catch { if (error as NSError).code != NSUserCancelledError { models.error = error.localizedDescription } }
        }
        .confirmationDialog("Download using cellular data?",isPresented:$confirmCellular,titleVisibility:.visible) {
            Button("Download using cellular") { models.download(includeFast:true,allowCellular:true) }
            Button("Cancel",role:.cancel) {}
        } message: { Text("The complete model is about 12.1 GB, plus 1.2 GB for Fast. Your carrier may charge for this data.") }
        .confirmationDialog("Delete downloaded model files?",isPresented:$confirmDelete,titleVisibility:.visible) {
            Button("Delete model",role:.destructive) { models.deleteModel() }
        } message: { Text("Your gallery stays. You will need to download the model again before generating.") }
        .onAppear { models.refreshSpace() }
    }
}
struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var gallery: GalleryStore
    @AppStorage("autoSave") private var autoSave = false
    @AppStorage("haptics") private var haptics = true
    @AppStorage("defaultQuality") private var quality = "Fast"
    @AppStorage("defaultWidth") private var width = 1024
    @AppStorage("defaultHeight") private var height = 1024
    @State private var clear = false
    var body: some View {
        Form {
            Section("Model") { ModelControls().disabled(app.running) }
            Section("Defaults") {
                Picker("Quality",selection:$quality) { ForEach(Quality.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                Picker("Aspect ratio",selection:Binding(get:{"\(width)x\(height)"},set:{ value in let parts = value.split(separator:"x").compactMap { Int($0) }; if parts.count == 2 { width = parts[0]; height = parts[1] } })) {
                    ForEach(AspectPreset.all, id: \.label) { entry in Text(entry.label).tag("\(entry.width)x\(entry.height)") }
                }
                Text("Defaults apply the next time Moss opens.").font(.caption).foregroundStyle(.secondary)
                Toggle("Save to Photos automatically",isOn:$autoSave)
                Toggle("Haptics",isOn:$haptics)
            }
            Section("Gallery") { Button("Clear gallery",role:.destructive) { clear = true }.disabled(app.running || gallery.items.isEmpty) }
            Section("About") {
                LabeledContent("Version",value:"1.0.3 (4)")
                NavigationLink("Diagnostics") { DiagnosticsView() }
                Text("Offline generation. No analytics, tracking, or app account. Network access is used to download model files only.").font(.callout)
                Text("iPhone inference has not been validated by the project author on a physical device. A smaller image uses less memory. Keep the app open while generating.").font(.caption).foregroundStyle(.secondary)
                Link("MOSS model and license",destination:URL(string:"https://huggingface.co/OpenMOSS-Team/MOSS-Image-Base")!)
                Link("MLX conversion source",destination:URL(string:"https://github.com/felix-ab/moss-image-mlx")!)
            }
        }.navigationTitle("Settings").scrollContentBackground(.hidden).background(Theme.canvas)
            .confirmationDialog("Delete every image in Moss?",isPresented:$clear,titleVisibility:.visible) {
                Button("Delete all images",role:.destructive) { gallery.delete(Set(gallery.items.map(\.id))) }
            } message: { Text("This cannot be undone. Copies you saved to Photos are kept.") }
    }
}

/// The engine's timestamped log of recent runs, to screenshot or share when something goes wrong.
struct DiagnosticsView: View {
    @State private var text = RunLog.text
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "Nothing logged yet." : text)
                    .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                Color.clear.frame(height: 1).id("end")
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .background(Theme.canvas)
        .navigationTitle("Diagnostics").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { text = RunLog.text } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh")
                ShareLink(item: text.isEmpty ? "Nothing logged yet." : text) { Image(systemName: "square.and.arrow.up") }
                Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copy")
            }
        }
    }
}
