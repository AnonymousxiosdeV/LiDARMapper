// MeshViewerView.swift — LiDARMapper

import SwiftUI
import SceneKit

// MARK: - ViewMode

enum ViewMode: Int, CaseIterable {
    case textured = 0, solid = 1, wireframe = 2
    var label: String {
        switch self { case .textured: return "Textured"; case .solid: return "Solid"; case .wireframe: return "Wireframe" }
    }
    var icon: String {
        switch self { case .textured: return "photo.fill"; case .solid: return "cube.fill"; case .wireframe: return "cube" }
    }
}

// MARK: - MeshViewerView

struct MeshViewerView: View {
    let scanURL:  URL
    let scanName: String
    @Environment(\.dismiss) private var dismiss
    @State private var viewMode        = ViewMode.textured
    @State private var showEnhance     = false
    @State private var enhancing       = false
    @State private var enhanceProgress = 0.0
    @State private var enhanceMsg      = ""
    @State private var reloadToken     = 0

    var body: some View {
        ZStack {
            MeshHostRepresentable(scanURL: scanURL, viewMode: viewMode, reloadToken: reloadToken)
                .ignoresSafeArea()

            if enhancing {
                Color.black.opacity(0.75).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("Enhancing…").font(.headline).foregroundStyle(.white)
                    ProgressView(value: enhanceProgress).tint(.green).frame(width: 240)
                    Text("\(Int(enhanceProgress * 100))%")
                        .font(.system(size: 26, weight: .bold, design: .monospaced)).foregroundStyle(.green)
                    Text(enhanceMsg).font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                .padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .padding(10).background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                Text(scanName).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                Spacer()
                Menu {
                    Button { showEnhance = true } label: {
                        Label("Enhance Mesh…", systemImage: "wand.and.stars")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .padding(10).background(.ultraThinMaterial, in: Circle())
                }.disabled(enhancing)
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .overlay(alignment: .bottom) {
            if !enhancing {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(ViewMode.allCases, id: \.rawValue) { mode in
                            Button { viewMode = mode } label: {
                                Label(mode.label, systemImage: mode.icon)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(viewMode == mode ? .black : .white)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(viewMode == mode ? Color.cyan : Color.white.opacity(0.15),
                                                in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .padding(5).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    Text("Drag to rotate  •  Pinch to zoom  •  Double-tap to reset")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                }
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark).statusBarHidden(true)
        .confirmationDialog("Enhance Scan", isPresented: $showEnhance, titleVisibility: .visible) {
            Button("Quick Clean") {
                runEnhance(ProcessOptions(removeDegenerateFaces: true, weldThreshold: 0.001,
                                          removeLooseGeometry: true, removeSmallComponents: true,
                                          minComponentFaces: 50, recomputeNormals: true,
                                          enhanceTexture: true, textureTargetPx: 2048, textureSharpness: 0.6))
            }
            Button("Full Enhancement") {
                runEnhance(ProcessOptions(removeDegenerateFaces: true, weldThreshold: 0.002,
                                          removeLooseGeometry: true, removeSmallComponents: true,
                                          minComponentFaces: 100, smoothingIterations: 3,
                                          smoothingLambda: 0.5, smoothingMu: -0.53,
                                          recomputeNormals: true, enhanceTexture: true,
                                          textureTargetPx: 4096, textureSharpness: 0.75))
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Modifies the file in-place and reloads when complete.") }
    }

    private func runEnhance(_ opts: ProcessOptions) {
        enhancing = true; enhanceProgress = 0; enhanceMsg = "Starting…"
        let url = scanURL
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try MeshProcessor().process(objURL: url, options: opts) { p, msg in
                    DispatchQueue.main.async { enhanceProgress = p; enhanceMsg = msg }
                }
                DispatchQueue.main.async { enhancing = false; reloadToken += 1 }
            } catch { DispatchQueue.main.async { enhancing = false } }
        }
    }
}

// MARK: - MeshHostRepresentable

struct MeshHostRepresentable: UIViewControllerRepresentable {
    let scanURL:     URL
    let viewMode:    ViewMode
    let reloadToken: Int

    func makeUIViewController(context: Context) -> MeshHostVC {
        let vc = MeshHostVC()
        vc.pendingURL = scanURL
        return vc
    }

    func updateUIViewController(_ vc: MeshHostVC, context: Context) {
        // Only call loadFile if the view has already loaded (pendingURL handles the first load)
        if vc.isViewLoaded && (vc.loadedURL != scanURL || vc.loadedToken != reloadToken) {
            vc.loadedURL   = scanURL
            vc.loadedToken = reloadToken
            vc.loadFile(url: scanURL)
        }
        vc.apply(mode: viewMode)
    }
}

// MARK: - MeshHostVC

final class MeshHostVC: UIViewController {

    // Set by MeshHostRepresentable before viewDidLoad fires
    var pendingURL:   URL?
    var loadedURL:    URL?
    var loadedToken:  Int = -1

    private var scnView:  SCNView!
    private var pivot:    SCNNode!
    private var camNode:  SCNNode!
    private var spinner:  UIActivityIndicatorView!
    private var statusLbl: UILabel!

    private var meshNode:    SCNNode?
    private var tex:         UIImage?
    private var hasUVs       = false
    private var isCloud      = false
    private var curMode      = ViewMode.textured
    private var initCamXform = SCNMatrix4Identity
    private var loading      = false

    // MARK: - Lifecycle

    override func loadView() {
        let sv = SCNView()
        sv.backgroundColor            = UIColor(white: 0.08, alpha: 1)
        sv.antialiasingMode           = .multisampling2X
        sv.autoenablesDefaultLighting = true
        sv.allowsCameraControl        = true
        sv.defaultCameraController.interactionMode = .orbitTurntable
        sv.defaultCameraController.inertiaEnabled  = true
        sv.rendersContinuously        = true
        scnView = sv
        view    = sv
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildScene()
        buildStatusUI()
        // Load the pending file — this is the primary load path
        if let url = pendingURL {
            loadedURL   = url
            loadedToken = 0
            loadFile(url: url)
        }
    }

    // MARK: - Scene

    private func buildScene() {
        let scene = SCNScene()
        scnView.scene = scene

        camNode = SCNNode()
        let cam = SCNCamera()
        cam.fieldOfView = 60; cam.zNear = 0.001; cam.zFar = 2000
        camNode.camera   = cam
        camNode.position = SCNVector3(0, 0, 5)
        scene.rootNode.addChildNode(camNode)
        scnView.pointOfView = camNode
        initCamXform = camNode.transform

        pivot = SCNNode()
        scene.rootNode.addChildNode(pivot)

        let dtap = UITapGestureRecognizer(target: self, action: #selector(resetCam))
        dtap.numberOfTapsRequired = 2
        scnView.addGestureRecognizer(dtap)
    }

    // MARK: - Status UI

    private func buildStatusUI() {
        spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .cyan
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        spinner.startAnimating()

        statusLbl = UILabel()
        statusLbl.text          = "Loading…"
        statusLbl.textColor     = .white
        statusLbl.font          = .systemFont(ofSize: 14, weight: .medium)
        statusLbl.textAlignment = .center
        statusLbl.numberOfLines = 0
        statusLbl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLbl)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            statusLbl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLbl.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            statusLbl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLbl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async {
            self.statusLbl?.text      = s
            self.statusLbl?.textColor = .white
            self.statusLbl?.isHidden  = false
            self.spinner?.isHidden    = false
        }
    }
    private func clearStatus() {
        DispatchQueue.main.async {
            self.spinner?.stopAnimating(); self.spinner?.isHidden    = true
            self.statusLbl?.isHidden = true
        }
    }
    private func showErr(_ s: String) {
        DispatchQueue.main.async {
            self.loading = false
            self.spinner?.stopAnimating(); self.spinner?.isHidden    = true
            self.statusLbl?.text      = "⚠️ \(s)"
            self.statusLbl?.textColor = .systemOrange
            self.statusLbl?.isHidden  = false
        }
    }

    // MARK: - Load

    func loadFile(url: URL) {
        guard !loading else { return }
        loading = true
        meshNode?.removeFromParentNode(); meshNode = nil
        setStatus("Loading…")
        let ext = url.pathExtension.lowercased()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if ext == "ply" { self.loadPLY(url: url) }
            else             { self.loadOBJ(url: url) }
        }
    }

    // MARK: OBJ

    private func loadOBJ(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            showErr("File not found"); return
        }
        setStatus("Reading…")
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            showErr("Cannot read file"); return
        }
        setStatus("Parsing…")
        let parsed = Self.parseOBJ(text: text)
        guard parsed.vCount > 0, parsed.fCount > 0 else {
            showErr("No geometry — \(parsed.vCount) verts, \(parsed.fCount) faces"); return
        }
        setStatus("Building mesh…")
        let texture = Self.findTexture(objURL: url)
        guard let node = Self.makeMeshNode(parsed: parsed, texture: texture) else {
            showErr("Could not build geometry"); return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.loading  = false
            self.tex      = texture
            self.hasUVs   = parsed.hasUVs
            self.isCloud  = false
            self.addAndFrame(node)
            self.apply(mode: self.curMode)
            self.clearStatus()
        }
    }

    // MARK: PLY

    private func loadPLY(url: URL) {
        setStatus("Reading point cloud…")
        guard let data = try? Data(contentsOf: url) else { showErr("Cannot read PLY"); return }
        setStatus("Parsing…")
        guard let (pos, col) = Self.parsePLY(data: data), !pos.isEmpty else {
            showErr("Invalid PLY"); return
        }
        guard let node = Self.makeCloudNode(pos: pos, col: col) else {
            showErr("Could not build point cloud"); return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.loading = false
            self.tex     = nil; self.hasUVs = false; self.isCloud = true
            self.addAndFrame(node)
            self.apply(mode: self.curMode)
            self.clearStatus()
        }
    }

    // MARK: Add + Frame

    private func addAndFrame(_ node: SCNNode) {
        meshNode = node
        pivot.addChildNode(node)

        // SCNNode.boundingBox is instant — no main-thread blocking loop
        let (mn, mx) = node.boundingBox
        let cx = (mn.x + mx.x) / 2
        let cy = (mn.y + mx.y) / 2
        let cz = (mn.z + mx.z) / 2
        let maxDim = max(mx.x - mn.x, mx.y - mn.y, mx.z - mn.z)

        node.position  = SCNVector3(-cx, -cy, -cz)
        pivot.position = SCNVector3(0, 0, 0)

        let dist = maxDim > 0.001 ? Float(maxDim) * 2.2 + 0.5 : 5
        camNode.position    = SCNVector3(0, dist * 0.2, dist)
        camNode.eulerAngles = SCNVector3(-0.15, 0, 0)
        initCamXform        = camNode.transform
    }

    @objc private func resetCam() {
        scnView.defaultCameraController.stopInertia()
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.4
        camNode.transform   = initCamXform
        pivot.eulerAngles   = SCNVector3(0, 0, 0)
        pivot.position      = SCNVector3(0, 0, 0)
        SCNTransaction.commit()
    }

    // MARK: View Mode

    func apply(mode: ViewMode) {
        curMode = mode
        guard let node = meshNode, let geo = node.geometry else { return }
        let mat = SCNMaterial(); mat.isDoubleSided = true
        if isCloud {
            mat.lightingModel    = .constant
            mat.diffuse.contents = mode == .textured ? UIColor.white
                : UIColor(red: 0.5, green: 0.75, blue: 1, alpha: 1)
        } else {
            switch mode {
            case .textured:
                mat.lightingModel     = .lambert
                if let t = tex, hasUVs {
                    mat.diffuse.contents = t
                    mat.diffuse.wrapS    = .repeat; mat.diffuse.wrapT = .repeat
                } else {
                    mat.diffuse.contents = UIColor(red: 0.6, green: 0.75, blue: 0.85, alpha: 1)
                }
            case .solid:
                mat.lightingModel    = .blinn
                mat.diffuse.contents = UIColor(red: 0.78, green: 0.82, blue: 0.86, alpha: 1)
            case .wireframe:
                mat.lightingModel    = .constant
                mat.diffuse.contents = UIColor(red: 0.2, green: 0.85, blue: 0.95, alpha: 1)
                mat.fillMode         = .lines
            }
        }
        geo.materials = [mat]
    }

    // MARK: - OBJ Parser

    struct OBJData {
        var positions: [Float]; var uvs: [Float]; var indices: [Int32]
        var hasUVs: Bool
        var vCount: Int { positions.count / 3 }
        var fCount: Int { indices.count / 3 }
    }

    static func parseOBJ(text: String) -> OBJData {
        var rawPos = [(Float, Float, Float)]()
        var rawUV  = [(Float, Float)]()
        var expPos = [Float](), expUV = [Float](), idx = [Int32]()

        struct VK: Hashable { let vi, ti: Int32 }
        var vmap = [VK: Int32]()

        func res(_ r: Int, _ n: Int) -> Int { r < 0 ? n + r : r - 1 }
        func exp(_ vi: Int, _ ti: Int) -> Int32 {
            let k = VK(vi: Int32(vi), ti: Int32(ti))
            if let e = vmap[k] { return e }
            let i = Int32(expPos.count / 3)
            let (x, y, z) = vi >= 0 && vi < rawPos.count ? rawPos[vi] : (0, 0, 0)
            expPos += [x, y, z]
            let (u, v) = ti >= 0 && ti < rawUV.count ? rawUV[ti] : (0, 0)
            expUV += [u, v]
            vmap[k] = i; return i
        }
        func tok(_ t: Substring) -> (Int, Int) {
            let c = t.split(separator: "/", omittingEmptySubsequences: false)
            return (res(Int(c[0]) ?? 1, rawPos.count),
                    c.count > 1 && !c[1].isEmpty ? res(Int(c[1]) ?? 1, rawUV.count) : -1)
        }

        for raw in text.components(separatedBy: "\n") {
            let ln = raw.trimmingCharacters(in: .whitespaces)
            guard !ln.isEmpty, !ln.hasPrefix("#") else { continue }
            let p = ln.split(separator: " ", omittingEmptySubsequences: true)
            guard !p.isEmpty else { continue }
            switch p[0] {
            case "v" where p.count >= 4:
                rawPos.append((Float(p[1]) ?? 0, Float(p[2]) ?? 0, Float(p[3]) ?? 0))
            case "vt" where p.count >= 3:
                rawUV.append((Float(p[1]) ?? 0, 1 - (Float(p[2]) ?? 0)))
            case "f" where p.count >= 4:
                let (av, at) = tok(p[1]); let a = exp(av, at)
                for i in 2 ..< (p.count - 1) {
                    let (bv, bt) = tok(p[i]); let (cv, ct) = tok(p[i + 1])
                    idx += [a, exp(bv, bt), exp(cv, ct)]
                }
            default: break
            }
        }

        let mx = Int32(expPos.count / 3) - 1
        var safe = [Int32](); var i = 0
        while i + 2 < idx.count {
            let (a, b, c) = (idx[i], idx[i+1], idx[i+2])
            if a >= 0 && a <= mx && b >= 0 && b <= mx && c >= 0 && c <= mx {
                safe += [a, b, c]
            }
            i += 3
        }
        return OBJData(positions: expPos, uvs: expUV, indices: safe, hasUVs: !rawUV.isEmpty)
    }

    // MARK: - Texture

    static func findTexture(objURL: URL) -> UIImage? {
        let dir  = objURL.deletingLastPathComponent()
        let base = objURL.deletingPathExtension().lastPathComponent
        if let mtl = try? String(contentsOf: dir.appendingPathComponent(base + ".mtl"),
                                  encoding: .utf8) {
            for ln in mtl.components(separatedBy: "\n") {
                let pts = ln.trimmingCharacters(in: .whitespaces)
                           .split(separator: " ", omittingEmptySubsequences: true)
                guard pts.count >= 2, pts[0] == "map_Kd" else { continue }
                let fn = pts.dropFirst().joined(separator: " ")
                for u in [dir.appendingPathComponent(fn),
                           dir.appendingPathComponent((fn as NSString).lastPathComponent)] {
                    if let img = UIImage(contentsOfFile: u.path) { return img }
                }
            }
        }
        for sfx in ["_texture", "_face_texture", ""] {
            for ext in ["jpg", "jpeg", "png"] {
                let u = dir.appendingPathComponent(base + sfx + "." + ext)
                if let img = UIImage(contentsOfFile: u.path) { return img }
            }
        }
        return nil
    }

    // MARK: - Build Mesh Node

    static func makeMeshNode(parsed: OBJData, texture: UIImage?) -> SCNNode? {
        guard parsed.vCount > 0, parsed.fCount > 0 else { return nil }
        let n = parsed.vCount
        let posData = Data(bytes: parsed.positions, count: parsed.positions.count * 4)
        let posSrc  = SCNGeometrySource(data: posData, semantic: .vertex, vectorCount: n,
                                        usesFloatComponents: true, componentsPerVector: 3,
                                        bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        var srcs: [SCNGeometrySource] = [posSrc]
        if parsed.hasUVs, parsed.uvs.count == n * 2 {
            let uvData = Data(bytes: parsed.uvs, count: parsed.uvs.count * 4)
            srcs.append(SCNGeometrySource(data: uvData, semantic: .texcoord, vectorCount: n,
                                          usesFloatComponents: true, componentsPerVector: 2,
                                          bytesPerComponent: 4, dataOffset: 0, dataStride: 8))
        }
        let idxData = Data(bytes: parsed.indices, count: parsed.indices.count * 4)
        let el = SCNGeometryElement(data: idxData, primitiveType: .triangles,
                                    primitiveCount: parsed.fCount, bytesPerIndex: 4)
        let geo = SCNGeometry(sources: srcs, elements: [el])
        let mat = SCNMaterial(); mat.lightingModel = .lambert; mat.isDoubleSided = true
        mat.diffuse.contents = (texture != nil && parsed.hasUVs)
            ? texture! : UIColor(red: 0.6, green: 0.75, blue: 0.85, alpha: 1)
        if texture != nil && parsed.hasUVs { mat.diffuse.wrapS = .repeat; mat.diffuse.wrapT = .repeat }
        geo.materials = [mat]
        return SCNNode(geometry: geo)
    }

    // MARK: - PLY Parser

    static func parsePLY(data: Data) -> ([Float], [Float])? {
        var bodyStart: Int?
        for mk in ["end_header\r\n", "end_header\n"] {
            if let r = data.range(of: mk.data(using: .utf8)!) { bodyStart = r.upperBound; break }
        }
        guard let bs = bodyStart else { return nil }
        let hdr = String(data: data.subdata(in: 0..<bs), encoding: .utf8) ?? ""

        var vCount = 0, bpv = 0, hasColor = false, inV = false
        for raw in hdr.components(separatedBy: .newlines) {
            let pts = raw.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard !pts.isEmpty else { continue }
            if pts[0] == "element" {
                inV = pts.count >= 2 && pts[1] == "vertex"
                if inV, pts.count >= 3 { vCount = Int(pts[2]) ?? 0 }
            } else if pts[0] == "property" && inV && pts.count >= 3 {
                switch String(pts[1]) {
                case "float", "int", "uint": bpv += 4
                case "double":               bpv += 8
                case "uchar", "char":        bpv += 1
                case "ushort", "short":      bpv += 2
                default: break
                }
                if pts[2] == "red" { hasColor = true }
            }
        }
        guard vCount > 0, bpv >= 12 else { return nil }

        var pos = [Float](); pos.reserveCapacity(vCount * 3)
        var col = [Float](); col.reserveCapacity(vCount * 4)
        func rf(_ off: Int) -> Float {
            guard off + 4 <= data.count else { return 0 }
            var v: Float = 0
            withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: off ..< off + 4) }
            return v
        }
        for i in 0 ..< vCount {
            let b = bs + i * bpv; guard b + bpv <= data.count else { break }
            pos += [rf(b), rf(b + 4), rf(b + 8)]
            if hasColor && bpv >= 15 {
                col += [Float(data[b+12])/255, Float(data[b+13])/255,
                        Float(data[b+14])/255, 1]
            } else {
                col += [0.6, 0.75, 0.85, 1]
            }
        }
        return (pos, col)
    }

    // MARK: - Build Cloud Node

    static func makeCloudNode(pos: [Float], col: [Float]) -> SCNNode? {
        let n = pos.count / 3; guard n > 0 else { return nil }
        let pd = Data(bytes: pos, count: pos.count * 4)
        let ps = SCNGeometrySource(data: pd, semantic: .vertex, vectorCount: n,
                                   usesFloatComponents: true, componentsPerVector: 3,
                                   bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let cd = Data(bytes: col, count: col.count * 4)
        let cs = SCNGeometrySource(data: cd, semantic: .color, vectorCount: n,
                                   usesFloatComponents: true, componentsPerVector: 4,
                                   bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        var idx = (0 ..< Int32(n)).map { $0 }
        let id = Data(bytes: &idx, count: n * 4)
        let el = SCNGeometryElement(data: id, primitiveType: .point, primitiveCount: n, bytesPerIndex: 4)
        el.pointSize = 3; el.minimumPointScreenSpaceRadius = 1; el.maximumPointScreenSpaceRadius = 6
        let geo = SCNGeometry(sources: [ps, cs], elements: [el])
        let mat = SCNMaterial(); mat.lightingModel = .constant
        mat.diffuse.contents = UIColor.white; mat.isDoubleSided = true
        geo.materials = [mat]; return SCNNode(geometry: geo)
    }
}
