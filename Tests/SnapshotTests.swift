import XCTest
import SwiftUI
@testable import Moss

/// Renders the progress UI to PNGs (written to $SNAPSHOT_DIR when set) so the design can be reviewed from CI.
@MainActor final class SnapshotTests: XCTestCase {
    private func render<V: View>(_ name: String, _ view: V, width: CGFloat, dark: Bool) throws {
        let framed = view.frame(width: width).padding(16)
            .background(dark ? Color.black : Color(uiColor: .systemGroupedBackground))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: framed); renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "\(name) did not render")
        XCTAssertGreaterThan(image.size.width, 10)
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let data = image.pngData() {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }
    func testProgressAndActivityViewsRender() throws {
        let now = Date()
        let running = GenerationActivityAttributes.ContentState(phase: .running, detail: "Step 3 of 8", start: now.addingTimeInterval(-140), end: now.addingTimeInterval(262), fraction: 0.35)
        let paused = GenerationActivityAttributes.ContentState(phase: .paused, detail: "Step 5 of 8", start: now, end: nil, fraction: 0.6)
        for dark in [false, true] {
            try render("card-running", GenerationProgressCard(paused: false, runStart: now.addingTimeInterval(-140), estimatedEnd: now.addingTimeInterval(262), status: "Step 3 of 8", stageFraction: 0.3), width: 370, dark: dark)
            try render("card-estimating", GenerationProgressCard(paused: false, runStart: now, estimatedEnd: nil, status: "Reading your prompt", stageFraction: 0.04), width: 370, dark: dark)
            try render("card-paused", GenerationProgressCard(paused: true, runStart: now, estimatedEnd: now.addingTimeInterval(200), status: "Paused. Keep Moss open to continue.", stageFraction: 0.5), width: 370, dark: dark)
            try render("lockscreen-running", LockScreenView(state: running, size: "1024 × 1024").background(Color.black.opacity(0.55)), width: 370, dark: dark)
            try render("lockscreen-paused", LockScreenView(state: paused, size: "1024 × 1024").background(Color.black.opacity(0.55)), width: 370, dark: dark)
        }
        // Approximation of the compact Dynamic Island: ring on the left, countdown on the right of the camera.
        let island = HStack {
            ProgressRing(state: running).frame(width: 18, height: 18)
            Spacer()
            Countdown(state: running).font(.caption.weight(.semibold)).foregroundStyle(mossActivityTint).frame(maxWidth: 52, alignment: .trailing)
        }.padding(.horizontal, 14).frame(width: 250, height: 37).background(Capsule().fill(.black)).environment(\.colorScheme, .dark)
        try render("island-compact", island, width: 280, dark: true)
    }

    func testScreensRender() throws {
        let models = ModelManager(), gallery = GalleryStore()
        let app = AppModel(models: models, gallery: gallery)
        models.downloading = true; models.busy = true
        models.currentPath = "transformer/model-00001-of-00002.safetensors"
        models.currentReceived = 1_620_000_000; models.speed = 38_000_000
        try render("setup-downloading", SetupView().environmentObject(models).environmentObject(app).environmentObject(gallery), width: 390, dark: true)
        models.downloading = false; models.busy = false; models.currentPath = nil; models.ready = true
        app.settings.prompt = "A cozy reading nook by a rainy window, warm lamp light"
        try render("create-ready", GeneratorView().environmentObject(models).environmentObject(app).environmentObject(gallery).frame(height: 780), width: 390, dark: true)
    }
}
