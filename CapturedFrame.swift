// CapturedFrame.swift — LiDARMapper
// Higher-res frame capture (0.75 scale) for sharper texture detail.

import ARKit
import UIKit
import simd
import CoreImage
import CoreGraphics

// MARK: - CapturedFrame

struct CapturedFrame {
    let cameraTransform: simd_float4x4
    let intrinsics:      simd_float3x3
    let fullImageSize:   CGSize
    let jpegData:        Data
    let textureSize:     CGSize

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // 0.75 scale = better texture sharpness (was 0.5). Memory trade-off acceptable on Pro devices.
    init?(arFrame: ARFrame, scale: CGFloat = 0.75) {
        guard let image = Self.extractImage(arFrame.capturedImage, scale: scale),
              let jpeg  = image.jpegData(compressionQuality: 0.85) else { return nil }
        self.cameraTransform = arFrame.camera.transform
        self.intrinsics      = arFrame.camera.intrinsics
        self.fullImageSize   = arFrame.camera.imageResolution
        self.jpegData        = jpeg
        self.textureSize     = image.size
    }

    func project(_ worldPos: SIMD3<Float>) -> SIMD2<Float>? {
        let camPos = (cameraTransform.inverse * SIMD4<Float>(worldPos.x, worldPos.y, worldPos.z, 1)).xyz
        guard camPos.z < 0 else { return nil }
        let depth = -camPos.z
        let fx = intrinsics[0][0], fy = intrinsics[1][1]
        let cx = intrinsics[2][0], cy = intrinsics[2][1]
        let px = fx * (camPos.x / depth) + cx
        let py = -fy * (camPos.y / depth) + cy
        let u = px / Float(fullImageSize.width)
        let v = py / Float(fullImageSize.height)
        let edge: Float = 0.02
        guard u >= edge, u <= 1-edge, v >= edge, v <= 1-edge else { return nil }
        return SIMD2<Float>(u, v)
    }

    func visibilityScore(faceCentroid: SIMD3<Float>, faceNormal: SIMD3<Float>) -> Float? {
        guard project(faceCentroid) != nil else { return nil }
        let camPos   = cameraTransform.columns.3.xyz
        let toCam    = normalize(camPos - faceCentroid)
        let dotScore = dot(faceNormal, toCam)
        guard dotScore > 0.1 else { return nil }
        return dotScore
    }

    private static func extractImage(_ buffer: CVPixelBuffer, scale: CGFloat) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        let scaleFilter = CIFilter(name: "CILanczosScaleTransform")!
        scaleFilter.setValue(ci, forKey: kCIInputImageKey)
        scaleFilter.setValue(scale, forKey: kCIInputScaleKey)
        scaleFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let output = scaleFilter.outputImage,
              let cg     = ciContext.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - TextureAtlas

struct TextureAtlas {
    let jpegData:  Data
    let cols:      Int
    let rows:      Int
    let frameSize: CGSize

    func atlasUV(frameIndex: Int, rawUV: SIMD2<Float>) -> SIMD2<Float> {
        let col = frameIndex % cols
        let row = frameIndex / cols
        let au  = (Float(col) + rawUV.x) / Float(cols)
        let av  = (Float(row) + rawUV.y) / Float(rows)
        return SIMD2<Float>(au, av)
    }

    static func build(from frames: [CapturedFrame]) -> TextureAtlas? {
        guard !frames.isEmpty else { return nil }
        let n    = frames.count
        let cols = max(1, Int(ceil(sqrt(Double(n)))))
        let rows = max(1, Int(ceil(Double(n) / Double(cols))))
        guard let firstImg = UIImage(data: frames[0].jpegData) else { return nil }
        let fw = firstImg.size.width, fh = firstImg.size.height
        let atlasSize = CGSize(width: CGFloat(cols) * fw, height: CGFloat(rows) * fh)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: Int(atlasSize.width),
            height: Int(atlasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        for (i, frame) in frames.enumerated() {
            guard let uiImage = UIImage(data: frame.jpegData),
                  let cgImage = uiImage.cgImage else { continue }
            let col = i % cols
            let row = i / cols
            let rect = CGRect(x: CGFloat(col) * fw, y: CGFloat(row) * fh, width: fw, height: fh)
            ctx.draw(cgImage, in: rect)
        }

        guard let cgImage = ctx.makeImage(),
              let jpegData = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.92) else {
            return nil
        }

        return TextureAtlas(jpegData: jpegData, cols: cols, rows: rows,
                            frameSize: CGSize(width: fw, height: fh))
    }
}