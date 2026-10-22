import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var gallery: GalleryStore
    var body: some View {
        TabView(selection:$app.tab) {
            NavigationStack { GeneratorView() }.tabItem { Label("Create",systemImage:"leaf") }.tag(0)
            NavigationStack { GalleryView() }.tabItem { Label("Gallery",systemImage:"square.grid.2x2") }.tag(1)
            NavigationStack { SettingsView() }.tabItem { Label("Settings",systemImage:"slider.horizontal.3") }.tag(2)
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .alert("Moss",isPresented:Binding(get:{app.error != nil || models.error != nil || gallery.error != nil},set:{ if !$0 { app.error = nil; models.error = nil; gallery.error = nil } })) {
            Button("OK",role:.cancel) { app.error = nil; models.error = nil; gallery.error = nil }
        } message: { Text(app.error ?? models.error ?? gallery.error ?? "") }
    }
}
struct MossCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(18).frame(maxWidth:.infinity,alignment:.leading).glassPanel() }
}
func durationText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "Calculating" }
    let value = Int(seconds)
    if value >= 3600 { return "\(value/3600)h \((value%3600)/60)m" }
    return value >= 60 ? "\(value/60)m \(value%60)s" : "\(value)s"
}
