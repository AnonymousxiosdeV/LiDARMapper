// MeshProcessor.swift — LiDARMapper
// Post-scan mesh enhancement applied to saved OBJ files in the library.

import Foundation
import simd
import CoreImage
import UIKit

// MARK: - ProcessOptions

struct ProcessOptions {
    var removeDegenerateFaces:    Bool  = true
    var weldThreshold:            Float = 0.001
    var removeLooseGeometry:      Bool  = true
    var removeSmallComponents:    Bool  = true
    var minComponentFaces:        Int   = 40   // slightly lower for cleaner but denser meshes
    var smoothingIterations:      Int   = 4    // more smoothing for quality
    var smoothingLambda:          Float = 0.50
    var smoothingMu:              Float = -0.53
    var recomputeNormals:         Bool  = true
    var enhanceTexture:           Bool  = true
    var textureTargetPx:          Int   = 4096
    var textureSharpness:         Float = 0.85  // stronger sharpen
}

// MARK: - ProcessResult

struct ProcessResult {
    let vertsBefore: Int;  let vertsAfter:  Int
    let facesBefore: Int;  let facesAfter:  Int
    let textureEnhanced: Bool
    let timeSec: Double
}

// MARK: - MeshProcessor

final class MeshProcessor {

    private let log = AppLogger.shared

    private struct OBJFace {
        var vi: SIMD3<UInt32>
        var ti: SIMD3<Int>
        var ni: SIMD3<Int>
        var group:    String
        var material: String
    }

    func process(objURL: URL,
                 options: ProcessOptions,
                 progress: ((Double, String) -> Void)? = nil) throws -> ProcessResult {

        let start = Date()
        log.log("Processing: \(objURL.lastPathComponent)")

        progress?(0.04, "Parsing OBJ…")
        var (verts, normals, uvs, faces, mtlLine, groups) = try parseOBJ(url: objURL)
        let vertsBefore = verts.count, facesBefore = faces.count
        log.debug("Parsed: \(verts.count) verts, \(faces.count) faces")

        if options.removeDegenerateFaces {
            progress?(0.10, "Removing degenerate faces…")
            let before = faces.count
            faces = faces.filter { f in
                let v0 = verts[Int(f.vi.x)], v1 = verts[Int(f.vi.y)], v2 = verts[Int(f.vi.z)]
                return length(cross(v1-v0, v2-v0)) * 0.5 > 1e-7
            }
            log.debug("Degenerate removal: \(before) → \(faces.count) faces")
        }

        progress?(0.20, "Welding duplicate vertices…")
        let (weldedVerts, remapTable) = weldVertices(verts, threshold: options.weldThreshold)
        faces = faces.map { f in
            OBJFace(vi: SIMD3<UInt32>(remapTable[Int(f.vi.x)],
                                      remapTable[Int(f.vi.y)],
                                      remapTable[Int(f.vi.z)]),
                    ti: f.ti, ni: f.ni, group: f.group, material: f.material)
        }
        verts = weldedVerts
        log.debug("After weld: \(verts.count) verts")

        if options.removeLooseGeometry {
            progress?(0.30, "Removing loose geometry…")
            (verts, faces) = compactVertices(verts: verts, faces: faces)
            log.debug("After loose removal: \(verts.count) verts, \(faces.count) faces")
        }

        if options.removeSmallComponents && options.minComponentFaces > 0 {
            progress?(0.40, "Removing floating artifacts…")
            let before = faces.count
            (verts, faces) = removeSmallComponents(verts: verts, faces: faces,
                                                    minFaces: options.minComponentFaces)
            log.debug("Component removal: \(before) → \(faces.count) faces")
        }

        if options.smoothingIterations > 0 {
            progress?(0.50, "Smoothing surface (Taubin)…")
            verts = taubinSmooth(verts: verts, faces: faces,
                                 iterations: options.smoothingIterations,
                                 lambda: options.smoothingLambda,
                                 mu: options.smoothingMu)
        }

        if options.recomputeNormals {
            progress?(0.60, "Recomputing normals…")
            normals = computeNormals(verts: verts, faces: faces)
            faces = faces.map { f in
                OBJFace(vi: f.vi,
                        ti: f.ti,
                        ni: SIMD3<Int>(Int(f.vi.x), Int(f.vi.y), Int(f.vi.z)),
                        group: f.group, material: f.material)
            }
        }

        progress?(0.70, "Writing OBJ…")
        try writeOBJ(url: objURL, verts: verts, normals: normals, uvs: uvs,
                     faces: faces, mtlLine: mtlLine, groups: groups)

        var textureEnhanced = false
        if options.enhanceTexture {
            progress?(0.78, "Enhancing texture…")
            let baseName = objURL.deletingPathExtension().lastPathComponent
            let dir      = objURL.deletingLastPathComponent()
            for suffix in ["_texture", "_face_texture", ""] {
                for ext in ["jpg", "jpeg", "png"] {
                    let texURL = dir.appendingPathComponent(baseName + suffix + ".\(ext)")
                    guard FileManager.default.fileExists(atPath: texURL.path) else { continue }
                    if let data = enhanceTexture(url: texURL,
                                                  targetPx: options.textureTargetPx,
                                                  sharpness: options.textureSharpness) {
                        try data.write(to: texURL)
                        textureEnhanced = true
                        log.log("Texture enhanced: \(texURL.lastPathComponent)")
                    }
                }
            }
        }

        progress?(1.0, "Done")
        let elapsed = Date().timeIntervalSince(start)

        let vertsAfter = verts.count
        let facesAfter = faces.count
        log.log("Done in \(String(format:"%.1f",elapsed))s — " +
                "\(vertsBefore)→\(vertsAfter) verts, \(facesBefore)→\(facesAfter) faces")

        return ProcessResult(vertsBefore: vertsBefore, vertsAfter: vertsAfter,
                             facesBefore: facesBefore, facesAfter: facesAfter,
                             textureEnhanced: textureEnhanced, timeSec: elapsed)
    }

    private func parseOBJ(url: URL) throws -> (
        verts:   [SIMD3<Float>],
        normals: [SIMD3<Float>],
        uvs:     [SIMD2<Float>],
        faces:   [OBJFace],
        mtlLine: String?,
        groups:  [String]
    ) {
        let text = try String(contentsOf: url, encoding: .utf8)
        var verts   = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        var uvs     = [SIMD2<Float>]()
        var faces   = [OBJFace]()
        var mtlLine: String?
        var groups  = [String]()
        var curGroup    = "default"
        var curMaterial = "default"

        func resolveIdx(_ raw: Int, count: Int) -> Int {
            raw < 0 ? count + raw : raw - 1
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard !parts.isEmpty else { continue }
            switch parts[0] {
            case "v":
                guard parts.count >= 4 else { continue }
                verts.append(SIMD3<Float>(Float(parts[1]) ?? 0,
                                          Float(parts[2]) ?? 0,
                                          Float(parts[3]) ?? 0))
            case "vn":
                guard parts.count >= 4 else { continue }
                normals.append(SIMD3<Float>(Float(parts[1]) ?? 0,
                                             Float(parts[2]) ?? 0,
                                             Float(parts[3]) ?? 0))
            case "vt":
                guard parts.count >= 3 else { continue }
                uvs.append(SIMD2<Float>(Float(parts[1]) ?? 0,
                                        Float(parts[2]) ?? 0))
            case "f":
                guard parts.count >= 4 else { continue }
                var vis = [Int](), tis = [Int](), nis = [Int]()
                for p in parts[1...] {
                    let comps = p.split(separator: "/", omittingEmptySubsequences: false)
                    vis.append(resolveIdx(Int(comps[0]) ?? 1, count: verts.count))
                    tis.append(comps.count > 1 && !comps[1].isEmpty
                        ? resolveIdx(Int(comps[1]) ?? 1, count: uvs.count) : -1)
                    nis.append(comps.count > 2 && !comps[2].isEmpty
                        ? resolveIdx(Int(comps[2]) ?? 1, count: normals.count) : -1)
                }
                for i in 1..<(vis.count - 1) {
                    let vi = SIMD3<UInt32>(UInt32(max(0, vis[0])),
                                           UInt32(max(0, vis[i])),
                                           UInt32(max(0, vis[i+1])))
                    faces.append(OBJFace(vi: vi,
                                         ti: SIMD3<Int>(tis[0], tis[i], tis[i+1]),
                                         ni: SIMD3<Int>(nis[0], nis[i], nis[i+1]),
                                         group: curGroup, material: curMaterial))
                }
            case "mtllib": mtlLine = parts.dropFirst().joined(separator: " ")
            case "g", "o":
                curGroup = parts.dropFirst().joined(separator: "_")
                if !groups.contains(curGroup) { groups.append(curGroup) }
            case "usemtl": curMaterial = parts.dropFirst().joined(separator: " ")
            default: break
            }
        }
        return (verts, normals, uvs, faces, mtlLine, groups)
    }

    private func weldVertices(_ verts: [SIMD3<Float>],
                               threshold: Float) -> ([SIMD3<Float>], [UInt32]) {
        var result = [SIMD3<Float>]()
        var remap  = [UInt32](repeating: 0, count: verts.count)
        var grid   = [SIMD3<Int32>: Int]()
        let invT   = 1.0 / max(threshold, 1e-9)

        for (i, v) in verts.enumerated() {
            let cell = SIMD3<Int32>(Int32(floor(v.x * invT)),
                                    Int32(floor(v.y * invT)),
                                    Int32(floor(v.z * invT)))
            if let idx = grid[cell] { remap[i] = UInt32(idx); continue }

            var bestIdx:  Int?   = nil
            var bestDist: Float  = threshold * threshold
            for dx in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dz in Int32(-1)...1 {
                        guard dx != 0 || dy != 0 || dz != 0 else { continue }
                        if let idx = grid[cell &+ SIMD3<Int32>(dx, dy, dz)] {
                            let d = simd_distance_squared(v, result[idx])
                            if d < bestDist { bestDist = d; bestIdx = idx }
                        }
                    }
                }
            }
            if let idx = bestIdx { remap[i] = UInt32(idx) }
            else {
                let idx = result.count
                grid[cell] = idx; remap[i] = UInt32(idx); result.append(v)
            }
        }
        return (result, remap)
    }

    private func compactVertices(verts: [SIMD3<Float>],
                                  faces: [OBJFace]) -> ([SIMD3<Float>], [OBJFace]) {
        var used    = Set<Int>()
        faces.forEach { used.insert(Int($0.vi.x)); used.insert(Int($0.vi.y)); used.insert(Int($0.vi.z)) }

        var compact     = [Int](repeating: -1, count: verts.count)
        var newVerts    = [SIMD3<Float>]()
        newVerts.reserveCapacity(used.count)
        for i in 0..<verts.count where used.contains(i) {
            compact[i] = newVerts.count; newVerts.append(verts[i])
        }
        let newFaces = faces.compactMap { f -> OBJFace? in
            let a = compact[Int(f.vi.x)], b = compact[Int(f.vi.y)], c = compact[Int(f.vi.z)]
            guard a >= 0, b >= 0, c >= 0 else { return nil }
            return OBJFace(vi: SIMD3<UInt32>(UInt32(a), UInt32(b), UInt32(c)),
                           ti: f.ti, ni: f.ni, group: f.group, material: f.material)
        }
        return (newVerts, newFaces)
    }

    private func removeSmallComponents(verts: [SIMD3<Float>],
                                        faces: [OBJFace],
                                        minFaces: Int) -> ([SIMD3<Float>], [OBJFace]) {
        guard !faces.isEmpty else { return (verts, faces) }

        var parent = Array(0..<verts.count)
        var rank   = [Int](repeating: 0, count: verts.count)

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            if rank[ra] < rank[rb] { parent[ra] = rb }
            else if rank[ra] > rank[rb] { parent[rb] = ra }
            else { parent[rb] = ra; rank[ra] += 1 }
        }

        for f in faces {
            let a = Int(f.vi.x), b = Int(f.vi.y), c = Int(f.vi.z)
            union(a, b); union(b, c)
        }

        var compFaceCount = [Int: Int]()
        for f in faces { compFaceCount[find(Int(f.vi.x)), default: 0] += 1 }

        let largest   = compFaceCount.values.max() ?? 0
        let threshold = max(minFaces, Int(Double(largest) * 0.005))

        let keptFaces = faces.filter { compFaceCount[find(Int($0.vi.x)), default: 0] >= threshold }
        return compactVertices(verts: verts, faces: keptFaces)
    }

    private func taubinSmooth(verts: [SIMD3<Float>], faces: [OBJFace],
                               iterations: Int, lambda: Float, mu: Float) -> [SIMD3<Float>] {
        var adjSet = [Int: Set<Int>](minimumCapacity: verts.count)
        for f in faces {
            let (a, b, c) = (Int(f.vi.x), Int(f.vi.y), Int(f.vi.z))
            adjSet[a, default: []].formUnion([b, c])
            adjSet[b, default: []].formUnion([a, c])
            adjSet[c, default: []].formUnion([a, b])
        }
        let adj = (0..<verts.count).map { Array(adjSet[$0] ?? []) }

        func step(_ v: [SIMD3<Float>], factor: Float) -> [SIMD3<Float>] {
            var out = v
            for i in 0..<v.count {
                let nb = adj[i]; guard !nb.isEmpty else { continue }
                let avg = nb.reduce(SIMD3<Float>.zero) { $0 + v[$1] } / Float(nb.count)
                out[i] = v[i] + (avg - v[i]) * factor
            }
            return out
        }

        var result = verts
        for _ in 0..<iterations {
            result = step(result, factor: lambda)
            result = step(result, factor: mu)
        }
        return result
    }

    private func computeNormals(verts: [SIMD3<Float>], faces: [OBJFace]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: verts.count)
        for f in faces {
            let (i0, i1, i2) = (Int(f.vi.x), Int(f.vi.y), Int(f.vi.z))
            guard i0 < verts.count, i1 < verts.count, i2 < verts.count else { continue }
            let v0 = verts[i0], v1 = verts[i1], v2 = verts[i2]
            let faceNormal = normalize(cross(v1-v0, v2-v0))
            guard !faceNormal.x.isNaN else { continue }
            func angle(origin: SIMD3<Float>, a: SIMD3<Float>, b: SIMD3<Float>) -> Float {
                let da = normalize(a - origin), db = normalize(b - origin)
                return acos(max(-1, min(1, dot(da, db))))
            }
            normals[i0] += faceNormal * angle(origin: v0, a: v1, b: v2)
            normals[i1] += faceNormal * angle(origin: v1, a: v0, b: v2)
            normals[i2] += faceNormal * angle(origin: v2, a: v0, b: v1)
        }
        return normals.map { n in
            let l = length(n); return l > 1e-6 ? n / l : SIMD3<Float>(0, 1, 0)
        }
    }

    private func writeOBJ(url: URL,
                           verts:   [SIMD3<Float>],
                           normals: [SIMD3<Float>],
                           uvs:     [SIMD2<Float>],
                           faces:   [OBJFace],
                           mtlLine: String?,
                           groups:  [String]) throws {

        var lines = ["# LiDAR Mapper — Enhanced Mesh",
                     "# \(ISO8601DateFormatter().string(from: Date()))"]
        if let mtl = mtlLine { lines.append("mtllib \(mtl)") }
        lines.append("")

        for v  in verts   { lines.append("v \(v.x) \(v.y) \(v.z)") }
        lines.append("")
        for n  in normals { lines.append("vn \(n.x) \(n.y) \(n.z)") }
        lines.append("")
        for uv in uvs     { lines.append("vt \(uv.x) \(uv.y)") }
        lines.append("")

        var byMaterial = [String: [OBJFace]]()
        for f in faces { byMaterial[f.material, default: []].append(f) }

        for mat in byMaterial.keys.sorted() {
            lines.append("usemtl \(mat)")
            for f in byMaterial[mat]! {
                let (a, b, c) = (Int(f.vi.x)+1, Int(f.vi.y)+1, Int(f.vi.z)+1)
                if f.ti.x >= 0 && f.ni.x >= 0 {
                    lines.append("f \(a)/\(f.ti.x+1)/\(f.ni.x+1)" +
                                 " \(b)/\(f.ti.y+1)/\(f.ti.z+1)" +
                                 " \(c)/\(f.ti.z+1)/\(f.ni.z+1)")
                } else if f.ni.x >= 0 {
                    lines.append("f \(a)//\(f.ni.x+1) \(b)//\(f.ni.y+1) \(c)//\(f.ni.z+1)")
                } else if f.ti.x >= 0 {
                    lines.append("f \(a)/\(f.ti.x+1) \(b)/\(f.ti.y+1) \(c)/\(f.ti.z+1)")
                } else {
                    lines.append("f \(a) \(b) \(c)")
                }
            }
            lines.append("")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func enhanceTexture(url: URL,
                                 targetPx: Int,
                                 sharpness: Float) -> Data? {

        guard let src = CIImage(contentsOf: url) else { return nil }
        let ctx = CIContext(options: [.useSoftwareRenderer: false,
                                      .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        var img = src

        if let f = CIFilter(name: "CINoiseReduction") {
            f.setValue(img,  forKey: kCIInputImageKey)
            f.setValue(0.02, forKey: "inputNoiseLevel")
            f.setValue(0.50, forKey: "inputSharpness")
            img = f.outputImage ?? img
        }

        if let f = CIFilter(name: "CIColorControls") {
            f.setValue(img,  forKey: kCIInputImageKey)
            f.setValue(0.03, forKey: kCIInputBrightnessKey)
            f.setValue(1.10, forKey: kCIInputContrastKey)
            f.setValue(1.12, forKey: kCIInputSaturationKey)
            img = f.outputImage ?? img
        }

        if let f = CIFilter(name: "CIVibrance") {
            f.setValue(img,  forKey: kCIInputImageKey)
            f.setValue(0.25, forKey: "inputAmount")
            img = f.outputImage ?? img
        }

        let preRadius    = 1.5 * Double(sharpness)
        let preIntensity = 0.5 * Double(sharpness)
        if sharpness > 0.05, let f = CIFilter(name: "CIUnsharpMask") {
            f.setValue(img,         forKey: kCIInputImageKey)
            f.setValue(preRadius,   forKey: kCIInputRadiusKey)
            f.setValue(preIntensity,forKey: kCIInputIntensityKey)
            img = f.outputImage ?? img
        }

        let longEdge = max(img.extent.width, img.extent.height)
        let didUpscale: Bool
        if targetPx > 0 && longEdge < CGFloat(targetPx) - 16 {
            let scale = CGFloat(targetPx) / longEdge
            if let f = CIFilter(name: "CILanczosScaleTransform") {
                f.setValue(img,   forKey: kCIInputImageKey)
                f.setValue(scale, forKey: kCIInputScaleKey)
                f.setValue(1.0,   forKey: kCIInputAspectRatioKey)
                img = f.outputImage ?? img
            }
            didUpscale = true
        } else { didUpscale = false }

        if didUpscale && sharpness > 0.05, let f = CIFilter(name: "CIUnsharpMask") {
            let postRadius    = 2.5 * Double(sharpness)
            let postIntensity = 0.65 * Double(sharpness)
            f.setValue(img,          forKey: kCIInputImageKey)
            f.setValue(postRadius,   forKey: kCIInputRadiusKey)
            f.setValue(postIntensity,forKey: kCIInputIntensityKey)
            img = f.outputImage ?? img
        }

        guard let cg = ctx.createCGImage(img, from: img.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.95)
    }
}
