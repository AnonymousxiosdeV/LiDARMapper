// ARScanView.swift — LiDARMapper

import SwiftUI
import ARKit
import SceneKit

// MARK: - ARScanView

struct ARScanView: UIViewRepresentable {

    @ObservedObject var viewModel:   ScanViewModel
    @ObservedObject var coordinator: ARCoordinator

    func makeCoordinator() -> ARCoordinator { coordinator }

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arView.delegate                    = coordinator
        arView.session.delegate            = coordinator
        arView.automaticallyUpdatesLighting = true
        arView.antialiasingMode            = .multisampling4X
        arView.rendersContinuously         = true
        arView.autoenablesDefaultLighting  = true
        // Do NOT set backgroundColor — it blocks the camera feed on both cameras
        coordinator.arView = arView
        coordinator.startCameraOnly(mode: viewModel.cameraMode)
        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: - ARCoordinator

final class ARCoordinator: NSObject, ObservableObject {

    weak var arView: ARSCNView?
    private let viewModel: ScanViewModel
    private let log = AppLogger.shared
    private let metalDevice = MTLCreateSystemDefaultDevice()

    init(viewModel: ScanViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Session Control

    func startCameraOnly(mode: CameraMode) {
        guard let arView else { return }
        switch mode {
        case .rear:
            let config = ARWorldTrackingConfiguration()
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            log.log("Rear camera preview started")
        case .front:
            guard ARFaceTrackingConfiguration.isSupported else {
                log.warn("ARFaceTracking not supported")
                return
            }
            let config = ARFaceTrackingConfiguration()
            // Ensure camera feed renders through
            arView.scene.background.contents = nil
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            log.log("Front TrueDepth preview started")
        }
    }

    func startSession(reset: Bool, mode: CameraMode) {
        guard let arView else {
            log.error("startSession: arView is nil"); return
        }
        log.log("Starting \(mode.rawValue) scan (reset=\(reset))")
        switch mode {
        case .rear:
            let config = ARWorldTrackingConfiguration()
            config.sceneReconstruction  = .meshWithClassification
            config.environmentTexturing = .automatic
            config.planeDetection       = [.horizontal, .vertical]
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                config.frameSemantics.insert(.sceneDepth)
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                config.frameSemantics.insert(.smoothedSceneDepth)
            }
            arView.session.run(config, options: reset
                ? [.resetTracking, .removeExistingAnchors] : [])

        case .front:
            guard ARFaceTrackingConfiguration.isSupported else { return }
            let config = ARFaceTrackingConfiguration()
            config.maximumNumberOfTrackedFaces = ARFaceTrackingConfiguration.supportedNumberOfTrackedFaces
            config.isLightEstimationEnabled    = true
            arView.scene.background.contents   = nil   // keep camera feed visible
            arView.session.run(config, options: reset
                ? [.resetTracking, .removeExistingAnchors] : [])
        }
    }

    func pauseSession() {
        arView?.session.pause()
        log.log("AR session paused")
    }

    // MARK: - Rear Mesh Node
    // Full opacity (1.0) so texture is clearly visible during scanning

    private func makeMeshNode(for anchor: ARMeshAnchor) -> SCNNode {
        let cls   = anchor.geometry.dominantClassification()
        let color = cls.overlayColor

        // Subtle overlay — low opacity so camera feed is clear, wire edges give shape
        let solidMat = SCNMaterial()
        solidMat.diffuse.contents    = color.withAlphaComponent(0.20)
        solidMat.isDoubleSided       = true
        solidMat.lightingModel       = .constant
        solidMat.blendMode           = .alpha
        solidMat.writesToDepthBuffer = true

        let solidGeo       = SCNGeometry(arMesh: anchor.geometry)
        solidGeo.materials = [solidMat]

        // Coloured wireframe edges — main visual indicator
        let wireMat = SCNMaterial()
        wireMat.diffuse.contents = color.withAlphaComponent(0.80)
        wireMat.isDoubleSided    = true
        wireMat.lightingModel    = .constant
        wireMat.fillMode         = .lines

        let wireGeo       = SCNGeometry(arMesh: anchor.geometry)
        wireGeo.materials = [wireMat]

        let node = SCNNode(geometry: solidGeo)
        node.addChildNode(SCNNode(geometry: wireGeo))
        return node
    }

    // MARK: - Front Face Geometry Node

    private func makeFaceNode(for anchor: ARFaceAnchor, existing: SCNNode?) -> SCNNode {
        if let existing = existing,
           let faceGeo  = existing.geometry as? ARSCNFaceGeometry {
            faceGeo.update(from: anchor.geometry)
            // Also update wire child
            if let wireNode = existing.childNodes.first,
               let wireGeo  = wireNode.geometry as? ARSCNFaceGeometry {
                wireGeo.update(from: anchor.geometry)
            }
            return existing
        }

        guard let device = metalDevice,
              let faceGeo = ARSCNFaceGeometry(device: device) else { return SCNNode() }

        faceGeo.update(from: anchor.geometry)
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.cyan.withAlphaComponent(0.35)
        mat.isDoubleSided    = true
        mat.lightingModel    = .constant
        mat.blendMode        = .alpha
        faceGeo.materials    = [mat]

        // Wireframe overlay
        guard let wireGeo = ARSCNFaceGeometry(device: device) else {
            return SCNNode(geometry: faceGeo)
        }
        wireGeo.update(from: anchor.geometry)
        let wireMat = SCNMaterial()
        wireMat.diffuse.contents = UIColor.cyan.withAlphaComponent(0.90)
        wireMat.isDoubleSided    = true
        wireMat.lightingModel    = .constant
        wireMat.fillMode         = .lines
        wireGeo.materials        = [wireMat]

        let node = SCNNode(geometry: faceGeo)
        node.addChildNode(SCNNode(geometry: wireGeo))
        return node
    }
}

// MARK: - ARSCNViewDelegate

extension ARCoordinator: ARSCNViewDelegate {

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        if let mesh = anchor as? ARMeshAnchor {
            node.addChildNode(makeMeshNode(for: mesh))
            Task { @MainActor in viewModel.anchorAdded(mesh) }
        } else if let face = anchor as? ARFaceAnchor {
            node.addChildNode(makeFaceNode(for: face, existing: nil))
            Task { @MainActor in viewModel.faceAnchorAdded(face) }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        if let mesh = anchor as? ARMeshAnchor {
            node.childNodes.forEach { $0.removeFromParentNode() }
            node.addChildNode(makeMeshNode(for: mesh))
            Task { @MainActor in viewModel.anchorUpdated(mesh) }
        } else if let face = anchor as? ARFaceAnchor {
            let existing = node.childNodes.first
            let updated  = makeFaceNode(for: face, existing: existing)
            if updated !== existing {
                node.childNodes.forEach { $0.removeFromParentNode() }
                node.addChildNode(updated)
            }
            Task { @MainActor in viewModel.faceAnchorUpdated(face) }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        if let mesh = anchor as? ARMeshAnchor {
            Task { @MainActor in viewModel.anchorRemoved(mesh) }
        } else if let face = anchor as? ARFaceAnchor {
            Task { @MainActor in viewModel.faceAnchorRemoved(face) }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // ✅ ARSCNView calls this on the main thread, but viewModel is @MainActor.
        // DispatchQueue.main.async is far lighter than allocating a new Task every frame at 60fps.
        DispatchQueue.main.async { [weak self] in self?.viewModel.frameRendered() }
    }
}

// MARK: - ARSessionDelegate

extension ARCoordinator: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in viewModel.tryCapture(arFrame: frame) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        log.error("Session error: \(error.localizedDescription)")
        Task { @MainActor in viewModel.phase = .failed(message: error.localizedDescription) }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in viewModel.trackingMsg = "Session interrupted" }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in viewModel.trackingMsg = "" }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        var msg = ""
        switch camera.trackingState {
        case .normal:       msg = ""
        case .notAvailable: msg = "Tracking unavailable"
        case .limited(let r):
            switch r {
            case .initializing:         msg = "Initializing — move slowly"
            case .relocalizing:         msg = "Relocalizing"
            case .excessiveMotion:      msg = "⚠ Move more slowly"
            case .insufficientFeatures: msg = "⚠ Need more light / texture"
            @unknown default:           msg = "Tracking limited"
            }
        }
        Task { @MainActor in viewModel.trackingMsg = msg }
    }
}
