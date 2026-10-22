import SwiftUI

/// One row of the download list: a model component made of one or more manifest files.
struct ModelGroup: Identifiable {
    let id: String
    let title: String
    let icon: String
    let files: [ModelFile]
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var optional: Bool { files.allSatisfy(\.optional) }

    static func all(_ manifest: ModelManifest) -> [ModelGroup] {
        let order: [(String, String, String)] = [
            ("tokenizer", "Tokenizer", "textformat"),
            ("transformer", "Image model", "cube.transparent"),
            ("vae", "Image decoder", "wand.and.rays"),
            ("text", "Text encoder", "text.bubble"),
            ("adapter", "Fast add-on", "bolt.fill"),
        ]
        return order.compactMap { id, title, icon in
            let files = manifest.files.filter { $0.component == id }
            return files.isEmpty ? nil : ModelGroup(id: id, title: title, icon: icon, files: files)
        }
    }
}

/// First-run screen: hero, overall progress and a live per-component download queue.
struct SetupView: View {
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var app: AppModel
    @AppStorage("includeFastDownload") private var includeFast = true
    @State private var confirmCellular = false

    var body: some View {
        VStack(spacing: 18) {
            MossOrb(energy: models.downloading ? 0.55 : 0.1, progress: models.downloading ? overallFraction : nil, busy: false)
                .frame(height: 230)
            VStack(spacing: 8) {
                Text(models.ready ? "Moss is ready" : "Grow Moss on your iPhone").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("A one-time \(AppPaths.bytes(wantedBytes)) download. After that every image is made on this iPhone, offline.")
                    .font(.callout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }
            overall
            queue
            controls
        }
        .foregroundStyle(Theme.textPrimary)
        .confirmationDialog("Download using cellular data?", isPresented: $confirmCellular, titleVisibility: .visible) {
            Button("Download using cellular") { models.download(includeFast: includeFast, allowCellular: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("About \(AppPaths.bytes(wantedBytes)). Your carrier may charge for this data.") }
        .onAppear { models.refreshSpace() }
    }

    private var groups: [ModelGroup] { models.manifest.map(ModelGroup.all) ?? [] }
    private var wantedGroups: [ModelGroup] { groups.filter { !$0.optional || includeFast || models.fastReady } }
    private var wantedBytes: Int64 { wantedGroups.reduce(0) { $0 + $1.bytes } }

    private func have(_ file: ModelFile) -> Int64 {
        switch models.state(of: file) {
        case .done, .checking: return file.bytes
        case .downloading(let n): return n
        case .queued(let n), .missing(let n): return n
        }
    }
    private func have(_ group: ModelGroup) -> Int64 { group.files.reduce(0) { $0 + have($1) } }
    private var overallFraction: Double {
        let total = wantedBytes
        return total > 0 ? Double(wantedGroups.reduce(0) { $0 + have($1) }) / Double(total) : 0
    }
    private func seconds(_ bytes: Int64) -> Double? {
        guard models.speed > 1000 else { return nil }
        let value = Double(bytes) / models.speed
        return value >= 1 ? value : nil
    }

    // MARK: Overall

    private var overall: some View {
        let fraction = overallFraction
        let left = wantedBytes - wantedGroups.reduce(0) { $0 + have($1) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
                if models.downloading, let s = seconds(left) {
                    Text("\(durationText(s)) left").font(.title3.weight(.semibold)).foregroundStyle(Theme.accent).monospacedDigit()
                } else if models.downloading {
                    Text("Measuring speed…").font(.callout).foregroundStyle(Theme.textSecondary)
                }
            }
            MossBar(value: fraction).animation(.easeOut(duration: 0.4), value: fraction)
            HStack {
                Text("\(AppPaths.bytes(wantedBytes - left)) of \(AppPaths.bytes(wantedBytes))").monospacedDigit()
                Spacer()
                if models.downloading, models.speed > 0 { Text("\(AppPaths.bytes(Int64(models.speed)))/s").monospacedDigit() }
                else { Text("\(AppPaths.bytes(models.freeBytes)) free") }
            }.font(.footnote).foregroundStyle(Theme.textSecondary)
        }
        .padding(18).glassPanel()
    }

    // MARK: Queue

    private var queue: some View {
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 62) }
                row(group)
            }
        }
        .padding(.vertical, 6).glassPanel()
    }

    private enum RowState { case done, active, checking, queued, idle, skipped }
    private func rowState(_ group: ModelGroup) -> RowState {
        let states = group.files.map { models.state(of: $0) }
        if states.allSatisfy({ $0 == .done }) { return .done }
        if states.contains(.checking) { return .checking }
        if states.contains(where: { if case .downloading = $0 { return true }; return false }) { return .active }
        if group.optional && !includeFast && !models.fastReady { return .skipped }
        if models.downloading { return .queued }
        return .idle
    }

    @ViewBuilder private func row(_ group: ModelGroup) -> some View {
        let state = rowState(group)
        let got = have(group), remaining = group.bytes - got
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(state == .active || state == .checking ? Theme.accent.opacity(0.16) : Theme.raised)
                Image(systemName: state == .done ? "checkmark" : group.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(state == .active || state == .checking ? Theme.accent : Theme.textSecondary)
            }.frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(group.title).font(.system(size: 16, weight: state == .active ? .bold : .semibold))
                    Spacer()
                    Text(trailing(state, group: group, got: got, remaining: remaining))
                        .font(.system(size: 14, weight: state == .active ? .semibold : .regular)).monospacedDigit()
                        .foregroundStyle(state == .active ? Theme.accent : Theme.textSecondary)
                }
                if state == .active || state == .checking {
                    MossBar(value: Double(got) / Double(max(1, group.bytes)))
                    Text(detail(state, group: group, got: got)).font(.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .foregroundStyle(state == .active || state == .checking ? Theme.textPrimary : Theme.textSecondary)
        .opacity(state == .done ? 0.38 : state == .queued || state == .skipped ? 0.62 : 1)
        .animation(.easeInOut(duration: 0.3), value: state)
        .accessibilityElement(children: .combine)
    }

    private func trailing(_ state: RowState, group: ModelGroup, got: Int64, remaining: Int64) -> String {
        switch state {
        case .done: return "Done · \(AppPaths.bytes(group.bytes))"
        case .checking: return "Checking"
        case .active: return seconds(remaining).map { "\(durationText($0)) left" } ?? "Starting…"
        case .queued: return seconds(remaining).map { "Queued · ~\(durationText($0))" } ?? "Queued · \(AppPaths.bytes(remaining))"
        case .skipped: return "Off · \(AppPaths.bytes(group.bytes))"
        case .idle: return AppPaths.bytes(remaining)
        }
    }
    private func detail(_ state: RowState, group: ModelGroup, got: Int64) -> String {
        if state == .checking { return "Verifying the download is intact" }
        let parts = group.files.filter { $0.bytes > 1_000_000 }
        let partIndex = parts.firstIndex { $0.path == models.currentPath }.map { $0 + 1 }
        let part = parts.count > 1 && partIndex != nil ? "Part \(partIndex!) of \(parts.count) · " : ""
        return part + "\(AppPaths.bytes(got)) of \(AppPaths.bytes(group.bytes))"
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 14) {
            if !models.ready || !models.fastReady {
                Toggle(isOn: $includeFast) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include Fast add-on").font(.subheadline.weight(.semibold))
                        Text("Recommended. Sharp 1-megapixel images in 8 steps.").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }.tint(Theme.accent).disabled(models.downloading)
            }
            Button {
                if models.downloading { models.pause() }
                else if models.cellular { confirmCellular = true }
                else { models.download(includeFast: includeFast) }
            } label: {
                Label(models.downloading ? "Pause" : (overallFraction > 0 ? "Resume download" : "Download"),
                      systemImage: models.downloading ? "pause.fill" : "arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlowButtonStyle(running: models.downloading))
            .disabled(models.busy && !models.downloading || app.running)
            if models.cellular { Label("You're on cellular or a metered network.", systemImage: "antenna.radiowaves.left.and.right").font(.caption).foregroundStyle(.orange) }
            Text(models.downloading ? "Keep Moss open while it downloads. If you leave, it picks up where it stopped." : models.message)
                .font(.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }
        .padding(18).glassPanel()
    }
}
