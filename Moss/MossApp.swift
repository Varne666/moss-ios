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
    init() {
        let m = ModelManager(), g = GalleryStore()
        _models = StateObject(wrappedValue:m); _gallery = StateObject(wrappedValue:g)
        _app = StateObject(wrappedValue:AppModel(models:m,gallery:g)); AppDelegate.attach(m)
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(models).environmentObject(gallery).environmentObject(app).tint(mossAccent)
                .onChange(of:phase) { _,value in if value == .active { app.returnedToScreen() } else { app.leftScreen() } }
                .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)) { _ in app.memoryWarning() }
        }
    }
}
