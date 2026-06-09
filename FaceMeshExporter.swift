// FaceMeshExporter.swift — LiDARMapper
// Face mesh export with corrected texture orientation/alignment for front camera.
// Texture image is vertically flipped to match OBJ vt convention (v=0 at bottom) and ARKit UVs.

import ARKit
import simd
import Foundation
import UIKit
import CoreGraphics

extension MeshExporter {

    func exportFaceMesh(snapshots: [FaceSnapshot],
                        frames: [CapturedFrame],
                        to url: URL,
                        progress: ((Double) -> Void)? = nil) throws {

        let logger = AppLogger.shared
        logger.log("Exporting face mesh: \(snapshots.count) snapshot(s)")
        progress?(0.0)

        guard let snap = snapshots.max(by: { $0.vertices.count < $1.vertices.count }) else {
            let err = NSError(domain: "MeshExporter", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "No face snapshot available."])
            throw err
        }

        let baseName   = url.deletingPathExtension().lastPathComponent
        let hasTexture = !frames.isEmpty

        var texName: String?
        if hasTexture, let bestFrame = frames.last {
            texName = baseName + "_face_texture.jpg"
            let texURL = url.deletingLastPathComponent().appendingPathComponent(texName!)

            // Correct orientation: vertically flip the texture image so it aligns with OBJ vt (v=0 bottom)
            if let srcImg = UIImage(data: bestFrame.jpegData),
               let cg = srcImg.cgImage {
                let w = cg.width, h = cg.height
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                if let ctx = CGContext(data: nil, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.translateBy(x: 0, y: CGFloat(h))
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                    if let flippedCG = ctx.makeImage() {
                        let flippedData = UIImage(cgImage: flippedCG).jpegData(compressionQuality: 0.90) ?? bestFrame.jpegData
                        try flippedData.write(to: texURL)
                    } else {
                        try bestFrame.jpegData.write(to: texURL)
                    }
                } else {
                    try bestFrame.jpegData.write(to: texURL)
                }
            } else {
                try bestFrame.jpegData.write(to: texURL)
            }
        }
        progress?(0.20)

        let mtlName = baseName + ".mtl"
        let mtlURL  = url.deletingLastPathComponent().appendingPathComponent(mtlName)
        var mtl = "newmtl FaceMaterial\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nillum 1\n"
        if let tex = texName { mtl += "map_Kd \(tex)\n" }
        try mtl.write(to: mtlURL, atomically: true, encoding: .utf8)
        progress?(0.30)

        let worldVerts: [SIMD3<Float>] = snap.vertices.map {
            snap.transform.transformPoint($0)
        }
        progress?(0.40)

        let triCount = snap.triangleCount
        let idxBuf   = snap.triangleIndices
        var normals  = [SIMD3<Float>](repeating: .zero, count: worldVerts.count)

        for t in 0..<triCount {
            let i0 = Int(idxBuf[t*3])
            let i1 = Int(idxBuf[t*3+1])
            let i2 = Int(idxBuf[t*3+2])
            guard i0 < worldVerts.count, i1 < worldVerts.count, i2 < worldVerts.count else { continue }
            let fn = cross(worldVerts[i1] - worldVerts[i0], worldVerts[i2] - worldVerts[i0])
            normals[i0] += fn; normals[i1] += fn; normals[i2] += fn
        }
        normals = normals.map { n in
            let l = length(n); return l > 1e-6 ? n / l : SIMD3<Float>(0, 1, 0)
        }
        progress?(0.55)

        var lines = [
            "# LiDAR Mapper — TrueDepth Face Scan",
            "# Date: \(ISO8601DateFormatter().string(from: Date()))",
            "mtllib \(mtlName)",
            "o FaceScan", ""
        ]
        for v in worldVerts { lines.append("v \(v.x) \(v.y) \(v.z)") }
        lines.append("")
        for n in normals    { lines.append("vn \(n.x) \(n.y) \(n.z)") }
        lines.append("")
        // vt with v-flip to match the corrected (flipped) texture image orientation
        for uv in snap.textureCoordinates { lines.append("vt \(uv.x) \(1.0 - uv.y)") }
        lines.append("")
        lines.append("usemtl FaceMaterial")

        for t in 0..<triCount {
            let i0 = Int(idxBuf[t*3]) + 1
            let i1 = Int(idxBuf[t*3+1]) + 1
            let i2 = Int(idxBuf[t*3+2]) + 1
            lines.append("f \(i0)/\(i0)/\(i0) \(i1)/\(i1)/\(i1) \(i2)/\(i2)/\(i2)")
        }

        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        progress?(1.0)
        logger.log("Face mesh done — \(worldVerts.count) verts, \(triCount) triangles")
    }
}
