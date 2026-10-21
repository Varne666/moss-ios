import SwiftUI
import UIKit

struct GeneratorView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var models: ModelManager
    @State private var advanced = false
    @State private var negative = false
    @State private var custom = false
    @FocusState private var editing: Bool
    private let ratios: [(String,Int,Int)] = [("1:1",512,512),("9:16",432,768),("16:9",768,432),("4:3",640,480),("3:4",480,640),("2:3",512,768),("3:2",768,512)]
    var body: some View {
        ScrollView {
            VStack(spacing:16) {
                if !models.ready {
                    SetupView()
                } else {
                    preview
                    if let message = app.message {
                        Text(message).font(.callout).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
                    }
                    if app.running { progress }
                    controls.disabled(app.running)
                }
            }.padding(16)
        }
        .background(Color(uiColor:.systemGroupedBackground))
        .navigationTitle("Moss")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge:.bottom) {
            if models.ready {
                VStack(spacing:12) {
                    if !app.running {
                        TextField("Describe your image, or paste a JSON layout…",text:$app.settings.prompt,axis:.vertical)
                            .lineLimit(2...6).padding(16).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:20))
                            .focused($editing).accessibilityLabel("Image prompt").autocorrectionDisabled()
                    }
                    Button {
                        editing = false
                        if app.running { app.cancel() } else {
                            app.settings.width = max(256,min(1536,Int((Double(app.settings.width)/16).rounded())*16))
                            app.settings.height = max(256,min(1536,Int((Double(app.settings.height)/16).rounded())*16))
                            app.generate()
                        }
                    } label: {
                        Label(app.running ? "Cancel" : "Generate",systemImage:app.running ? "stop" : "leaf")
                            .font(.headline).frame(maxWidth:.infinity).padding(.vertical,8)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(models.busy)
                }.padding(16).background(.bar)
            }
        }
        .toolbar { ToolbarItemGroup(placement:.keyboard) { Spacer(); Button("Done") { editing = false } } }
    }
    private var preview: some View {
        Group {
            if let image = app.preview {
                Image(uiImage:image).resizable().scaledToFit().accessibilityLabel("Last generated image")
            } else {
                VStack(spacing:16) {
                    Image(systemName:"leaf").font(.system(size:44,weight:.light)).foregroundStyle(mossAccent).accessibilityHidden(true)
                    Text(app.running ? "Your image is on its way" : "A little space for your imagination").font(.title3).multilineTextAlignment(.center)
                    Text(app.running ? "Keep Moss open. The first run may take a long time." : "Describe a scene below to begin.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(32).frame(maxWidth:.infinity,minHeight:240)
            }
        }.clipShape(RoundedRectangle(cornerRadius:24,style:.continuous))
            .background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:24))
    }
    private var progress: some View {
        MossCard {
            VStack(alignment:.leading,spacing:8) {
                Text(app.progress.message).font(.headline)
                if let value = app.progress.fraction { ProgressView(value:value) } else { ProgressView() }
                if let seconds = app.progress.remaining { Text("About \(durationText(seconds)) left for sampling").font(.callout).foregroundStyle(.secondary) }
                Text("Preview appears after decoding.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var controls: some View {
        MossCard {
            VStack(alignment:.leading,spacing:16) {
                Text("Size").font(.headline)
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:8) {
                        ForEach(ratios,id:\.0) { entry in
                            let (label,w,h) = entry
                            Button { app.settings.width = w; app.settings.height = h; custom = false } label: {
                                VStack(spacing:8) {
                                    RoundedRectangle(cornerRadius:3).stroke(lineWidth:1.5).frame(width:28*min(1,CGFloat(w)/CGFloat(h)),height:28*min(1,CGFloat(h)/CGFloat(w))).frame(width:32,height:32)
                                    Text(label).font(.caption)
                                }.frame(width:52,height:64)
                            }.buttonStyle(.bordered).tint(app.settings.width == w && app.settings.height == h ? mossAccent : .secondary)
                                .accessibilityLabel("\(label), \(w) by \(h)")
                        }
                        Button("Custom") { custom.toggle() }.buttonStyle(.bordered)
                    }
                }
                Text("\(app.settings.width) × \(app.settings.height)").font(.callout).foregroundStyle(.secondary)
                if custom {
                    HStack {
                        dimension("Width",value:$app.settings.width)
                        dimension("Height",value:$app.settings.height)
                    }
                    Text("Sizes round to the nearest multiple of 16. Start at 512 × 512.").font(.caption).foregroundStyle(.secondary)
                }
                if app.settings.width*app.settings.height > 768*768 {
                    Label("Large image: experimental on iPhone. Memory use and time increase.",systemImage:"exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                Picker("Quality",selection:Binding(get:{app.settings.quality},set:{app.settings.preset($0)})) {
                    ForEach(Quality.allCases) { q in Text(q.rawValue).tag(q) }
                }.pickerStyle(.segmented)
                Text(app.settings.quality == .fast ? "8-step distilled adapter. Requires its optional download." : app.settings.quality == .best ? "Official settings: 50 steps, guidance 3, shift 5, negative layer 22 skipped." : "20 steps using the Base model. A compromise between detail and time.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Negative prompt",isExpanded:$negative) {
                    TextField("Things to avoid (optional)",text:$app.settings.negativePrompt,axis:.vertical).lineLimit(2...5).focused($editing).padding(.top,8)
                    if app.settings.guidance == 1 { Text("Guidance is 1, so the negative branch is unused.").font(.caption).foregroundStyle(.secondary) }
                }
                DisclosureGroup("Advanced",isExpanded:$advanced) { advancedControls.padding(.top,12) }
            }
        }
    }
    private func dimension(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment:.leading) {
            Text(label).font(.caption)
            TextField(label,value:value,format:.number).keyboardType(.numberPad).textFieldStyle(.roundedBorder).focused($editing)
                .onChange(of:editing) { _,isEditing in if !isEditing { value.wrappedValue = max(256,min(1536,Int((Double(value.wrappedValue)/16).rounded())*16)) } }
        }
    }
    private var advancedControls: some View {
        VStack(alignment:.leading,spacing:16) {
            Stepper("Steps: \(app.settings.steps)",value:$app.settings.steps,in:1...100)
            HStack { Text("Guidance"); Spacer(); TextField("Guidance",value:$app.settings.guidance,format:.number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width:88).focused($editing) }
            HStack { Text("Shift"); Spacer(); TextField("Shift",value:$app.settings.shift,format:.number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width:88).focused($editing) }
            Toggle("Skip layer 22 in negative branch",isOn:$app.settings.skipLayer)
            Toggle("Lock seed",isOn:$app.settings.lockedSeed)
            HStack {
                TextField("Seed",value:$app.settings.seed,format:.number).keyboardType(.numberPad).focused($editing)
                Button { UIPasteboard.general.string = String(app.settings.seed) } label: { Image(systemName:"doc.on.doc") }.accessibilityLabel("Copy seed")
            }
            Stepper("Images per run: \(app.settings.count)",value:$app.settings.count,in:1...8)
            Text("Images run one at a time. A locked seed increases by one for each image. Changing advanced values overrides the preset settings.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
