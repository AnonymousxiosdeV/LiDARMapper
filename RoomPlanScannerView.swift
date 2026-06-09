// RoomPlanScannerView.swift — LiDARMapper
// RoomCaptureView starts camera preview on appear but does NOT start
// scanning until the user taps Start.

import SwiftUI
import RoomPlan

// MARK: - Room Scan Phase

enum RoomScanPhase {
    case idle
    case scanning
    case processing
    case done(CapturedRoom)
    case failed(String)
    case exported(URL)
}

// MARK: - RoomScanViewModel

@MainActor
final class RoomScanViewModel: ObservableObject {

    @Published var phase:         RoomScanPhase = .idle
    @Published var wallCount:     Int = 0
    @Published var doorCount:     Int = 0
    @Published var windowCount:   Int = 0
    @Published var objectCount:   Int = 0
    @Published var exportURL:     URL?
    @Published var showShareSheet = false

    private let log = AppLogger.shared
    lazy var delegate: RoomPlanDelegate = RoomPlanDelegate(viewModel: self)

    func didPresent(_ room: CapturedRoom) {
        wallCount = room.walls.count; doorCount = room.doors.count
        windowCount = room.windows.count; objectCount = room.objects.count
        log.log("Room processed: \(wallCount)w \(doorCount)d \(windowCount)win \(objectCount)obj")
        phase = .done(room)
    }

    func didFail(_ error: Error) {
        phase = .failed(error.localizedDescription)
        log.error("Room error: \(error)")
    }

    func exportRoom(_ room: CapturedRoom) {
        phase = .processing
        Task {
            do {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let dir  = docs.appendingPathComponent("LiDARMapper/exports", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let iso  = ISO8601DateFormatter()
                iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
                let stamp = iso.string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let url   = dir.appendingPathComponent("room_\(stamp).usdz")
                try room.export(to: url, exportOptions: .mesh)
                log.log("Room exported: \(url.lastPathComponent)")
                exportURL = url; showShareSheet = true
                phase = .exported(url)
            } catch {
                log.error("Export failed: \(error)")
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - RoomPlanDelegate

final class RoomPlanDelegate: NSObject, NSCoding, RoomCaptureViewDelegate {

    weak var viewModel: RoomScanViewModel?

    init(viewModel: RoomScanViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    func encode(with coder: NSCoder) {}
    required init?(coder: NSCoder) { return nil }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData,
                     error: Error?) -> Bool {
        if let e = error {
            Task { @MainActor [weak self] in self?.viewModel?.didFail(e) }
            return false
        }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let e = error {
            Task { @MainActor [weak self] in self?.viewModel?.didFail(e) }
            return
        }
        Task { @MainActor [weak self] in self?.viewModel?.didPresent(processedResult) }
    }
}

// MARK: - RoomCaptureContainer
// Wraps RoomCaptureView in UIViewController so it has a proper view hierarchy.
// Camera preview starts in viewDidAppear. Scanning starts only on startScan().

final class RoomCaptureContainer: UIViewController {

    private(set) var roomView: RoomCaptureView?
    var roomDelegate: RoomPlanDelegate?
    private var isScanning = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let rv = RoomCaptureView(frame: view.bounds)
        rv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(rv)
        roomView = rv
        if let d = roomDelegate { rv.delegate = d }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Start camera-only preview — NOT a full scan
        // Pass a config but immediately stop scanning while keeping camera alive.
        // RoomCaptureSession has no "preview-only" mode so we run briefly then
        // pause the scanning portion by stopping immediately after camera starts.
        roomView?.captureSession.run(configuration: RoomCaptureSession.Configuration())
        // Stop the scan data collection while keeping camera feed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            // ✅ self! → safe optional check; VC may be gone if user navigates away quickly
            if self?.isScanning == false {
                self?.roomView?.captureSession.stop()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        roomView?.captureSession.stop()
    }

    func startScan() {
        isScanning = true
        roomView?.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    func stopScan() {
        isScanning = false
        roomView?.captureSession.stop()
    }
}

// MARK: - RoomCaptureContainerRepresentable

struct RoomCaptureContainerRepresentable: UIViewControllerRepresentable {

    let viewModel: RoomScanViewModel
    let onContainer: (RoomCaptureContainer) -> Void

    func makeUIViewController(context: Context) -> RoomCaptureContainer {
        let vc = RoomCaptureContainer()
        vc.roomDelegate = viewModel.delegate
        DispatchQueue.main.async { onContainer(vc) }
        return vc
    }

    func updateUIViewController(_ vc: RoomCaptureContainer, context: Context) {}
}

// MARK: - RoomPlanScannerView

struct RoomPlanScannerView: View {

    @Binding var appMode: AppMode
    @StateObject private var viewModel   = RoomScanViewModel()
    @State private var container: RoomCaptureContainer?
    @State private var showExportOptions = false

    private var isSupported: Bool { RoomCaptureSession.isSupported }

    private var isScanning: Bool {
        if case .scanning   = viewModel.phase { return true }; return false
    }
    private var isProcessing: Bool {
        if case .processing = viewModel.phase { return true }; return false
    }
    private var isDone: Bool {
        if case .done = viewModel.phase { return true }; return false
    }
    private var capturedRoom: CapturedRoom? {
        if case .done(let r) = viewModel.phase { return r }; return nil
    }
    private var errorMsg: String? {
        if case .failed(let m) = viewModel.phase { return m }; return nil
    }

    var body: some View {
        ZStack {
            if isSupported {
                RoomCaptureContainerRepresentable(
                    viewModel: viewModel,
                    onContainer: { container = $0 }
                )
                .ignoresSafeArea()
                .onAppear  { UIApplication.shared.isIdleTimerDisabled = true }
                .onDisappear {
                    container?.stopScan()
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            } else {
                Color.black.ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48)).foregroundStyle(.orange)
                    Text("RoomPlan Not Supported")
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    Text("Requires iPhone 12 Pro or later with LiDAR.")
                        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.5))
                }
            }

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Button {
                        container?.stopScan()
                        appMode = .landing
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .padding(10).background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    if isDone        { RoomStatsHUD(viewModel: viewModel) }
                    else if isScanning { ScanningIndicator() }
                }
                .padding(.horizontal, 14).padding(.top, 10)

                Spacer()

                if isProcessing { ProcessingOverlay() }

                if let err = errorMsg {
                    Text(err).font(.system(size: 13, weight: .semibold)).foregroundStyle(.red)
                        .multilineTextAlignment(.center).padding(.horizontal, 20).padding(.bottom, 8)
                }

                RoomStatusBanner(phase: viewModel.phase).padding(.bottom, 8)

                HStack(spacing: 10) {
                    ScanButton(
                        label:    isScanning ? "■ Stop" : "▶ Start",
                        color:    isScanning ? .red : .indigo,
                        disabled: !isSupported || isProcessing
                    ) {
                        if isScanning {
                            viewModel.phase = .processing
                            container?.stopScan()
                        } else {
                            viewModel.phase = .scanning
                            container?.startScan()
                        }
                    }

                    ScanButton(label: "⬆ Export", color: .blue,
                               disabled: !isDone || isProcessing) {
                        showExportOptions = true
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .confirmationDialog("Export Room Scan", isPresented: $showExportOptions,
                            titleVisibility: .visible) {
            Button("USDZ — Mesh (QuickLook / Reality Composer)") {
                if let room = capturedRoom { viewModel.exportRoom(room) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Opens in QuickLook with full 3D and AR preview.") }
        .sheet(isPresented: $viewModel.showShareSheet) {
            if let url = viewModel.exportURL {
                ExportResultSheet(url: url, isPresented: $viewModel.showShareSheet,
                    onViewInLibrary: {
                        viewModel.showShareSheet = false
                        appMode = .library
                    }
                ).ignoresSafeArea()
            }
        }
    }
}

// MARK: - Supporting Views

struct RoomStatsHUD: View {
    @ObservedObject var viewModel: RoomScanViewModel
    var body: some View {
        HStack(spacing: 14) {
            roomStat("Walls",   value: viewModel.wallCount,   icon: "square.split.2x1")
            roomStat("Doors",   value: viewModel.doorCount,   icon: "door.left.hand.open")
            roomStat("Windows", value: viewModel.windowCount, icon: "window.casement")
            roomStat("Objects", value: viewModel.objectCount, icon: "sofa")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    private func roomStat(_ label: String, value: Int, icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.indigo)
            Text("\(value)").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            Text(label).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
        }
    }
}

struct ScanningIndicator: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.indigo).frame(width: 10, height: 10)
                .scaleEffect(pulse ? 1.4 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                           value: pulse)
            Text("Scanning Room")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .onAppear { pulse = true }
    }
}

struct ProcessingOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.indigo).scaleEffect(1.3)
            Text("Processing room…")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.bottom, 12)
    }
}

struct RoomStatusBanner: View {
    let phase: RoomScanPhase
    private var text: String {
        switch phase {
        case .idle:              return "Tap ▶ Start — walk slowly around the room"
        case .scanning:          return "Walk around covering all walls and surfaces"
        case .processing:        return "Building room model…"
        case .done:              return "Scan complete — tap ⬆ Export to save"
        case .exported(let url): return "Exported: \(url.lastPathComponent)"
        case .failed(let m):     return m
        }
    }
    private var color: Color {
        switch phase {
        case .scanning:   return .indigo
        case .processing: return .cyan
        case .done:       return .green
        case .exported:   return .cyan
        case .failed:     return .red
        default:          return .white.opacity(0.6)
        }
    }
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color).multilineTextAlignment(.center).padding(.horizontal, 16)
    }
}
