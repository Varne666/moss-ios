import SwiftUI
import UIKit

/// Create screen: 3D hero (or the finished image), live countdown, and a studio-style composer.
struct GeneratorView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var models: ModelManager
    @State private var showAdvanced = false
    @State private var showImage = true
    @FocusState private var editing: Bool

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            RadialGradient(colors: [Theme.accentDeep.opacity(0.35), .clear], center: .top, startRadius: 0, endRadius: 420).ignoresSafeArea()
            if !models.ready {
                ScrollView { SetupView().padding(16).padding(.bottom, 90) }.scrollIndicators(.hidden)
            } else {
                VStack(spacing: 14) {
                    header
                    hero.frame(maxHeight: .infinity)
                    if let message = app.message, !app.running {
                        Text(message).font(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).padding(.horizontal, 8)
                    }
                    if app.running {
                        GenerationProgressCard(paused: app.paused, cooling: app.cooling, onStop: { app.cancel() }, runStart: app.runStart, estimatedEnd: app.estimatedEnd, status: statusLine, stageFraction: stageFraction)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        composer.transition(.opacity)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: app.running)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showAdvanced) { AdvancedSheet().environmentObject(app).presentationDetents([.medium, .large]).presentationBackground(Theme.panel) }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Moss").font(.system(size: 26, weight: .bold, design: .rounded))
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(app.running ? Theme.accent : Theme.accentDeep).frame(width: 7, height: 7)
                Text(app.running ? (app.backgroundCPU ? "Working slowly" : "Generating") : "Offline · Ready").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10).frame(height: 28).background(Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
        }
        .padding(.top, 6)
    }

    // MARK: Hero

    @ViewBuilder private var hero: some View {
        if let image = app.preview, showImage, !app.running {
            Image(uiImage: image).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                .overlay(alignment: .topTrailing) {
                    Button { withAnimation { showImage = false } } label: {
                        Image(systemName: "cube.transparent").font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34)
                            .background(.ultraThinMaterial, in: Circle())
                    }.padding(10).accessibilityLabel("Show the 3D orb")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Last generated image")
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            ZStack(alignment: .bottom) {
                if app.running {
                    // While the GPU is generating, a render-server animation replaces the 3D scene so the
                    // orb stays smooth and the model gets the whole GPU.
                    MossPulse(progress: orbProgress ?? 0, active: !app.paused && !app.cooling)
                } else {
                    MossOrb(energy: 0.15, progress: nil, busy: false)
                }
                if !app.running {
                    VStack(spacing: 6) {
                        Text(app.preview == nil ? "What should Moss grow?" : "Ready for the next one").font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("Drag the orb. Describe anything below.").font(.footnote).foregroundStyle(Theme.textSecondary)
                        if app.preview != nil {
                            Button("Show last image") { withAnimation { showImage = true } }.font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent).padding(.top, 2)
                        }
                    }.padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
    }
    private var orbProgress: Double? {
        guard let end = app.estimatedEnd else { return stageFraction }
        let total = end.timeIntervalSince(app.runStart)
        return total > 0 ? min(1, max(0, Date().timeIntervalSince(app.runStart) / total)) : nil
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !app.running {
                TextField("", text: $app.settings.prompt, prompt: Text("Describe your image, or paste a JSON layout…").foregroundStyle(Theme.textMuted), axis: .vertical)
                    .lineLimit(1...5).font(.system(size: 17)).tint(Theme.accent)
                    .focused($editing).autocorrectionDisabled().submitLabel(.return)
                    .accessibilityLabel("Image prompt")
                    .padding(.horizontal, 4).padding(.top, 4)
            }
            HStack(spacing: 8) {
                if !app.running {
                    Menu {
                        ForEach(AspectPreset.all, id: \.label) { entry in
                            Button { app.settings.width = entry.width; app.settings.height = entry.height } label: {
                                if currentAspect == entry.label { Label("\(entry.label)  ·  \(entry.width)×\(entry.height)", systemImage: "checkmark") }
                                else { Text("\(entry.label)  ·  \(entry.width)×\(entry.height)") }
                            }
                        }
                    } label: { ChipLabel(icon: "aspectratio", text: currentAspect ?? "\(app.settings.width)×\(app.settings.height)") }
                    Menu {
                        ForEach(Quality.allCases) { q in
                            Button { app.settings.preset(q) } label: {
                                Label(q.rawValue + (q == .fast ? "  ·  8 steps" : q == .balanced ? "  ·  30 steps" : "  ·  50 steps"), systemImage: app.settings.quality == q ? "checkmark" : qualityIcon(q))
                            }.disabled(q == .fast && !models.fastReady)
                        }
                    } label: { ChipLabel(icon: qualityIcon(app.settings.quality), text: app.settings.quality.rawValue) }
                    Button { showAdvanced = true } label: { ChipLabel(icon: "slider.horizontal.3", text: "") }
                        .accessibilityLabel("Advanced settings")
                }
                Spacer(minLength: 4)
                Button {
                    editing = false
                    if app.running { app.cancel() } else { app.generate() }
                } label: {
                    HStack(spacing: 6) {
                        Text(app.running ? "Stop" : "Generate").lineLimit(1)
                        Image(systemName: app.running ? "stop.fill" : "arrow.up")
                    }.fixedSize()
                }
                .buttonStyle(GlowButtonStyle(running: app.running))
                .disabled(models.busy || (!app.running && app.settings.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .accessibilityLabel(app.running ? "Stop generating" : "Generate image")
            }
        }
        .padding(14).glassPanel(radius: 28)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = false } } }
    }
    private var currentAspect: String? { AspectPreset.all.first { $0.width == app.settings.width && $0.height == app.settings.height }?.label }
    private func qualityIcon(_ q: Quality) -> String { q == .fast ? "bolt.fill" : q == .balanced ? "circle.lefthalf.filled" : "sparkles" }

    private var statusLine: String {
        if app.cooling { return "iPhone is hot. Moss continues as soon as it cools." }
        if app.paused { return "Paused. Keep Moss open to continue." }
        let p = app.progress
        let prefix = app.settings.count > 1 ? "Image \(app.imageNumber) of \(app.settings.count) · " : ""
        let suffix = app.backgroundCPU ? " · slower in background" : ""
        switch p.stage {
        case .encode: return prefix + "Reading your prompt" + suffix
        case .prepare: return prefix + "Preparing the image model" + suffix
        case .sample: return prefix + "Step \(min(p.index+1,p.total)) of \(p.total)" + suffix
        case .decode: return prefix + "Finishing the image" + suffix
        default: return prefix + "Starting"
        }
    }
    private var stageFraction: Double {
        let p = app.progress
        switch p.stage {
        case .encode: return 0.1 * Double(p.index) / Double(max(1,p.total))
        case .prepare: return 0.1
        case .sample: return 0.1 + 0.8 * Double(p.index) / Double(max(1,p.total))
        case .decode: return 0.9 + 0.1 * Double(p.index) / Double(max(1,p.total))
        default: return 0
        }
    }
}

/// Negative prompt, size, steps, guidance, seed and batch: everything beyond the chips.
struct AdvancedSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editing: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section("Negative prompt") {
                    TextField("Things to avoid (optional)", text: $app.settings.negativePrompt, axis: .vertical).lineLimit(2...5).focused($editing)
                    if app.settings.guidance == 1 { Text("Fast uses guidance 1, so the negative prompt has no effect.").font(.caption).foregroundStyle(.secondary) }
                }
                Section("Size") {
                    Stepper("Width  \(app.settings.width)", value: $app.settings.width, in: 256...1360, step: 16)
                    Stepper("Height  \(app.settings.height)", value: $app.settings.height, in: 256...1360, step: 16)
                    if app.settings.width * app.settings.height > 1_048_576 { Text("Keep width × height at or below 1,048,576 pixels.").font(.caption).foregroundStyle(.orange) }
                    else if app.settings.width * app.settings.height < 700_000 { Text("Below about 1 megapixel the model loses detail.").font(.caption).foregroundStyle(.secondary) }
                }
                Section("Sampling") {
                    Stepper("Steps  \(app.settings.steps)", value: $app.settings.steps, in: 1...100)
                    LabeledContent("Guidance") { TextField("Guidance", value: $app.settings.guidance, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($editing) }
                    LabeledContent("Shift") { TextField("Shift", value: $app.settings.shift, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($editing) }
                    Toggle("Skip layer 22 in negative branch", isOn: $app.settings.skipLayer)
                }
                Section("Seed and batch") {
                    Toggle("Lock seed", isOn: $app.settings.lockedSeed)
                    LabeledContent("Seed") { TextField("Seed", value: $app.settings.seed, format: .number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.trailing).focused($editing) }
                    Stepper("Images per run  \(app.settings.count)", value: $app.settings.count, in: 1...8)
                }
                Section { Button("Reset to \(app.settings.quality.rawValue) defaults") { app.settings.preset(app.settings.quality) } }
            }
            .scrollContentBackground(.hidden)
            .tint(Theme.accent)
            .navigationTitle("Advanced").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = false; dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

/// Countdown card shown while an image is being generated.
struct GenerationProgressCard: View {
    let paused: Bool
    var cooling = false
    var onStop: (() -> Void)? = nil
    let runStart: Date
    let estimatedEnd: Date?
    let status: String
    let stageFraction: Double
    var body: some View {
        MossCard {
            TimelineView(.periodic(from:.now,by:1)) { context in
                let now = context.date
                let total = estimatedEnd.map { $0.timeIntervalSince(runStart) } ?? 0
                let fraction: Double? = !paused && !cooling && estimatedEnd != nil && total > 0 ? min(0.99,max(0,now.timeIntervalSince(runStart)/total)) : nil
                VStack(alignment:.leading,spacing:12) {
                    HStack(alignment:.firstTextBaseline) {
                        if cooling {
                            Text("Cooling down").font(.system(.title,design:.rounded).weight(.semibold))
                        } else if paused {
                            Text("Paused").font(.system(.largeTitle,design:.rounded).weight(.semibold))
                        } else if let end = estimatedEnd {
                            Text(timerInterval:now...max(now,end),countsDown:true,showsHours:true)
                                .font(.system(.largeTitle,design:.rounded).weight(.semibold)).monospacedDigit()
                        } else {
                            Text("Estimating…").font(.system(.title,design:.rounded).weight(.semibold)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let fraction { Text(fraction,format:.percent.precision(.fractionLength(0))).font(.title3.weight(.medium)).monospacedDigit().foregroundStyle(mossAccent) }
                    }
                    MossBar(value:fraction ?? stageFraction).animation(.easeInOut(duration:0.8),value:fraction ?? stageFraction)
                    HStack(alignment:.firstTextBaseline) {
                        Text(status).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if let end = estimatedEnd, !paused, !cooling { Text("Done at \(end.formatted(date:.omitted,time:.shortened))").font(.callout).foregroundStyle(.secondary) }
                    }
                    if let onStop {
                        Button(action: onStop) { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(GlowButtonStyle(running: true)).padding(.top, 4)
                            .accessibilityLabel("Stop generating")
                    }
                }
                .accessibilityElement(children:.contain)
                .accessibilityLabel([status, fraction.map { "\(Int($0*100)) percent" }, estimatedEnd.map { "about \(durationText($0.timeIntervalSince(now))) left" }].compactMap { $0 }.joined(separator:", "))
            }
        }
    }
}

/// Thin rounded progress bar in the app accent (drawn with shapes so it looks identical everywhere).
struct MossBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment:.leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(mossAccent).frame(width:max(6,geo.size.width*min(1,max(0,value))))
            }
        }.frame(height:6).accessibilityHidden(true)
    }
}
