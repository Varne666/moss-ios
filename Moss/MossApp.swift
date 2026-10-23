import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static weak var manager: ModelManager?
    private static var pending: (() -> Void)?
    static func attach(_ manager: ModelManager) { self.manager = manager; if let pending { manager.backgroundCompletion = pending; self.pending = nil } }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if let manager = Self.manager { manager.backgroundCompletion = completionHandler }
        else { Self.pending = completionHandler }
    }
}
@main struct MossApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    @StateObject private var models: ModelManager
    @StateObject private var gallery: GalleryStore
    @StateObject private var app: AppModel
    @StateObject private var loras: LoRAStore
    init() {
        let m = ModelManager(), g = GalleryStore(), l = LoRAStore()
        _models = StateObject(wrappedValue:m); _gallery = StateObject(wrappedValue:g); _loras = StateObject(wrappedValue:l)
        _app = StateObject(wrappedValue:AppModel(models:m,gallery:g,loras:l)); AppDelegate.attach(m)
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(models).environmentObject(gallery).environmentObject(app).environmentObject(loras).tint(Theme.accent).preferredColorScheme(.dark)
                .onChange(of:phase) { _,value in if value == .active { app.returnedToScreen(); models.resumeIfInterrupted() } else { app.leftScreen() } }
                .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)) { _ in app.memoryWarning() }
        }
    }
}
