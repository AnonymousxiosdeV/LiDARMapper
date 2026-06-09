// MeshExporter.swift — LiDARMapper

import ARKit
import simd
import Foundation
import UIKit
import CoreGraphics

// MARK: - Export Format

enum ExportFormat: String, CaseIterable, Identifiable {
    case obj = "OBJ"
    case ply = "PLY"
    var id: String { rawValue }
    var fileExtension: String { rawValue.lowercased() }
}

// MARK: - Unified Mesh

struct UnifiedMeshData {
    var vertices:        [SIMD3<Float>]
    var normals:         [SIMD3<Float>]
    var faces:           [SIMD3<UInt32>]
    var classifications: [ARMeshClassification]
    var vertexCount: Int { vertices.count }
    var faceCount:   Int { faces.count }
}

// MARK: - MeshExporter

final class MeshExporter {

    private let log = AppLogger.shared

    // MARK: - Collect & Merge

    func collectMeshData(from anchors: [ARMeshAnchor],
                         progress: ((Double) -> Void)? = nil) -> UnifiedMeshData {
        log.log("Merging \(anchors.count) tile(s)")
        var allVerts = [SIMD3<Float>](), allFaces = [SIMD3<UInt32>]()
        var allCls   = [ARMeshClassification]()
        let total    = Float(max(anchors.count, 1))

        for (idx, anchor) in anchors.enumerated() {
            let mesh  = anchor.geometry
            let xform = anchor.transform
            let base  = UInt32(allVerts.count)

            for i in 0..<mesh.vertices.count {
                allVerts.append(xform.transformPoint(mesh.vertexPosition(at: i)))
            }
            for i in 0..<mesh.faces.count {
                let (i0, i1, i2) = mesh.triangleIndices(at: i)
                allFaces.append(SIMD3<UInt32>(base+i0, base+i1, base+i2))
                allCls.append(mesh.faceClassification(at: i))
            }
            progress?(Double(idx+1) / Double(total) * 0.6)
        }

        log.log("Merged: \(allVerts.count) verts, \(allFaces.count) faces")
        let normals = computeAngleWeightedNormals(vertices: allVerts, faces: allFaces)
        progress?(1.0)

        return UnifiedMeshData(vertices: allVerts, normals: normals,
                               faces: allFaces, classifications: allCls)
    }

    private func computeAngleWeightedNormals(vertices: [SIMD3<Float>],
                                             faces: [SIMD3<UInt32>]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for face in faces {
            let (i0, i1, i2) = (Int(face.x), Int(face.y), Int(face.z))
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }
            let v0 = vertices[i0], v1 = vertices[i1], v2 = vertices[i2]
            let fn = normalize(cross(v1-v0, v2-v0))
            func angle(o: SIMD3<Float>, a: SIMD3<Float>, b: SIMD3<Float>) -> Float {
                let da = normalize(a-o), db = normalize(b-o)
                return acos(max(-1, min(1, dot(da, db))))
            }
            normals[i0] += fn * angle(o: v0, a: v1, b: v2)
            normals[i1] += fn * angle(o: v1, a: v0, b: v2)
            normals[i2] += fn * angle(o: v2, a: v0, b: v1)
        }
        return normals.map { n in let l = length(n); return l > 1e-6 ? n/l : SIMD3<Float>(0,1,0) }
    }

    func exportOBJ(meshData: UnifiedMeshData, to url: URL) throws {
        log.log("Exporting OBJ → \(url.lastPathComponent)")
        var lines = ["# LiDAR Mapper  Date: \(ISO8601DateFormatter().string(from: Date()))",
                     "o LiDARScan\n"]
        for v in meshData.vertices { lines.append("v \(v.x) \(v.y) \(v.z)") }
        lines.append("")
        for n in meshData.normals  { lines.append("vn \(n.x) \(n.y) \(n.z)") }
        lines.append("")

        var byClass = [Int: [Int]]()
        for (i, cls) in meshData.classifications.enumerated() {
            byClass[cls.rawValue, default: []].append(i)
        }
        for (raw, idxs) in byClass.sorted(by: { $0.key < $1.key }) {
            let cls = ARMeshClassification(rawValue: raw) ?? .none
            lines.append("g \(cls.displayName.replacingOccurrences(of: " ", with: "_"))")
            for i in idxs {
                let f = meshData.faces[i]
                let (a,b,c) = (Int(f.x)+1, Int(f.y)+1, Int(f.z)+1)
                lines.append("f \(a)//\(a) \(b)//\(b) \(c)//\(c)")
            }
            lines.append("")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        log.log("OBJ done")
    }

    func exportOBJTextured(meshData: UnifiedMeshData,
                           frames: [CapturedFrame],
                           to url: URL,
                           progress: ((Double) -> Void)? = nil) throws {
        log.log("Building texture atlas from \(frames.count) frame(s)")
        progress?(0.0)

        guard !frames.isEmpty, let atlas = TextureAtlas.build(from: frames) else {
            log.warn("Atlas build failed — falling back to untextured OBJ")
            try exportOBJ(meshData: meshData, to: url)
            return
        }
        progress?(0.15)

        let baseName = url.deletingPathExtension().lastPathComponent
        let texName  = baseName + "_texture.jpg"
        let texURL   = url.deletingLastPathComponent().appendingPathComponent(texName)
        try atlas.jpegData.write(to: texURL)

        let mtlName = baseName + ".mtl"
        let mtlURL  = url.deletingLastPathComponent().appendingPathComponent(mtlName)
        let mtlContent = """
        newmtl TexturedMesh
        Ka 1.0 1.0 1.0
        Kd 1.0 1.0 1.0
        Ks 0.0 0.0 0.0
        illum 1
        map_Kd \(texName)

        newmtl UntexturedMesh
        Ka 0.55 0.55 0.55
        Kd 0.55 0.55 0.55
        illum 1
        """
        try mtlContent.write(to: mtlURL, atomically: true, encoding: .utf8)
        progress?(0.20)

        var vtLines = [String](), texFaces = [String](), unTexFaces = [String]()
        var vtIndex = 1
        let faceCount = meshData.faces.count

        for fi in 0..<faceCount {
            let face = meshData.faces[fi]
            let (i0,i1,i2) = (Int(face.x), Int(face.y), Int(face.z))
            let v0 = meshData.vertices[i0], v1 = meshData.vertices[i1],
                v2 = meshData.vertices[i2]
            let centroid = (v0+v1+v2) / 3
            let normal   = meshData.normals[i0]

            var bestIdx: Int?, bestScore: Float = 0
            for (fIdx, frame) in frames.enumerated() {
                if let s = frame.visibilityScore(faceCentroid: centroid,
                                                  faceNormal: normal), s > bestScore {
                    bestScore = s; bestIdx = fIdx
                }
            }

            if let bi = bestIdx,
               let uv0 = frames[bi].project(v0),
               let uv1 = frames[bi].project(v1),
               let uv2 = frames[bi].project(v2) {
                let a0 = atlas.atlasUV(frameIndex: bi, rawUV: uv0)
                let a1 = atlas.atlasUV(frameIndex: bi, rawUV: uv1)
                let a2 = atlas.atlasUV(frameIndex: bi, rawUV: uv2)
                vtLines.append("vt \(a0.x) \(1 - a0.y)")
                vtLines.append("vt \(a1.x) \(1 - a1.y)")
                vtLines.append("vt \(a2.x) \(1 - a2.y)")
                let (v0i,v1i,v2i) = (i0+1,i1+1,i2+1)
                let (t0,t1,t2) = (vtIndex,vtIndex+1,vtIndex+2)
                texFaces.append("f \(v0i)/\(t0)/\(v0i) \(v1i)/\(t1)/\(v1i) \(v2i)/\(t2)/\(v2i)")
                vtIndex += 3
            } else {
                let (v0i,v1i,v2i) = (i0+1,i1+1,i2+1)
                unTexFaces.append("f \(v0i)//\(v0i) \(v1i)//\(v1i) \(v2i)//\(v2i)")
            }
            if fi % 5000 == 0 {
                progress?(0.20 + 0.75 * Double(fi) / Double(faceCount))
            }
        }

        var lines = ["# LiDAR Mapper — Textured Scan",
                     "mtllib \(mtlName)", "o LiDARScan\n"]
        for v in meshData.vertices { lines.append("v \(v.x) \(v.y) \(v.z)") }
        lines.append("")
        for n in meshData.normals  { lines.append("vn \(n.x) \(n.y) \(n.z)") }
        lines.append("")
        lines.append(contentsOf: vtLines)
        lines.append("")
        if !texFaces.isEmpty {
            lines.append("usemtl TexturedMesh"); lines.append(contentsOf: texFaces); lines.append("")
        }
        if !unTexFaces.isEmpty {
            lines.append("usemtl UntexturedMesh"); lines.append(contentsOf: unTexFaces); lines.append("")
        }

        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        progress?(1.0)
        let pct = texFaces.isEmpty ? 0 : Int(100*texFaces.count/(texFaces.count+unTexFaces.count))
        log.log("Textured OBJ done — \(pct)% UV coverage")
    }

    func exportPLY(meshData: UnifiedMeshData, to url: URL) throws {
        log.log("Exporting PLY → \(url.lastPathComponent)")
        let header = "ply\nformat binary_little_endian 1.0\ncomment LiDAR Mapper\nelement vertex \(meshData.vertexCount)\nproperty float x\nproperty float y\nproperty float z\nproperty float nx\nproperty float ny\nproperty float nz\nelement face \(meshData.faceCount)\nproperty list uchar uint vertex_indices\nproperty uchar classification\nend_header\n"
        var data = Data(); data.append(header.data(using: .utf8)!)
        for i in 0..<meshData.vertexCount {
            var vx=meshData.vertices[i].x, vy=meshData.vertices[i].y, vz=meshData.vertices[i].z
            var nx=meshData.normals[i].x,  ny=meshData.normals[i].y,  nz=meshData.normals[i].z
            withUnsafeBytes(of: &vx){data.append(contentsOf:$0)}
            withUnsafeBytes(of: &vy){data.append(contentsOf:$0)}
            withUnsafeBytes(of: &vz){data.append(contentsOf:$0)}
            withUnsafeBytes(of: &nx){data.append(contentsOf:$0)}
            withUnsafeBytes(of: &ny){data.append(contentsOf:$0)}
            withUnsafeBytes(of: &nz){data.append(contentsOf:$0)}
        }
        for (i, face) in meshData.faces.enumerated() {
            var cnt: UInt8=3, i0=face.x, i1=face.y, i2=face.z
            var cls=UInt8(meshData.classifications[i].rawValue)
            withUnsafeBytes(of: &cnt){data.append(contentsOf:$0)}
            withUnsafeBytes(of: &i0) {data.append(contentsOf:$0)}
            withUnsafeBytes(of: &i1) {data.append(contentsOf:$0)}
            withUnsafeBytes(of: &i2) {data.append(contentsOf:$0)}
            withUnsafeBytes(of: &cls){data.append(contentsOf:$0)}
        }
        try data.write(to: url, options: .atomic)
        log.log("PLY done — \(data.count / 1_048_576) MB")
    }

    func exportColoredPLY(meshData: UnifiedMeshData,
                           frames:   [CapturedFrame],
                           to url:   URL,
                           progress: ((Double) -> Void)? = nil) throws {
        log.log("Exporting coloured PLY → \(url.lastPathComponent)")
        let vCount = meshData.vertexCount
        progress?(0.0)

        let samplers: [BitmapSampler?] = frames.enumerated().map { (i, f) in
            defer { progress?(0.10 * Double(i+1) / Double(max(1, frames.count))) }
            return BitmapSampler(jpeg: f.jpegData)
        }
        progress?(0.12)

        var colors = [SIMD3<UInt8>](repeating: SIMD3<UInt8>(150, 150, 150), count: vCount)

        for vi in 0..<vCount {
            let vertex = meshData.vertices[vi]
            let normal = meshData.normals[vi]
            var bestScore: Float = 0

            for (fi, frame) in frames.enumerated() {
                guard let score = frame.visibilityScore(faceCentroid: vertex,
                                                         faceNormal:   normal),
                      score > bestScore,
                      let uv  = frame.project(vertex),
                      let smp = samplers[fi] else { continue }
                bestScore = score
                let c = smp.sample(at: uv)
                colors[vi] = SIMD3<UInt8>(
                    UInt8(min(255, Int(c.x * 255))),
                    UInt8(min(255, Int(c.y * 255))),
                    UInt8(min(255, Int(c.z * 255))))
            }

            if vi % 8_000 == 0 {
                progress?(0.12 + 0.73 * Double(vi) / Double(max(1, vCount)))
            }
        }
        progress?(0.85)

        let header = """
        ply\r\nformat binary_little_endian 1.0\r\ncomment LiDAR Mapper — Coloured Point Cloud\r\n\
        element vertex \(vCount)\r\nproperty float x\r\nproperty float y\r\nproperty float z\r\n\
        property uchar red\r\nproperty uchar green\r\nproperty uchar blue\r\nend_header\r\n
        """
        var data = Data(); data.append(contentsOf: header.utf8)
        data.reserveCapacity(data.count + vCount * 15)

        for vi in 0..<vCount {
            var x = meshData.vertices[vi].x
            var y = meshData.vertices[vi].y
            var z = meshData.vertices[vi].z
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &z) { data.append(contentsOf: $0) }
            data.append(colors[vi].x)
            data.append(colors[vi].y)
            data.append(colors[vi].z)
        }

        try data.write(to: url, options: .atomic)
        progress?(1.0)
        log.log("Coloured PLY done — \(vCount) pts, \(data.count / 1_048_576)MB")
    }

    func exportAll(meshData: UnifiedMeshData,
                   frames:   [CapturedFrame],
                   baseURL:  URL,
                   progress: ((Double, String) -> Void)? = nil) throws {

        let dir  = baseURL.deletingLastPathComponent()
        let stem = baseURL.deletingPathExtension().lastPathComponent

        let geoURL = dir.appendingPathComponent(stem + ".obj")
        let texURL = dir.appendingPathComponent(stem + "_textured.obj")
        let plyURL = dir.appendingPathComponent(stem + ".ply")

        progress?(0.00, "Exporting geometry OBJ…")
        try exportOBJ(meshData: meshData, to: geoURL)
        progress?(0.08, "Geometry OBJ saved")

        if !frames.isEmpty {
            progress?(0.08, "Building seamless texture…")
            try exportSeamlessTextured(meshData: meshData, frames: frames, to: texURL) { p in
                progress?(0.08 + p * 0.74, p < 0.55 ? "Blending colours…" : "Baking texture…")
            }
        }
        progress?(0.82, "Textured OBJ saved")

        progress?(0.82, "Exporting point cloud…")
        if !frames.isEmpty {
            try exportColoredPLY(meshData: meshData, frames: frames, to: plyURL) { p in
                progress?(0.82 + p * 0.18, "Writing point cloud…")
            }
        } else {
            try exportPLY(meshData: meshData, to: plyURL)
        }
        progress?(1.0, "All formats saved ✓")
        log.log("exportAll complete — geo, textured, PLY")
    }

    // MARK: - Photogrammetry Export
    // Saves images + camera poses (transform + intrinsics) for use in external photogrammetry tools
    // (RealityKit Object Capture, COLMAP, Meshroom, Metashape, etc.)
    func exportPhotogrammetry(frames: [CapturedFrame],
                              to folderURL: URL,
                              progress: ((Double) -> Void)? = nil) throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        var poses: [[String: Any]] = []
        for (i, frame) in frames.enumerated() {
            let imgName = String(format: "image_%03d.jpg", i)
            let imgURL = folderURL.appendingPathComponent(imgName)
            try frame.jpegData.write(to: imgURL)

            // Camera pose (world transform) and intrinsics for photogrammetry
            let t = frame.cameraTransform
            let pose: [String: Any] = [
                "image": imgName,
                "transform": [
                    "columns": [
                        [t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w],
                        [t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w],
                        [t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w],
                        [t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w]
                    ]
                ],
                "intrinsics": [
                    [frame.intrinsics[0][0], frame.intrinsics[0][1], frame.intrinsics[0][2]],
                    [frame.intrinsics[1][0], frame.intrinsics[1][1], frame.intrinsics[1][2]],
                    [frame.intrinsics[2][0], frame.intrinsics[2][1], frame.intrinsics[2][2]]
                ],
                "imageSize": [frame.fullImageSize.width, frame.fullImageSize.height]
            ]
            poses.append(pose)
            progress?(Double(i) / Double(max(1, frames.count)))
        }

        let jsonURL = folderURL.appendingPathComponent("camera_poses.json")
        let jsonData = try JSONSerialization.data(withJSONObject: ["poses": poses], options: .prettyPrinted)
        try jsonData.write(to: jsonURL)

        log.log("Photogrammetry dataset exported: \(frames.count) images + poses to \(folderURL.lastPathComponent)")
    }

    func exportSeamlessTextured(meshData: UnifiedMeshData,
                                 frames:   [CapturedFrame],
                                 to url:   URL,
                                 progress: ((Double) -> Void)? = nil) throws {
        guard !frames.isEmpty else {
            try exportOBJ(meshData: meshData, to: url); progress?(1.0); return
        }
        log.log("Photographic textured OBJ → \(url.lastPathComponent)")
        let vCount = meshData.vertexCount
        let fCount = meshData.faceCount
        progress?(0.0)

        let maxSel  = min(24, frames.count)
        let step    = max(1, frames.count / maxSel)
        let sel     = stride(from: 0, to: frames.count, by: step)
                          .prefix(maxSel).map { frames[$0] }
        let nFrames = sel.count
        let nCols   = nFrames <= 4 ? nFrames : 4
        let nRows   = (nFrames + nCols - 1) / nCols

        let frameW  = Int(sel[0].textureSize.width)
        let frameH  = Int(sel[0].textureSize.height)
        let cellW_f = max(512.0, 8192.0 / Double(nCols))
        let cellW   = Int(cellW_f.rounded())
        let aspect  = frameH > 0 ? Double(frameH) / Double(frameW) : 1.0
        let cellH   = Int((cellW_f * aspect).rounded())
        let atlasW  = nCols * cellW
        let atlasH  = nRows * cellH
        progress?(0.04)

        let samplers: [BitmapSampler?] = sel.map { BitmapSampler(jpeg: $0.jpegData) }

        let lums: [Float] = sel.indices.map { fi in
            guard let s = samplers[fi] else { return 0.5 }
            var sum: Float = 0
            for r: Float in [0.25, 0.5, 0.75] {
                for c: Float in [0.25, 0.5, 0.75] {
                    let p = s.sample(at: SIMD2<Float>(c, r))
                    sum += 0.299*p.x + 0.587*p.y + 0.114*p.z
                }
            }
            return sum / 9
        }
        let medLum: Float = {
            let s = lums.sorted(); return s.isEmpty ? 0.5 : s[s.count / 2]
        }()
        let expScale: [Float] = lums.map { l in l > 0.02 ? min(3.0, medLum / l) : 1.0 }
        progress?(0.08)

        var faceFrame = [Int](repeating: 0, count: fCount)
        DispatchQueue.concurrentPerform(iterations: fCount) { fi in
            let face = meshData.faces[fi]
            let v0   = meshData.vertices[Int(face.x)]
            let v1   = meshData.vertices[Int(face.y)]
            let v2   = meshData.vertices[Int(face.z)]
            let cen  = (v0 + v1 + v2) / 3
            let cp   = simd_cross(v1 - v0, v2 - v0)
            let fn   = simd_length(cp) > 1e-8 ? simd_normalize(cp) : SIMD3<Float>(0,1,0)
            var bestScore: Float = -1, bestIdx = 0
            for (si, frame) in sel.enumerated() {
                if let sc = frame.visibilityScore(faceCentroid: cen, faceNormal: fn),
                   sc > bestScore { bestScore = sc; bestIdx = si }
            }
            faceFrame[fi] = bestIdx
        }
        progress?(0.22)

        for _ in 0..<4 {
            var vertVotes = [[Int: Int]](repeating: [:], count: vCount)
            for fi in 0..<fCount {
                let face = meshData.faces[fi]; let f = faceFrame[fi]
                for vi in [Int(face.x), Int(face.y), Int(face.z)] {
                    vertVotes[vi][f, default: 0] += 1
                }
            }
            for fi in 0..<fCount {
                let face = meshData.faces[fi]
                var votes = [Int: Int]()
                for vi in [Int(face.x), Int(face.y), Int(face.z)] {
                    for (f, cnt) in vertVotes[vi] { votes[f, default: 0] += cnt }
                }
                if let best = votes.max(by: { $0.value < $1.value }) {
                    faceFrame[fi] = best.key
                }
            }
        }
        progress?(0.40)

        var px = [UInt8](repeating: 100, count: atlasW * atlasH * 4)
        for (si, _) in sel.enumerated() {
            guard let smp = samplers[si] else { continue }
            let col = si % nCols, row = si / nCols
            let sc  = expScale[si]
            for py in 0..<cellH {
                let fv = (Float(py) + 0.5) / Float(cellH)
                for px2 in 0..<cellW {
                    let fu  = (Float(px2) + 0.5) / Float(cellW)
                    let c   = smp.sample(at: SIMD2<Float>(fu, fv))
                    let off = ((row * cellH + py) * atlasW + col * cellW + px2) * 4
                    px[off]   = UInt8(min(255, Int(c.x * sc * 255)))
                    px[off+1] = UInt8(min(255, Int(c.y * sc * 255)))
                    px[off+2] = UInt8(min(255, Int(c.z * sc * 255)))
                    px[off+3] = 255
                }
            }
        }
        progress?(0.62)

        let sp = CGColorSpaceCreateDeviceRGB()
        guard let cgCtx = CGContext(data: &px, width: atlasW, height: atlasH,
                                    bitsPerComponent: 8, bytesPerRow: atlasW * 4,
                                    space: sp,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let cgImg = cgCtx.makeImage() else {
            throw NSError(domain: "MeshExporter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Atlas CGContext failed"])
        }

        let size = CGSize(width: atlasW, height: atlasH)
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        let ctx2 = UIGraphicsGetCurrentContext()!
        ctx2.translateBy(x: 0, y: size.height)
        ctx2.scaleBy(x: 1, y: -1)
        ctx2.draw(cgImg, in: CGRect(origin: .zero, size: size))
        let flippedImg = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        guard let atlasJPG = flippedImg.jpegData(compressionQuality: 0.93) else {
            throw NSError(domain: "MeshExporter", code: 4, userInfo: [NSLocalizedDescriptionKey: "Atlas JPEG encode failed"])
        }
        progress?(0.72)

        let dir     = url.deletingLastPathComponent()
        let stem    = url.deletingPathExtension().lastPathComponent
        let texName = stem + "_texture.jpg"
        let mtlName = stem + ".mtl"
        try atlasJPG.write(to: dir.appendingPathComponent(texName))
        let mtl = "newmtl PhotoMesh\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nillum 1\nmap_Kd \(texName)\n"
        try mtl.write(to: dir.appendingPathComponent(mtlName), atomically: true, encoding: .utf8)
        progress?(0.76)

        func clampProject(_ v: SIMD3<Float>, _ frame: CapturedFrame) -> SIMD2<Float> {
            let cam = (frame.cameraTransform.inverse * SIMD4<Float>(v.x, v.y, v.z, 1)).xyz
            guard cam.z < -1e-4 else { return SIMD2<Float>(0.5, 0.5) }
            let d  = -cam.z
            let fx = frame.intrinsics[0][0], fy = frame.intrinsics[1][1]
            let cx = frame.intrinsics[2][0], cy = frame.intrinsics[2][1]
            let u  = max(0.005, min(0.995, (fx * cam.x / d + cx) / Float(frame.fullImageSize.width)))
            let v2 = max(0.005, min(0.995, (-fy * cam.y / d + cy) / Float(frame.fullImageSize.height)))
            return SIMD2<Float>(u, v2)
        }

        struct UVKey: Hashable { let u, v: Int32
            init(_ uv: SIMD2<Float>) { u = Int32(uv.x * 1_000_000); v = Int32(uv.y * 1_000_000) }
        }
        var vtMap = [UVKey: Int](); var vtList = [SIMD2<Float>]()
        var faceVT = [(Int, Int, Int)](); faceVT.reserveCapacity(fCount)

        func addVT(_ uv: SIMD2<Float>) -> Int {
            let k = UVKey(uv)
            if let i = vtMap[k] { return i }
            let i = vtList.count; vtList.append(uv); vtMap[k] = i; return i
        }

        for fi in 0..<fCount {
            let face  = meshData.faces[fi]
            let si    = faceFrame[fi]
            let frame = sel[si]
            let col   = si % nCols, row = si / nCols

            func atlasUV(_ v: SIMD3<Float>) -> SIMD2<Float> {
                let fuv = clampProject(v, frame)
                let au  = (Float(col) + fuv.x) / Float(nCols)
                let av  = 1.0 - (Float(row) + fuv.y) / Float(nRows)
                return SIMD2<Float>(au, av)
            }
            let v0 = meshData.vertices[Int(face.x)]
            let v1 = meshData.vertices[Int(face.y)]
            let v2 = meshData.vertices[Int(face.z)]
            faceVT.append((addVT(atlasUV(v0)), addVT(atlasUV(v1)), addVT(atlasUV(v2))))
        }
        progress?(0.88)

        var lines = [
            "# LiDAR Mapper — Photographic Textured OBJ",
            "# Camera-frame atlas with cluster-smoothed assignments",
            "# \(ISO8601DateFormatter().string(from: Date()))",
            "mtllib \(mtlName)", "o LiDARScan", ""
        ]
        for v in meshData.vertices { lines.append("v \(v.x) \(v.y) \(v.z)") }
        lines.append("")
        for n in meshData.normals  { lines.append("vn \(n.x) \(n.y) \(n.z)") }
        lines.append("")
        for uv in vtList           { lines.append("vt \(uv.x) \(uv.y)") }
        lines.append(""); lines.append("usemtl PhotoMesh")
        for (fi, face) in meshData.faces.enumerated() {
            let (a,b,c)   = (Int(face.x)+1, Int(face.y)+1, Int(face.z)+1)
            let (ta,tb,tc) = faceVT[fi]
            lines.append("f \(a)/\(ta+1)/\(a) \(b)/\(tb+1)/\(b) \(c)/\(tc+1)/\(c)")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        progress?(1.0)
        log.log("Photographic OBJ done — \(nFrames) frames in \(nCols)×\(nRows) atlas " +
                "\(atlasW)×\(atlasH), \(vtList.count) UVs")
    }

}  // end MeshExporter

// MARK: - BitmapSampler

struct BitmapSampler {
    private let bytes:  [UInt8]
    private let width:  Int
    private let height: Int

    init?(jpeg: Data) {
        guard let img = UIImage(data: jpeg), let cg = img.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let sp  = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buf, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4, space: sp,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        bytes = buf; width = w; height = h
    }

    func sample(at uv: SIMD2<Float>) -> SIMD3<Float> {
        let px = min(width-1,  max(0, Int(uv.x * Float(width))))
        let py = min(height-1, max(0, Int(uv.y * Float(height))))
        let o  = py * width * 4 + px * 4
        return SIMD3<Float>(Float(bytes[o])/255, Float(bytes[o+1])/255, Float(bytes[o+2])/255)
    }
}