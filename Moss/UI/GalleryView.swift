import SwiftUI
import UIKit

struct ShareItems: Identifiable { let id = UUID(); let urls: [URL] }
struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context:Context) -> UIActivityViewController { UIActivityViewController(activityItems:urls,applicationActivities:nil) }
    func updateUIViewController(_ controller:UIActivityViewController,context:Context) {}
}
struct GalleryView: View {
    @EnvironmentObject var gallery: GalleryStore
    @EnvironmentObject var app: AppModel
    @State private var selection = Set<UUID>()
    @State private var selecting = false
    @State private var detail: GalleryItem?
    @State private var share: ShareItems?
    @State private var delete = false
    @State private var favorites = false
    var visible: [GalleryItem] { gallery.items.filter { !favorites || $0.favorite } }
    var selected: [GalleryItem] { gallery.items.filter { selection.contains($0.id) } }
    var body: some View {
        Group {
            if visible.isEmpty {
                ContentUnavailableView {
                    Label(favorites ? "No favorites yet" : "Your images will grow here",systemImage:favorites ? "heart" : "leaf")
                } description: { Text(favorites ? "Open an image and tap Favorite." : "Create your first image in Moss.") } actions: { Button(favorites ? "Show all images" : "Create an image") { if favorites { favorites = false } else { app.tab = 0 } }.buttonStyle(.borderedProminent) }
            } else {
                ScrollView {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:144),spacing:8)],spacing:8) {
                        ForEach(visible) { item in
                            Button { if selecting { if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) } } else { detail = item } } label: {
                                ZStack(alignment:.bottomTrailing) {
                                    if let image = UIImage(contentsOfFile:gallery.thumbnail(item).path) ?? UIImage(contentsOfFile:gallery.file(item).path) {
                                        Image(uiImage:image).resizable().scaledToFill().frame(height:168).clipped()
                                    } else { Color.secondary.frame(height:168).overlay(Image(systemName:"photo")) }
                                    if selecting { Image(systemName:selection.contains(item.id) ? "checkmark.circle.fill" : "circle").font(.title2).padding(8).background(.thinMaterial,in:Circle()).padding(8) }
                                    else if item.favorite { Image(systemName:"heart.fill").padding(8).background(.thinMaterial,in:Circle()).padding(8) }
                                }.clipShape(RoundedRectangle(cornerRadius:16)).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(item.settings.prompt).accessibilityHint(selecting ? "Select image" : "Open image")
                        }
                    }.padding(16)
                }
            }
        }.navigationTitle("Gallery").background(Theme.canvas)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { Button { favorites.toggle() } label: { Image(systemName:favorites ? "heart.fill" : "heart") }.accessibilityLabel(favorites ? "Show all images" : "Show favorites") }
                ToolbarItem(placement:.topBarTrailing) { Button(selecting ? "Done" : "Select") { selecting.toggle(); selection = [] }.disabled(gallery.items.isEmpty) }
            }
            .safeAreaInset(edge:.bottom) {
                if selecting {
                    HStack(spacing:24) {
                        Button { Task { do { try await gallery.saveToPhotos(selected); app.message = "Selected images saved to Photos." } catch { gallery.error = error.localizedDescription } } } label: { Label("Save",systemImage:"square.and.arrow.down") }
                        Button { share = ShareItems(urls:selected.map(gallery.file)) } label: { Label("Share",systemImage:"square.and.arrow.up") }
                        Button(role:.destructive) { delete = true } label: { Label("Delete",systemImage:"trash") }
                    }.labelStyle(.iconOnly).font(.title2).padding(20).frame(maxWidth:.infinity).background(.bar).disabled(selection.isEmpty)
                }
            }
            .sheet(item:$detail) { item in NavigationStack { ImageDetail(item:item) }.environmentObject(gallery).environmentObject(app) }
            .sheet(item:$share) { ShareSheet(urls:$0.urls) }
            .confirmationDialog("Delete \(selection.count) selected images?",isPresented:$delete,titleVisibility:.visible) { Button("Delete",role:.destructive) { gallery.delete(selection); selection = [] } }
    }
}
struct ImageDetail: View {
    let item: GalleryItem
    @EnvironmentObject var gallery: GalleryStore
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var info = false
    @State private var share: ShareItems?
    @State private var delete = false
    @State private var saved = false
    var current: GalleryItem { gallery.items.first(where:{$0.id == item.id}) ?? item }
    var body: some View {
        VStack(spacing:0) {
            ZoomImage(url:gallery.file(item)).accessibilityLabel(item.settings.prompt)
            if info {
                ScrollView {
                    VStack(alignment:.leading,spacing:12) {
                        Text(item.settings.prompt).textSelection(.enabled)
                        if !item.settings.negativePrompt.isEmpty { Text("Negative: \(item.settings.negativePrompt)").foregroundStyle(.secondary).textSelection(.enabled) }
                        Text("\(item.settings.width) × \(item.settings.height) · \(item.settings.quality.rawValue) · \(item.settings.steps) steps\nGuidance \(item.settings.guidance) · Shift \(item.settings.shift)\nSeed \(String(item.settings.seed)) · Layer skip \(item.settings.skipLayer ? "on" : "off")\n\(durationText(item.seconds)) · \(item.created.formatted())").font(.callout).textSelection(.enabled)
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
                }.frame(maxHeight:240)
            }
            Button("Reuse settings") { app.reuse(item); if !app.running { dismiss() } }.buttonStyle(.borderedProminent).padding(16)
        }.navigationTitle("Image").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement:.topBarTrailing) { Button { info.toggle() } label: { Image(systemName:"info.circle") }.accessibilityLabel("Prompt and settings") }
                ToolbarItem(placement:.bottomBar) {
                    HStack(spacing:24) {
                        Button { gallery.toggleFavorite(current) } label: { Image(systemName:current.favorite ? "heart.fill" : "heart") }.accessibilityLabel("Favorite")
                        Button { Task { do { try await gallery.saveToPhotos([item]); saved = true } catch { gallery.error = error.localizedDescription } } } label: { Image(systemName:"square.and.arrow.down") }.accessibilityLabel("Save to Photos")
                        Button { UIPasteboard.general.image = UIImage(contentsOfFile:gallery.file(item).path) } label: { Image(systemName:"doc.on.doc") }.accessibilityLabel("Copy image")
                        Button { share = ShareItems(urls:[gallery.file(item)]) } label: { Image(systemName:"square.and.arrow.up") }.accessibilityLabel("Share image")
                        Button(role:.destructive) { delete = true } label: { Image(systemName:"trash") }.accessibilityLabel("Delete image")
                    }
                }
            }
            .sheet(item:$share) { ShareSheet(urls:$0.urls) }
            .confirmationDialog("Delete this image?",isPresented:$delete,titleVisibility:.visible) { Button("Delete",role:.destructive) { gallery.delete([item.id]); dismiss() } }
            .alert("Saved to Photos",isPresented:$saved) { Button("OK",role:.cancel) {} }
            .alert("Could not save",isPresented:Binding(get:{gallery.error != nil},set:{if !$0 {gallery.error = nil}})) { Button("OK",role:.cancel) {gallery.error = nil} } message:{Text(gallery.error ?? "")}
    }
}
struct ZoomImage: UIViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context:Context) -> UIScrollView {
        let scroll = UIScrollView(); scroll.delegate = context.coordinator; scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        let image = UIImageView(image:UIImage(contentsOfFile:url.path)); image.contentMode = .scaleAspectFit
        image.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(image)
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor),image.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor),image.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor),image.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor),image.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor),image.heightAnchor.constraint(equalTo:scroll.frameLayoutGuide.heightAnchor)])
        context.coordinator.image = image
        let tap = UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.doubleTap(_:))); tap.numberOfTapsRequired = 2; scroll.addGestureRecognizer(tap)
        return scroll
    }
    func updateUIView(_ view:UIScrollView,context:Context) {}
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var image: UIImageView?
        func viewForZooming(in scrollView:UIScrollView) -> UIView? { image }
        @objc func doubleTap(_ gesture:UITapGestureRecognizer) { guard let scroll = gesture.view as? UIScrollView else { return }; scroll.setZoomScale(scroll.zoomScale > 1 ? 1 : 2,animated:true) }
    }
}
