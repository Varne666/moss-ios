import SwiftUI
import UniformTypeIdentifiers

/// Realism controls: the Realistic Snapshot recipe, the snapshot prompt style, and imported LoRAs.
struct StyleSheet: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var loras: LoRAStore
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var showModels = false
    @State private var civitaiKey = ""

    private var snapshotLoRA: LoRAStore.Item? { loras.items.first { $0.name.localizedCaseInsensitiveContains("snapshot") } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { applyRecipe() } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Realistic Snapshot recipe", systemImage: "camera.fill").font(.headline)
                            Text("Kromoss · Fast DMD2 (8 steps, guidance 1) · snapshot wording · Realistic Snapshot LoRA at 1.0 · 9:16").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !models.kromossReady {
                        Button("Download the Kromoss realism model…") { showModels = true }
                    }
                    if snapshotLoRA == nil { snapshotDownload }
                } footer: { Text("From the MOSS-Image Kromoss Realism workflow. Its res_5s sampler is replaced by the Euler sampler Kromoss recommends for DMD2: the same 8 steps at a fifth of the work.") }

                Section("Prompt") {
                    Toggle(isOn: $app.settings.snapshotStyle) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Snapshot wording")
                            Text("Wraps your prompt in “amateur photo, candid photorealistic… natural iphone photo…”").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    if loras.items.isEmpty { Text("No LoRAs yet.").foregroundStyle(.secondary) }
                    ForEach(loras.items) { item in loraRow(item) }
                        .onDelete { offsets in for i in offsets { remove(loras.items[i]) } }
                    Button { importing = true } label: { Label(loras.importing ? "Importing…" : "Import LoRA (.safetensors)", systemImage: "square.and.arrow.down") }
                        .disabled(loras.importing)
                } header: { Text("LoRAs") } footer: { Text("MOSS-Image LoRAs only. Strength 0.6–1.2 is the usual range. Each LoRA adds a little time per step.") }
            }
            .scrollContentBackground(.hidden).background(Theme.canvas)
            .tint(Theme.accent)
            .navigationTitle("Style").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "safetensors") ?? .data, .data]) { result in
                if case .success(let url) = result { loras.importFile(url) }
            }
            .sheet(isPresented: $showModels) {
                NavigationStack { ZStack { Theme.canvas.ignoresSafeArea(); ScrollView { SetupView().padding(16) } }.navigationTitle("Models").navigationBarTitleDisplayMode(.inline) }
                    .environmentObject(models).environmentObject(app)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Realistic Snapshot needs a Civitai account: Moss downloads it with the user's own API key (kept in the
    /// Keychain), or the user downloads it in Safari and imports the file.
    @ViewBuilder private var snapshotDownload: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Get the Realistic Snapshot LoRA (580 MB)").font(.subheadline.weight(.semibold))
            Text("Civitai only lets signed-in accounts download it. Create a free API key on Civitai (Account settings → API Keys → Add API key), copy it, and paste it here. Moss keeps it in this iPhone's Keychain and only sends it to Civitai.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Open Civitai API keys", destination: URL(string: "https://civitai.com/user/account")!).font(.caption.weight(.semibold))
            if let f = loras.downloadFraction {
                ProgressView(value: f) { Text(f >= 1 ? "Checking file…" : "Downloading \(Int(f * 100))%").font(.caption) }
                Button("Cancel download", role: .cancel) { loras.cancelDownload() }.font(.caption)
            } else {
                SecureField("Civitai API key", text: $civitaiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onAppear { civitaiKey = loras.civitaiKey ?? "" }
                Button {
                    loras.civitaiKey = civitaiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    loras.downloadSnapshot()
                } label: { Label("Download Realistic Snapshot", systemImage: "arrow.down.circle.fill") }
                .disabled(civitaiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Or download the MOSS-Image version in Safari from civitai.com/models/2268008 and tap Import LoRA below.").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func choice(_ item: LoRAStore.Item) -> LoRAChoice? { app.settings.loras.first { $0.id == item.id } }
    @ViewBuilder private func loraRow(_ item: LoRAStore.Item) -> some View {
        let enabled = Binding(get: { choice(item) != nil }, set: { on in
            if on { if choice(item) == nil { app.settings.loras.append(.init(id: item.id, name: item.name, strength: 1)) } }
            else { app.settings.loras.removeAll { $0.id == item.id } }
        })
        let strength = Binding(get: { Double(choice(item)?.strength ?? 1) }, set: { v in
            if let i = app.settings.loras.firstIndex(where: { $0.id == item.id }) { app.settings.loras[i].strength = Float((v * 20).rounded() / 20) }
        })
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                    Text("\(AppPaths.bytes(item.bytes)) · \(item.layers) blocks\(item.rank.map { " · rank \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                }
            }
            if enabled.wrappedValue {
                HStack {
                    Slider(value: strength, in: 0...1.5)
                    Text(String(format: "%.2f", strength.wrappedValue)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
        }
    }
    private func remove(_ item: LoRAStore.Item) {
        app.settings.loras.removeAll { $0.id == item.id }
        loras.delete(item)
    }
    private func applyRecipe() {
        if models.kromossReady { app.settings.model = .kromoss }
        if models.fastReady { app.settings.preset(.fast) }
        app.settings.snapshotStyle = true
        app.settings.width = 768; app.settings.height = 1360
        if let item = snapshotLoRA {
            app.settings.loras.removeAll { $0.id == item.id }
            app.settings.loras.append(.init(id: item.id, name: item.name, strength: 1))
        }
        if !models.kromossReady { showModels = true } else { dismiss() }
    }
}
