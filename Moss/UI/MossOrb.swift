import SceneKit
import SwiftUI
import UIKit

/// Interactive 3D hero: a living moss orb. Drag to spin it (with inertia); tap to make it pulse.
/// While an image is generating it breathes faster, glows brighter and its orbiting seeds speed up.
/// Rendering pauses when the view is off screen and is replaced by a still frame with Reduce Motion.
struct MossOrb: UIViewRepresentable {
    /// 0 = calm, 1 = generating.
    var energy: Double
    /// 0...1 overall progress, shown by how many orbiting seeds are lit.
    var progress: Double?
    /// Lower frame rate while the GPU is busy generating, so the orb never slows the model down.
    var busy: Bool

    func makeCoordinator() -> OrbScene { OrbScene() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.isJitteringEnabled = false
        view.delegate = context.coordinator
        view.rendersContinuously = !UIAccessibility.isReduceMotionEnabled
        view.isPlaying = !UIAccessibility.isReduceMotionEnabled
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(OrbScene.pan(_:))))
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(OrbScene.tap(_:))))
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Moss orb"
        view.accessibilityHint = "Drag to spin. Decorative."
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.targetEnergy = Float(energy)
        context.coordinator.setProgress(progress)
        view.preferredFramesPerSecond = busy ? 30 : 60
    }

    static func dismantleUIView(_ view: SCNView, coordinator: OrbScene) {
        view.isPlaying = false
        view.scene = nil
    }
}

final class OrbScene: NSObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let camera = SCNNode()
    private let pivot = SCNNode()
    private let orb: SCNNode
    private let halo: SCNNode
    private let seedRing = SCNNode()
    private var seeds: [SCNNode] = []
    private let material = SCNMaterial()
    private var spin = SIMD2<Float>(0, 0.35)      // radians/second around x, y
    private var energy: Float = 0
    var targetEnergy: Float = 0
    private var pulse: Float = 0
    private var litSeeds = 0
    private var lastTime: TimeInterval?
    private let seedCount = 24

    override init() {
        // Orb: a smooth sphere whose surface is displaced by layered waves in a geometry shader, with a
        // fresnel rim in the moss-lime accent.
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 64
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(red: 0.10, green: 0.17, blue: 0.10, alpha: 1)
        material.metalness.contents = 0.25
        material.roughness.contents = 0.38
        material.shaderModifiers = [
            .geometry: """
            #pragma arguments
            float energyG;
            #pragma body
            float energy = energyG;
            float3 p = _geometry.position.xyz;
            float t = scn_frame.time * (0.6 + 1.4 * energy);
            float n = sin(p.x * 3.1 + t * 1.3) + sin(p.y * 2.7 - t * 1.1) + sin(p.z * 3.7 + t * 0.9) + 0.5 * sin((p.x + p.y) * 5.0 + t * 2.0);
            _geometry.position.xyz = p * (1.0 + (0.045 + 0.06 * energy) * n);
            """,
            .surface: """
            #pragma arguments
            float energyS;
            #pragma body
            float energy = energyS;
            float ndv = clamp(dot(normalize(_surface.normal), normalize(_surface.view)), 0.0, 1.0);
            float rim = pow(1.0 - ndv, 2.4);
            float3 lime = float3(0.79, 0.95, 0.36);
            float3 deep = float3(0.20, 0.34, 0.16);
            _surface.emission.rgb = lime * rim * (0.55 + 0.9 * energy) + deep * 0.25;
            """,
        ]
        material.setValue(NSNumber(value: 0), forKey: "energyG")
        material.setValue(NSNumber(value: 0), forKey: "energyS")
        sphere.materials = [material]
        orb = SCNNode(geometry: sphere)

        // Soft halo behind the orb.
        let plane = SCNPlane(width: 3.8, height: 3.8)
        let haloMaterial = SCNMaterial()
        haloMaterial.lightingModel = .constant
        haloMaterial.diffuse.contents = OrbScene.haloImage()
        haloMaterial.blendMode = .add
        haloMaterial.writesToDepthBuffer = false
        plane.materials = [haloMaterial]
        halo = SCNNode(geometry: plane)
        halo.position = SCNVector3(0, 0, -1.2)
        halo.opacity = 0.55
        super.init()

        let cam = SCNCamera(); cam.fieldOfView = 34   // no HDR/bloom: the halo plane gives the glow for free
        camera.camera = cam
        camera.position = SCNVector3(0, 0, 6.4)
        scene.rootNode.addChildNode(camera)

        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .omni; key.light?.intensity = 900
        key.light?.color = UIColor(white: 1, alpha: 1); key.position = SCNVector3(-3, 4, 5)
        let fill = SCNNode(); fill.light = SCNLight(); fill.light?.type = .ambient; fill.light?.intensity = 220
        fill.light?.color = UIColor(red: 0.6, green: 0.8, blue: 0.6, alpha: 1)
        scene.rootNode.addChildNode(key); scene.rootNode.addChildNode(fill)

        scene.rootNode.addChildNode(halo)
        scene.rootNode.addChildNode(pivot)
        pivot.addChildNode(orb)

        // Orbiting seeds: lit seeds track progress while generating.
        for i in 0..<seedCount {
            let seed = SCNNode(geometry: SCNSphere(radius: 0.045))
            let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = UIColor(white: 1, alpha: 0.25)
            seed.geometry?.materials = [m]
            let angle = Float(i) / Float(seedCount) * 2 * .pi
            seed.position = SCNVector3(cos(angle) * 1.55, 0, sin(angle) * 1.55)
            seeds.append(seed); seedRing.addChildNode(seed)
        }
        seedRing.eulerAngles = SCNVector3(0.32, 0, 0.12)
        scene.rootNode.addChildNode(seedRing)
        scene.background.contents = UIColor.clear
    }

    func setProgress(_ value: Double?) {
        let lit = value.map { Int(($0 * Double(seedCount)).rounded(.down)) } ?? 0
        guard lit != litSeeds else { return }
        litSeeds = lit
        for (i, seed) in seeds.enumerated() {
            seed.geometry?.firstMaterial?.diffuse.contents = i < lit
                ? UIColor(red: 0.79, green: 0.95, blue: 0.36, alpha: 1)
                : UIColor(white: 1, alpha: 0.25)
        }
    }

    @objc func pan(_ gesture: UIPanGestureRecognizer) {
        let v = gesture.velocity(in: gesture.view)
        switch gesture.state {
        case .changed:
            let d = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)
            rotate(by: SIMD2(Float(d.y) * 0.01, Float(d.x) * 0.01))
            spin = SIMD2(Float(v.y) * 0.004, Float(v.x) * 0.004)
        case .ended, .cancelled:
            spin = SIMD2(Float(v.y) * 0.004, Float(v.x) * 0.004)
        default: break
        }
    }
    @objc func tap(_ gesture: UITapGestureRecognizer) {
        pulse = 1
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func rotate(by delta: SIMD2<Float>) {
        let qx = simd_quatf(angle: delta.x, axis: SIMD3(1, 0, 0))
        let qy = simd_quatf(angle: delta.y, axis: SIMD3(0, 1, 0))
        pivot.simdOrientation = (qy * qx * pivot.simdOrientation).normalized
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = Float(min(0.05, max(0, time - (lastTime ?? time)))); lastTime = time
        // Ease toward the target energy; spin decays to a gentle idle rotation.
        energy += (targetEnergy - energy) * min(1, dt * 2.5)
        pulse = max(0, pulse - dt * 1.8)
        let idle = SIMD2<Float>(0, 0.35 + 0.9 * energy)
        spin += (idle - spin) * min(1, dt * 1.6)
        rotate(by: spin * dt)
        let breathe = 1 + 0.025 * sin(Float(time) * (1.2 + 2.0 * energy)) + 0.12 * pulse
        orb.simdScale = SIMD3(repeating: breathe)
        let glow = NSNumber(value: min(1, energy + pulse))
        material.setValue(glow, forKey: "energyG"); material.setValue(glow, forKey: "energyS")
        seedRing.simdOrientation = simd_quatf(angle: dt * (0.25 + 1.2 * energy), axis: SIMD3(0, 1, 0)) * seedRing.simdOrientation
        halo.opacity = CGFloat(0.45 + 0.35 * energy + 0.3 * pulse)
    }

    private static func haloImage() -> UIImage {
        let size = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(red: 0.79, green: 0.95, blue: 0.36, alpha: 0.55).cgColor, UIColor(red: 0.2, green: 0.35, blue: 0.15, alpha: 0).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.drawRadialGradient(gradient, startCenter: CGPoint(x: 128, y: 128), startRadius: 0, endCenter: CGPoint(x: 128, y: 128), endRadius: 128, options: [])
        }
    }
}

/// Generating state of the hero. Pure SwiftUI shapes animated by the system render server, so it stays at
/// full frame rate even while the model keeps the GPU busy, and costs the generation almost nothing.
struct MossPulse: View {
    var progress: Double
    var active: Bool
    @State private var breathe = false
    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let seeds = 24

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.accent.opacity(0.55), Theme.accentDeep.opacity(0.25), .clear], center: .center, startRadius: 0, endRadius: size * 0.5))
                    .frame(width: size, height: size)
                    .scaleEffect(breathe ? 1.04 : 0.94)
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.86, green: 0.98, blue: 0.62), Theme.accent, Theme.accentDeep, Color(red: 0.08, green: 0.14, blue: 0.08)], center: UnitPoint(x: 0.36, y: 0.32), startRadius: 2, endRadius: size * 0.34))
                    .frame(width: size * 0.5, height: size * 0.5)
                    .overlay(Circle().strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1.5).blur(radius: 2))
                    .shadow(color: Theme.accent.opacity(active ? 0.55 : 0.2), radius: active ? 30 : 12)
                    .scaleEffect(breathe ? 1.03 : 0.97)
                ZStack {
                    ForEach(0..<seeds, id: \.self) { i in
                        Circle()
                            .fill(Double(i) < progress * Double(seeds) ? Theme.accent : Color.white.opacity(0.22))
                            .frame(width: 7, height: 7)
                            .offset(y: -size * 0.38)
                            .rotationEffect(.degrees(Double(i) / Double(seeds) * 360))
                    }
                }
                .rotationEffect(.degrees(spin ? 360 : 0))
                .rotation3DEffect(.degrees(62), axis: (x: 1, y: 0, z: 0.15))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { animate() }
        .onChange(of: active) { _, _ in animate() }
        .accessibilityHidden(true)
    }

    private func animate() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: active ? 1.4 : 2.6).repeatForever(autoreverses: true)) { breathe.toggle() }
        if !spin { withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { spin = true } }
    }
}
