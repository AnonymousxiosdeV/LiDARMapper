// ARGeometry+Extensions.swift — LiDARMapper
// IMPORTANT: Do NOT import SwiftUI here.
// SwiftUI's View.offset() modifier causes a compiler conflict with
// ARGeometrySource.offset when both are in scope.
// Color helpers live in ARClassification+SwiftUI.swift (separate file).

import ARKit
import SceneKit
import simd
import UIKit

// MARK: - ARMeshGeometry Accessors

extension ARMeshGeometry {

    /// Vertex position (local anchor space) at index.
    func vertexPosition(at index: Int) -> SIMD3<Float> {
        let src: ARGeometrySource = vertices   // explicit non-optional type
        let buf = src.buffer.contents()
        let off: Int = src.offset              // Int local var — no SwiftUI ambiguity
        let str: Int = src.stride
        return buf.advanced(by: off + index * str)
                  .assumingMemoryBound(to: SIMD3<Float>.self)
                  .pointee
    }

    /// Normal vector (local anchor space) at index.
    func normalVector(at index: Int) -> SIMD3<Float> {
        let src: ARGeometrySource = normals
        let buf = src.buffer.contents()
        let off: Int = src.offset
        let str: Int = src.stride
        return buf.advanced(by: off + index * str)
                  .assumingMemoryBound(to: SIMD3<Float>.self)
                  .pointee
    }

    /// Three vertex indices for a triangle face. Handles UInt16 and UInt32 buffers.
    func triangleIndices(at faceIndex: Int) -> (UInt32, UInt32, UInt32) {
        let el: ARGeometryElement = faces
        let byteOff = faceIndex * el.indexCountPerPrimitive * el.bytesPerIndex
        let base    = el.buffer.contents().advanced(by: byteOff)
        if el.bytesPerIndex == MemoryLayout<UInt16>.size {
            let p = base.assumingMemoryBound(to: UInt16.self)
            return (UInt32(p[0]), UInt32(p[1]), UInt32(p[2]))
        } else {
            let p = base.assumingMemoryBound(to: UInt32.self)
            return (p[0], p[1], p[2])
        }
    }

    /// Surface classification for a face index.
    /// classification is Optional<ARGeometrySource> in ARKit — returns .none if unavailable.
    func faceClassification(at faceIndex: Int) -> ARMeshClassification {
        guard let src: ARGeometrySource = classification else { return .none }
        let off: Int = src.offset
        let str: Int = src.stride
        let raw = src.buffer.contents()
                    .advanced(by: off + faceIndex * str)
                    .assumingMemoryBound(to: UInt8.self)
                    .pointee
        return ARMeshClassification(rawValue: Int(raw)) ?? .none
    }

    /// Most common classification across all faces in this tile.
    func dominantClassification() -> ARMeshClassification {
        guard classification != nil else { return .none }
        var counts = [Int: Int]()
        for i in 0..<faces.count {
            let key = faceClassification(at: i).rawValue
            counts[key, default: 0] += 1
        }
        let best = counts.max { $0.value < $1.value }?.key ?? 0
        return ARMeshClassification(rawValue: best) ?? .none
    }
}

// MARK: - SCNGeometry from ARMeshGeometry (zero-copy Metal buffer)

extension SCNGeometry {

    convenience init(arMesh mesh: ARMeshGeometry) {
        let vSrc:  ARGeometrySource  = mesh.vertices
        let nSrc:  ARGeometrySource  = mesh.normals
        let faceEl: ARGeometryElement = mesh.faces

        let vOff: Int = vSrc.offset;  let vStr: Int = vSrc.stride
        let nOff: Int = nSrc.offset;  let nStr: Int = nSrc.stride

        let vertexSource = SCNGeometrySource(
            buffer:       vSrc.buffer,
            vertexFormat: .float3,
            semantic:     .vertex,
            vertexCount:  vSrc.count,
            dataOffset:   vOff,
            dataStride:   vStr
        )

        let normalSource = SCNGeometrySource(
            buffer:       nSrc.buffer,
            vertexFormat: .float3,
            semantic:     .normal,
            vertexCount:  nSrc.count,
            dataOffset:   nOff,
            dataStride:   nStr
        )

        let faceByteCount = faceEl.count * faceEl.indexCountPerPrimitive * faceEl.bytesPerIndex
        let faceData = Data(
            bytesNoCopy: faceEl.buffer.contents(),
            count:       faceByteCount,
            deallocator: .none
        )

        let element = SCNGeometryElement(
            data:           faceData,
            primitiveType:  .triangles,
            primitiveCount: faceEl.count,
            bytesPerIndex:  faceEl.bytesPerIndex
        )

        self.init(sources: [vertexSource, normalSource], elements: [element])
    }
}

// MARK: - SIMD Helpers

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

extension float4x4 {
    func transformPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        (self * SIMD4<Float>(p.x, p.y, p.z, 1.0)).xyz
    }
}

// MARK: - UIColor helpers (no SwiftUI import needed here)

extension ARMeshClassification {

    var displayName: String {
        switch self {
        case .none:    return "Unknown"
        case .wall:    return "Wall"
        case .floor:   return "Floor"
        case .ceiling: return "Ceiling"
        case .table:   return "Table"
        case .seat:    return "Chair"
        case .window:  return "Window"
        case .door:    return "Door"
        default:       return "Other"
        }
    }

    var overlayColor: UIColor {
        switch self {
        case .floor:   return UIColor(red: 0.30, green: 0.85, blue: 0.30, alpha: 0.65)
        case .wall:    return UIColor(red: 0.30, green: 0.55, blue: 1.00, alpha: 0.65)
        case .ceiling: return UIColor(red: 1.00, green: 0.90, blue: 0.25, alpha: 0.65)
        case .table:   return UIColor(red: 1.00, green: 0.50, blue: 0.15, alpha: 0.65)
        case .seat:    return UIColor(red: 0.70, green: 0.25, blue: 1.00, alpha: 0.65)
        case .window:  return UIColor(red: 0.20, green: 0.90, blue: 0.90, alpha: 0.65)
        case .door:    return UIColor(red: 0.90, green: 0.35, blue: 0.35, alpha: 0.65)
        default:       return UIColor(white: 0.75, alpha: 0.45)
        }
    }
}
