// MiniScanPreview.swift — LiDARMapper
// Corner mini point-cloud during scanning.
// Fixed actor isolation for main-actor ViewModel properties.

import SwiftUI
import SceneKit
import ARKit

struct MiniScanPreviewView: View {
    @ObservedObject var viewModel: ScanViewModel
    @State private var expanded = false

    var body: some View {
        ZStack {
            if expanded {
                Color.black.opacity(0.92).ignoresSafeArea()
                MiniSceneContainer(viewModel: viewModel, expanded: true)
                    .ignoresSafeArea()
                VStack {
                    HStack {
                        Spacer()
                        Button { withAnimation(.spring()) { expanded = false } } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(16)
                        }
                    }
                    Spacer()
                    Text("Drag to orbit  •  Pinch to zoom")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                        .padding(.bottom, 40)
                }
            } else {
                ZStack(alignment: .bottomTrailing) {
                    MiniSceneContainer(viewModel: viewModel, expanded: false)
                        .frame(width: 150, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                expanded = true
                            }
                        }
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(6)
                        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                        .padding(6)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: expanded)
    }
}

struct MiniSceneContainer: UIViewRepresentable {
    @ObservedObject var viewModel: ScanViewModel
    let expanded: Bool

    func makeCoordinator() -> MiniCoordinator { MiniCoordinator() }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.backgroundColor            = UIColor(white: 0.08, alpha: 1)
        v.antialiasingMode           = .multisampling2X
        v.allowsCameraControl        = false
        v.rendersContinuously        = true
        v.autoenablesDefaultLighting = false
        context.coordinator.setup(v, expanded: expanded)
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        context.coordinator.syncPointCloud(from: viewModel)
        context.coordinator.updateCameraTracking(from: viewModel)
        context.coordinator.setExpandedGestures(expanded, on: v)
    }
}

final class MiniCoordinator: NSObject {
    private weak var scnView: SCNView?
    private var scene:        SCNScene?
    private var cloudRoot:    SCNNode?
    private var pivotNode:    SCNNode?
    private var orbitNode:    SCNNode?
    private var gesturesAdded = false

    private var lastSyncCount  = -1
    private let syncThrottle   = 3

    private var lastPan:   CGPoint = .zero
    private var lastPinch: CGFloat = 1.0

    func setup(_ v: SCNView, expanded: Bool) {
        scnView = v
        let s = SCNScene(); scene = s; v.scene = s

        addLight(s, .ambient,     UIColor(white: 0.9, alpha: 1), 600)
        addLight(s, .directional, UIColor(white: 0.7, alpha: 1), 400,
                 euler: SCNVector3(-0.5, 0.4, 0))

        let pivot = SCNNode(); s.rootNode.addChildNode(pivot); pivotNode = pivot

        let orbit = SCNNode()
        orbit.position = SCNVector3(0, 0, expanded ? 5 : 4)
        s.rootNode.addChildNode(orbit); orbitNode = orbit

        let camNode = SCNNode(); let cam = SCNCamera()
        cam.fieldOfView = expanded ? 50 : 60
        cam.zNear = 0.01; cam.zFar = 200
        camNode.camera = cam; orbit.addChildNode(camNode); v.pointOfView = camNode

        let root = SCNNode(); pivot.addChildNode(root); cloudRoot = root
    }

    // Snapshot on main actor to satisfy isolation
    func syncPointCloud(from viewModel: ScanViewModel) {
        Task { @MainActor in
            let count = viewModel.tileCount
            guard abs(count - self.lastSyncCount) >= self.syncThrottle else { return }
            self.lastSyncCount = count

            let anchors = Array(viewModel.meshAnchors.values)
            guard !anchors.isEmpty, let root = self.cloudRoot else {
                self.cloudRoot?.childNodes.forEach { $0.removeFromParentNode() }
                return
            }
            let latestFrame = viewModel.allCapturedFrames().last

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let node = self.buildPointCloud(from: anchors, colorFrame: latestFrame)
                DispatchQueue.main.async {
                    root.childNodes.forEach { $0.removeFromParentNode() }
                    if let n = node { root.addChildNode(n); self.centreAndScale(n, in: root) }
                }
            }
        }
    }

    private func buildPointCloud(from anchors: [ARMeshAnchor],
                                  colorFrame: CapturedFrame?) -> SCNNode? {
        let maxPoints  = 30_000
        let totalVerts = anchors.reduce(0) { $0 + $1.geometry.vertices.count }
        let step       = max(1, totalVerts / maxPoints)

        var flatPos   = [Float]()
        var flatColor = [Float]()
        flatPos.reserveCapacity(min(totalVerts, maxPoints) * 3)
        flatColor.reserveCapacity(min(totalVerts, maxPoints) * 4)

        let sampler = colorFrame.flatMap { BitmapSampler(jpeg: $0.jpegData) }

        for anchor in anchors {
            let mesh  = anchor.geometry
            let xform = anchor.transform
            var i = 0
            while i < mesh.vertices.count {
                let w = xform.transformPoint(mesh.vertexPosition(at: i))
                flatPos.append(w.x); flatPos.append(w.y); flatPos.append(w.z)

                var r: Float = 0.50, g: Float = 0.68, b: Float = 0.85
                if let frame = colorFrame, let smp = sampler,
                   let uv = frame.project(w) {
                    let c = smp.sample(at: uv)
                    r = c.x; g = c.y; b = c.z
                }
                flatColor.append(r); flatColor.append(g)
                flatColor.append(b); flatColor.append(1.0)

                i += step
            }
        }

        guard !flatPos.isEmpty else { return nil }
        let n = flatPos.count / 3

        let posData = Data(bytes: flatPos,   count: flatPos.count   * 4)
        let posSrc  = SCNGeometrySource(data: posData, semantic: .vertex,
                                         vectorCount: n, usesFloatComponents: true,
                                         componentsPerVector: 3, bytesPerComponent: 4,
                                         dataOffset: 0, dataStride: 12)

        let colData = Data(bytes: flatColor, count: flatColor.count * 4)
        let colSrc  = SCNGeometrySource(data: colData, semantic: .color,
                                         vectorCount: n, usesFloatComponents: true,
                                         componentsPerVector: 4, bytesPerComponent: 4,
                                         dataOffset: 0, dataStride: 16)

        var idx = (0..<Int32(n)).map { $0 }
        let idxData = Data(bytes: &idx, count: n * 4)
        let element = SCNGeometryElement(data: idxData, primitiveType: .point,
                                          primitiveCount: n, bytesPerIndex: 4)
        element.pointSize = 3.0
        element.minimumPointScreenSpaceRadius = 1.0
        element.maximumPointScreenSpaceRadius = 5.0

        let geo = SCNGeometry(sources: [posSrc, colSrc], elements: [element])
        let mat = SCNMaterial()
        mat.lightingModel    = .constant
        mat.diffuse.contents = UIColor.white
        mat.isDoubleSided    = true
        geo.materials = [mat]
        return SCNNode(geometry: geo)
    }

    func updateCameraTracking(from viewModel: ScanViewModel) {
        Task { @MainActor in
            guard let pivot = self.pivotNode else { return }
            if let t = viewModel.allCapturedFrames().last?.cameraTransform {
                let yaw  = atan2(t.columns.2.x, t.columns.2.z)
                let cur  = pivot.eulerAngles.y
                let diff = self.shortestAngle(from: cur, to: -yaw)
                pivot.eulerAngles.y = cur + diff * 0.08
                let pitch = -0.25 + Float(t.columns.2.y) * 0.3
                pivot.eulerAngles.x += (pitch - pivot.eulerAngles.x) * 0.05
            }
        }
    }

    private func shortestAngle(from a: Float, to b: Float) -> Float {
        var d = b - a
        while d >  Float.pi { d -= 2 * .pi }
        while d < -Float.pi { d += 2 * .pi }
        return d
    }

    func setExpandedGestures(_ expanded: Bool, on v: SCNView) {
        if expanded && !gesturesAdded {
            v.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
            v.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
            gesturesAdded = true
        } else if !expanded && gesturesAdded {
            v.gestureRecognizers?.forEach { v.removeGestureRecognizer($0) }
            gesturesAdded = false
            orbitNode?.position.z = 4
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let pivot = pivotNode, let v = scnView else { return }
        let t  = g.translation(in: v)
        let dx = Float(t.x - lastPan.x); let dy = Float(t.y - lastPan.y)
        pivot.eulerAngles.y += dx * 0.006
        pivot.eulerAngles.x -= dy * 0.006
        pivot.eulerAngles.x  = max(-.pi*0.48, min(.pi*0.48, pivot.eulerAngles.x))
        lastPan = g.state == .ended ? .zero : t
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard let orbit = orbitNode else { return }
        if g.state == .began { lastPinch = g.scale }
        orbit.position.z = max(0.5, min(30, orbit.position.z / Float(g.scale / lastPinch)))
        lastPinch = g.scale
    }

    private func centreAndScale(_ node: SCNNode, in parent: SCNNode) {
        let (mn, mx) = node.boundingBox
        guard mn.x.isFinite && mx.x.isFinite else { return }
        node.position = SCNVector3(-(mn.x+mx.x)/2, -(mn.y+mx.y)/2, -(mn.z+mx.z)/2)
        let d = max(mx.x-mn.x, mx.y-mn.y, mx.z-mn.z)
        if d > 0 { let s = Float(2.5) / d; parent.scale = SCNVector3(s,s,s) }
    }

    private func addLight(_ scene: SCNScene, _ type: SCNLight.LightType,
                           _ color: UIColor, _ intensity: CGFloat,
                           euler: SCNVector3 = SCNVector3(0,0,0)) {
        let n = SCNNode(); let l = SCNLight()
        l.type = type; l.color = color; l.intensity = intensity
        n.light = l; n.eulerAngles = euler
        scene.rootNode.addChildNode(n)
    }
}
