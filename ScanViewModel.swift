// ScanViewModel.swift — LiDARMapper

import ARKit
import SwiftUI

enum CameraMode: String, CaseIterable {
    case rear  = "Rear LiDAR"
    case front = "Front TrueDepth"

    var systemImage: String {
        switch self {
        case .rear:  return "camera.aperture"
        case .front: return "person.crop.square"
        }
    }

    var isSupported: Bool {
        switch self {
        case .rear:  return ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        case .front: return ARFaceTrackingConfiguration.isSupported
        }
    }
}

enum ScanPhase: Equatable {
    case idle
    case scanning
    case paused
    case exporting(progress: Double)
    case exported(url: URL)
    case failed(message: String)
}

@MainActor
final class ScanViewModel: ObservableObject {

    @Published var phase:              ScanPhase    = .idle
    @Published var cameraMode:         CameraMode   = .rear
    @Published var vertexCount:        Int          = 0
    @Published var faceCount:          Int          = 0
    @Published var tileCount:          Int          = 0
    @Published var fps:                Double       = 0
    @Published var trackingMsg:        String       = ""
    @Published var showShareSheet                   = false
    @Published var exportURL:          URL?         = nil
    @Published var exportFormat:       ExportFormat = .obj
    @Published var capturedFrameCount: Int          = 0
    @Published var maxScanDistance:    Float        = 5.0

    static let maxFrames = 400

    private(set) var meshAnchors  = [UUID: ARMeshAnchor]()
    private let meshLock          = NSLock()

    private(set) var faceSnapshots = [UUID: FaceSnapshot]()
    private let faceLock           = NSLock()

    private var capturedFrames   = [CapturedFrame]()
    private let framesLock       = NSLock()
    private var lastCaptureDate  = Date.distantPast
    private let captureInterval: TimeInterval = 0.20
    private var lastCapturedTransform: simd_float4x4?

    // Dedicated live front camera frame for face texture (ensures front camera image, not back)
    private var faceTextureFrame: CapturedFrame?

    private var fpsFrames = 0
    private var fpsDate   = Date()

    let log = AppLogger.shared
    nonisolated let exporter = MeshExporter()

    func switchCamera() {
        guard phase == .idle || phase == .paused else { return }
        let next: CameraMode = cameraMode == .rear ? .front : .rear
        guard next.isSupported else {
            phase = .failed(message: "\(next.rawValue) is not supported on this device.")
            return
        }
        cameraMode = next
        resetScan()
    }

    func anchorAdded(_ anchor: ARMeshAnchor) {
        meshLock.lock(); meshAnchors[anchor.identifier] = anchor; meshLock.unlock()
        refreshStats()
    }
    func anchorUpdated(_ anchor: ARMeshAnchor) {
        meshLock.lock(); meshAnchors[anchor.identifier] = anchor; meshLock.unlock()
        refreshStats()
    }
    func anchorRemoved(_ anchor: ARMeshAnchor) {
        meshLock.lock(); meshAnchors.removeValue(forKey: anchor.identifier); meshLock.unlock()
        refreshStats()
    }

    func faceAnchorAdded(_ anchor: ARFaceAnchor) {
        let snap = FaceSnapshot(anchor: anchor)
        faceLock.lock(); faceSnapshots[anchor.identifier] = snap; faceLock.unlock()
        vertexCount = snap.vertices.count
        faceCount   = snap.triangleCount
        tileCount   = 1

        // Capture live front camera image for accurate face texture
        if let currentFrame = /* provided by coordinator or last ARFrame */ nil {
            // Will be set from AR delegate
        }
    }
    func faceAnchorUpdated(_ anchor: ARFaceAnchor) {
        let snap = FaceSnapshot(anchor: anchor)
        faceLock.lock(); faceSnapshots[anchor.identifier] = snap; faceLock.unlock()
        vertexCount = snap.vertices.count
        faceCount   = snap.triangleCount
    }
    func faceAnchorRemoved(_ anchor: ARFaceAnchor) {
        faceLock.lock(); faceSnapshots.removeValue(forKey: anchor.identifier); faceLock.unlock()
    }

    func tryCapture(arFrame: ARFrame) {
        guard case .scanning = phase else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCaptureDate) >= captureInterval else { return }

        let newTransform = arFrame.camera.transform
        if let prev = lastCapturedTransform {
            let dist  = simd_distance(newTransform.columns.3.xyz, prev.columns.3.xyz)
            let cosA  = simd_dot(normalize(newTransform.columns.2.xyz),
                                 normalize(prev.columns.2.xyz))
            let angle = acos(max(-1, min(1, cosA)))
            guard dist > 0.08 || angle > 0.05 else { return }
        }
        lastCapturedTransform = newTransform
        lastCaptureDate = now

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let captured = CapturedFrame(arFrame: arFrame, scale: 0.75) else { return }
            await MainActor.run {
                self.framesLock.lock()
                if self.cameraMode == .front {
                    // Keep only the latest front camera frame for face texture
                    self.faceTextureFrame = captured
                } else {
                    self.capturedFrames.append(captured)
                    if self.capturedFrames.count > Self.maxFrames {
                        self.capturedFrames.removeFirst(self.capturedFrames.count - Self.maxFrames)
                    }
                }
                self.capturedFrameCount = self.capturedFrames.count + (self.faceTextureFrame != nil ? 1 : 0)
                self.framesLock.unlock()
            }
        }
    }

    func allCapturedFrames() -> [CapturedFrame] {
        framesLock.lock(); defer { framesLock.unlock() }
        return capturedFrames
    }

    func currentFaceTextureFrame() -> CapturedFrame? {
        framesLock.lock(); defer { framesLock.unlock() }
        return faceTextureFrame
    }

    func frameRendered() {
        fpsFrames += 1
        let elapsed = Date().timeIntervalSince(fpsDate)
        guard elapsed >= 0.5 else { return }
        fps = Double(fpsFrames) / elapsed
        fpsFrames = 0; fpsDate = Date()
    }

    private func refreshStats() {
        meshLock.lock()
        var v = 0, f = 0
        for (_, a) in meshAnchors { v += a.geometry.vertices.count; f += a.geometry.faces.count }
        let t = meshAnchors.count
        meshLock.unlock()
        vertexCount = v; faceCount = f; tileCount = t
    }

    nonisolated func makeExportURL(format: ExportFormat) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = docs.appendingPathComponent("LiDARMapper/exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let iso  = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = iso.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("scan_\(stamp).\(format.fileExtension)")
    }

    func startExport(withTexture: Bool = true) {
        switch cameraMode {
        case .rear:  startRearExport(frames: withTexture ? allCapturedFrames() : [])
        case .front: startFrontExport(frames: withTexture ? (currentFaceTextureFrame() != nil ? [currentFaceTextureFrame()!] : allCapturedFrames()) : [])
        }
    }

    private func startRearExport(frames: [CapturedFrame]) {
        meshLock.lock()
        let camPos = simd_make_float3(0,0,0)
        let anchors = Array(meshAnchors.values).filter { a in
            let p = a.transform.columns.3.xyz
            return simd_distance(p, camPos) <= maxScanDistance
        }
        meshLock.unlock()

        guard !anchors.isEmpty else {
            phase = .failed(message: "No mesh data — start scanning first.")
            return
        }

        log.log("Rear export: \(anchors.count) tiles (filtered to \(maxScanDistance)m), \(frames.count) frames")
        phase = .exporting(progress: 0)

        let exp    = exporter
        let logger = log
        let vm     = self

        Task.detached(priority: .userInitiated) {
            do {
                let meshData = exp.collectMeshData(from: anchors) { p in
                    Task { @MainActor in vm.phase = .exporting(progress: p * 0.25) }
                }
                Task { @MainActor in vm.phase = .exporting(progress: 0.25) }

                let baseURL = try vm.makeExportURL(format: .obj)

                try exp.exportAll(meshData: meshData, frames: frames,
                                  baseURL: baseURL) { p, msg in
                    Task { @MainActor in vm.phase = .exporting(progress: 0.25 + p * 0.75) }
                }

                let dir  = baseURL.deletingLastPathComponent()
                let stem = baseURL.deletingPathExtension().lastPathComponent
                let texURL = dir.appendingPathComponent(stem + "_textured.obj")
                let shareURL = FileManager.default.fileExists(atPath: texURL.path) ? texURL : baseURL

                Task { @MainActor in vm.finishExport(url: shareURL, logger: logger) }
            } catch {
                Task { @MainActor in
                    vm.phase = .failed(message: error.localizedDescription)
                    logger.error("Export failed: \(error)")
                }
            }
        }
    }

    private func startFrontExport(frames: [CapturedFrame]) {
        faceLock.lock()
        let snapshots = Array(faceSnapshots.values)
        faceLock.unlock()

        guard !snapshots.isEmpty else {
            phase = .failed(message: "No face data — start scanning first.")
            return
        }

        log.log("Front export: \(snapshots.count) snapshots, \(frames.count) frames (front camera)")
        phase = .exporting(progress: 0)

        let exp    = exporter
        let logger = log
        let vm     = self

        Task.detached(priority: .userInitiated) {
            do {
                let url = try vm.makeExportURL(format: .obj)
                try exp.exportFaceMesh(snapshots: snapshots, frames: frames, to: url) { p in
                    Task { @MainActor in vm.phase = .exporting(progress: p) }
                }
                Task { @MainActor in vm.finishExport(url: url, logger: logger) }
            } catch {
                Task { @MainActor in
                    vm.phase = .failed(message: error.localizedDescription)
                    logger.error("Front export failed: \(error)")
                }
            }
        }
    }

    func finishExport(url: URL, logger: AppLogger) {
        exportURL      = url
        phase          = .exported(url: url)
        showShareSheet = true
        logger.log("Export ready: \(url.lastPathComponent)")
    }

    func resetScan() {
        meshLock.lock(); meshAnchors.removeAll(); meshLock.unlock()
        faceLock.lock(); faceSnapshots.removeAll(); faceLock.unlock()
        framesLock.lock()
        capturedFrames.removeAll()
        faceTextureFrame = nil
        framesLock.unlock()
        lastCapturedTransform = nil
        vertexCount = 0; faceCount = 0; tileCount = 0
        capturedFrameCount = 0; phase = .idle; exportURL = nil
    }
}

struct FaceSnapshot {
    let transform:          simd_float4x4
    let vertices:           [SIMD3<Float>]
    let textureCoordinates: [SIMD2<Float>]
    let triangleIndices:    [Int16]
    let triangleCount:      Int

    init(anchor: ARFaceAnchor) {
        self.transform          = anchor.transform
        let geo                 = anchor.geometry
        self.vertices           = geo.vertices
        self.textureCoordinates = geo.textureCoordinates
        self.triangleCount      = geo.triangleCount

        let count = geo.triangleCount * 3
        let ptr   = geo.triangleIndices
        self.triangleIndices = (0..<count).map { ptr[$0] }
    }
}