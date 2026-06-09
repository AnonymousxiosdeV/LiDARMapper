// ContentView.swift — LiDARMapper

import SwiftUI
import ARKit

enum AppMode: Equatable {
    case landing
    case scanning
    case roomPlan
    case exportIPA
    case library
}

struct ContentView: View {
    @State private var mode: AppMode = .landing
    var body: some View {
        switch mode {
        case .landing:   LandingView(mode: $mode)
        case .scanning:  ScannerView(mode: $mode)
        case .roomPlan:  RoomPlanScannerView(appMode: $mode)
        case .exportIPA: ExportView()
        case .library:   ScanLibraryView(mode: $mode)
        }
    }
}

struct LandingView: View {
    @Binding var mode: AppMode
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 44) {
                VStack(spacing: 10) {
                    Image(systemName: "view.3d")
                        .font(.system(size: 64, weight: .ultraLight)).foregroundStyle(.cyan)
                    Text("LiDAR Mapper")
                        .font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
                    Text("iPhone 17 Pro Max")
                        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.4))
                }
                VStack(spacing: 14) {
                    LandingButton(icon: "sensor.tag.radiowaves.forward.fill",
                                  title: "Start Scanning", subtitle: "Real-time LiDAR 3D mapping",
                                  color: .cyan)   { mode = .scanning }
                    LandingButton(icon: "square.3.layers.3d",
                                  title: "My Scans", subtitle: "View and render saved meshes",
                                  color: .green)  { mode = .library }
                    LandingButton(icon: "floor.lamp",
                                  title: "Room Scan",
                                  subtitle: "Structured room model with RoomPlan",
                                  color: .indigo) { mode = .roomPlan }
                    LandingButton(icon: "square.and.arrow.up.fill",
                                  title: "Export IPA", subtitle: "Package app for sideloading",
                                  color: .orange) { mode = .exportIPA }
                }
                .padding(.horizontal, 28)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
    }
}

struct LandingButton: View {
    let icon: String; let title: String; let subtitle: String
    let color: Color; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(color).frame(width: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(color.opacity(0.25), lineWidth: 1))
        }
    }
}

struct ScannerView: View {

    @Binding var mode: AppMode
    @StateObject private var viewModel:   ScanViewModel
    @StateObject private var coordinator: ARCoordinator
    @State private var showExportSheet  = false
    @State private var showErrorAlert   = false

    init(mode: Binding<AppMode>) {
        _mode = mode
        let vm    = ScanViewModel()
        let coord = ARCoordinator(viewModel: vm)
        _viewModel   = StateObject(wrappedValue: vm)
        _coordinator = StateObject(wrappedValue: coord)
    }

    private var isErrorPhase: Bool {
        if case .failed = viewModel.phase { return true }; return false
    }
    private var errorMessage: String {
        if case .failed(let m) = viewModel.phase { return m }; return ""
    }
    private var exportProgress: Double {
        if case .exporting(let p) = viewModel.phase { return p }; return 0
    }
    private var isExportingPhase: Bool {
        if case .exporting = viewModel.phase { return true }; return false
    }
    private var isFrontMode: Bool { viewModel.cameraMode == .front }
    private var isScanning: Bool {
        if case .scanning = viewModel.phase { return true }; return false
    }

    var body: some View {
        ZStack {
            ARScanView(viewModel: viewModel, coordinator: coordinator)
                .ignoresSafeArea()
                .onAppear  { UIApplication.shared.isIdleTimerDisabled = true }
                .onDisappear {
                    coordinator.pauseSession()
                    UIApplication.shared.isIdleTimerDisabled = false
                }

            VStack(spacing: 0) {

                HStack(alignment: .top, spacing: 10) {
                    Button {
                        coordinator.pauseSession()
                        mode = .landing
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .padding(10).background(.ultraThinMaterial, in: Circle())
                    }

                    StatsHUD(viewModel: viewModel)
                    Spacer()

                    VStack(spacing: 8) {
                        LegendHUD()

                        Button {
                            coordinator.pauseSession()
                            viewModel.switchCamera()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                coordinator.startCameraOnly(mode: viewModel.cameraMode)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.2.circlepath.camera")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(isFrontMode ? "TrueDepth" : "LiDAR")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(isFrontMode ? .purple : .cyan)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(
                                isFrontMode ? Color.purple.opacity(0.5) : Color.cyan.opacity(0.5),
                                lineWidth: 1))
                        }
                        .disabled(isExportingPhase)
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)

                if !viewModel.trackingMsg.isEmpty {
                    TrackingBanner(message: viewModel.trackingMsg).padding(.top, 6)
                }

                if isFrontMode {
                    Text("Point front camera at your face • Stay still for best results")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.purple.opacity(0.9))
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 6)
                }

                Spacer()

                if isScanning && viewModel.cameraMode == .rear && viewModel.tileCount > 0 {
                    HStack {
                        Spacer()
                        MiniScanPreviewView(viewModel: viewModel)
                            .padding(.trailing, 14)
                    }
                    .padding(.bottom, 6)
                }

                if isExportingPhase {
                    ExportProgressView(progress: exportProgress)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }

                if isScanning && viewModel.cameraMode == .rear {
                    VStack(spacing: 4) {
                        HStack {
                            Text("Max Distance")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                            Spacer()
                            Text(String(format: "%.1f m", viewModel.maxScanDistance))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.cyan)
                        }
                        Slider(value: $viewModel.maxScanDistance, in: 1...10, step: 0.5)
                            .tint(.cyan)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 14).padding(.bottom, 8)
                }

                StatusBanner(phase: viewModel.phase,
                             trackingMsg: viewModel.trackingMsg,
                             cameraMode: viewModel.cameraMode)
                    .padding(.horizontal, 16).padding(.bottom, 6)

                ControlBar(viewModel: viewModel,
                           coordinator: coordinator,
                           showExportSheet: $showExportSheet)
                    .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onChange(of: isErrorPhase) { _, newValue in showErrorAlert = newValue }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { viewModel.phase = .idle }
        } message: { Text(errorMessage) }
        .confirmationDialog(
            isFrontMode ? "Export Face Scan" : "Export LiDAR Scan",
            isPresented: $showExportSheet,
            titleVisibility: .visible
        ) {
            if isFrontMode {
                Button("OBJ + Texture (\(viewModel.capturedFrameCount) frames)") {
                    viewModel.startExport(withTexture: true)
                }
                Button("OBJ — Geometry Only") {
                    viewModel.startExport(withTexture: false)
                }
            } else {
                Button("OBJ + Texture (\(viewModel.capturedFrameCount) frames)") {
                    viewModel.exportFormat = .obj
                    viewModel.startExport(withTexture: true)
                }
                Button("OBJ — No Texture") {
                    viewModel.exportFormat = .obj
                    viewModel.startExport(withTexture: false)
                }
                Button("PLY — Binary Point Cloud") {
                    viewModel.exportFormat = .ply
                    viewModel.startExport(withTexture: false)
                }
                Button("Photogrammetry Dataset (images + poses)") {
                    viewModel.startPhotogrammetryExport()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isFrontMode
                 ? "TrueDepth face mesh uses built-in ARKit UV coordinates."
                 : "OBJ + Texture projects frames onto mesh. Photogrammetry exports raw images + camera poses for external tools (RealityCapture) to generate OBJ. On-device ObjectCapture (RealityKit) available in future update for pure photo reconstruction.")
        }
        .sheet(isPresented: $viewModel.showShareSheet) {
            if let url = viewModel.exportURL {
                ExportResultSheet(url: url,
                                  isPresented: $viewModel.showShareSheet,
                                  onViewInLibrary: {
                    viewModel.showShareSheet = false
                    mode = .library
                }).ignoresSafeArea()
            }
        }
    }
}

struct ExportResultSheet: View {
    let url: URL
    @Binding var isPresented: Bool
    let onViewInLibrary: () -> Void
    @State private var showShareActivity = false

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56, weight: .ultraLight)).foregroundStyle(.green)
                VStack(spacing: 6) {
                    Text("Scan Exported")
                        .font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1).truncationMode(.middle)
                }
                VStack(spacing: 12) {
                    Button(action: onViewInLibrary) {
                        Label("View in My Scans", systemImage: "square.3.layers.3d")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(Color.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button(action: { showShareActivity = true }) {
                        Label("Share / AirDrop", systemImage: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(Color.blue.opacity(0.80), in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button("Dismiss") { isPresented = false }
                        .font(.system(size: 15)).foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 28)
            }
            .padding(.vertical, 44)
        }
        .sheet(isPresented: $showShareActivity) {
            ShareSheet(url: url).ignoresSafeArea()
        }
    }
}

struct ControlBar: View {
    @ObservedObject var viewModel: ScanViewModel
    let coordinator: ARCoordinator
    @Binding var showExportSheet: Bool

    private var isScanning: Bool {
        if case .scanning = viewModel.phase { return true }; return false
    }
    private var hasMesh: Bool {
        viewModel.cameraMode == .front
            ? !viewModel.faceSnapshots.isEmpty
            : viewModel.tileCount > 0
    }
    private var isExporting: Bool {
        if case .exporting = viewModel.phase { return true }; return false
    }

    var body: some View {
        HStack(spacing: 10) {
            ScanButton(
                label:    isScanning ? "● Scanning" : (viewModel.phase == .paused ? "▶ Resume" : "▶ Start"),
                color:    isScanning ? .red : .green,
                disabled: isScanning || isExporting
            ) {
                let reset = viewModel.phase == .idle
                if reset { viewModel.resetScan() }
                viewModel.phase = .scanning
                coordinator.startSession(reset: reset, mode: viewModel.cameraMode)
            }

            ScanButton(label: "⏸ Pause", color: .orange,
                       disabled: !isScanning || isExporting) {
                viewModel.phase = .paused
                coordinator.pauseSession()
            }

            ScanButton(label: "⬆ Export", color: .blue,
                       disabled: !hasMesh || isExporting) {
                showExportSheet = true
            }
        }
    }
}

struct StatsHUD: View {
    @ObservedObject var viewModel: ScanViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            statRow("Vtx",   value: viewModel.vertexCount.formatted())
            statRow("Faces", value: viewModel.faceCount.formatted())
            if viewModel.cameraMode == .rear {
                statRow("Tiles", value: "\(viewModel.tileCount)")
            }
            statRow("FPS",   value: String(format: "%.0f", viewModel.fps))
            statRow("Imgs",  value: "\(viewModel.capturedFrameCount)/\(ScanViewModel.maxFrames)")
        }
        .font(.system(size: 11.5, weight: .regular, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    private func statRow(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":").foregroundStyle(.white.opacity(0.6))
            Text(value)
        }
    }
}

private let legendItems: [(ARMeshClassification, String)] = [
    (.floor, "Floor"), (.wall, "Wall"), (.ceiling, "Ceiling"),
    (.table, "Table"), (.seat, "Chair"), (.window, "Window"),
    (.door, "Door"),   (.none, "Other"),
]

struct LegendHUD: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(legendItems, id: \.1) { cls, name in
                HStack(spacing: 6) {
                    Circle().fill(cls.swiftUIColor).frame(width: 8, height: 8)
                    Text(name).font(.system(size: 10.5)).foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TrackingBanner: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color.yellow, in: Capsule())
    }
}

struct StatusBanner: View {
    let phase: ScanPhase; let trackingMsg: String; let cameraMode: CameraMode
    private var text: String {
        switch phase {
        case .idle:
            return cameraMode == .front
                ? "TrueDepth ready — move slowly around the object for full coverage"
                : "Camera ready — move slowly for complete scan. Aim for overlapping views."
        case .scanning:
            return trackingMsg.isEmpty
                ? (cameraMode == .front ? "Scanning face — hold still, good lighting helps" : "Scanning — slow circular motion, keep 1-2m distance, overlap views 30%+")
                : trackingMsg
        case .paused:            return "Paused — tap ▶ Resume or ⬆ Export. Check preview for coverage gaps."
        case .exporting:         return "Processing mesh and texture…"
        case .exported(let url): return "Exported: \(url.lastPathComponent)"
        case .failed(let msg):   return msg
        }
    }
    private var color: Color {
        switch phase {
        case .scanning:             return cameraMode == .front ? .purple : .green
        case .paused:               return .yellow
        case .exporting, .exported: return .cyan
        case .failed:               return .red
        default:                    return .white.opacity(0.6)
        }
    }
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color).multilineTextAlignment(.center)
    }
}

struct ExportProgressView: View {
    let progress: Double
    var body: some View {
        VStack(spacing: 4) {
            Text("Processing… \(Int(progress * 100))%")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            ProgressView(value: progress).tint(.green)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ScanButton: View {
    let label: String; let color: Color; let disabled: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(disabled ? .white.opacity(0.3) : .white)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(disabled ? color.opacity(0.25) : color.opacity(0.80),
                            in: RoundedRectangle(cornerRadius: 12))
        }
        .disabled(disabled)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
