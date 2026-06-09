// ScanLibraryView.swift — LiDARMapper

import SwiftUI
import QuickLook

// MARK: - ScanFile

struct ScanFile: Identifiable {
    let id = UUID()
    let url: URL; let name: String; let date: Date
    let sizeBytes: Int64; let format: ScanFileFormat

    var formattedSize: String {
        let mb = Double(sizeBytes) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB", mb)
                       : String(format: "%.0f KB", Double(sizeBytes) / 1024)
    }
    var formattedDate: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
}

enum ScanFileFormat: Equatable {
    case obj; case usdz; case ply
    init(extension ext: String) {
        switch ext.lowercased() {
        case "obj":  self = .obj
        case "usdz": self = .usdz
        default:     self = .ply
        }
    }
    var canView: Bool { true }
    var label: String {
        switch self { case .obj: return "OBJ"; case .usdz: return "USDZ"; case .ply: return "PLY" }
    }
    var color: Color {
        switch self { case .obj: return .cyan; case .usdz: return .indigo; case .ply: return .orange }
    }
    var icon: String {
        switch self { case .obj: return "cube.fill"; case .usdz: return "arkit"; case .ply: return "doc.fill" }
    }
}

// MARK: - Destination enum — drives single NavigationLink / fullScreenCover

private enum LibraryDestination: Identifiable {
    case objViewer(ScanFile)
    case quickLook(URL)
    var id: String {
        switch self {
        case .objViewer(let s): return "obj-\(s.id)"
        case .quickLook(let u): return "ql-\(u.path)"
        }
    }
}

// MARK: - ScanLibraryView

struct ScanLibraryView: View {

    @Binding var mode: AppMode

    @State private var scans:          [ScanFile] = []
    @State private var isLoading                   = true
    @State private var destination:    LibraryDestination?
    @State private var scanToDelete:   ScanFile?
    @State private var showDeleteAlert             = false
    private let log = AppLogger.shared

    var body: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()
            VStack(spacing: 0) {

                // Header
                HStack {
                    Button(action: { mode = .landing }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .padding(10).background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    Text("Saved Scans")
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    Spacer()
                    Color.clear.frame(width: 40, height: 40)
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)

                if isLoading {
                    Spacer()
                    ProgressView().tint(.cyan).scaleEffect(1.3)
                    Text("Loading scans…").font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5)).padding(.top, 12)
                    Spacer()

                } else if scans.isEmpty {
                    Spacer()
                    VStack(spacing: 14) {
                        Image(systemName: "square.3.layers.3d.slash")
                            .font(.system(size: 52, weight: .ultraLight))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("No scans yet")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("Complete a scan and export to save it here.")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.3))
                            .multilineTextAlignment(.center)
                    }
                    Spacer()

                } else {
                    // Format legend
                    HStack(spacing: 10) {
                        ForEach([ScanFileFormat.obj, .usdz, .ply], id: \.label) { fmt in
                            let count = scans.filter { $0.format == fmt }.count
                            if count > 0 {
                                Label("\(count) \(fmt.label)", systemImage: fmt.icon)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(fmt.color)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(fmt.color.opacity(0.12), in: Capsule())
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.bottom, 10)

                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(scans) { scan in
                                ScanRowView(scan: scan,
                                    onOpen:   { openScan(scan) },
                                    onDelete: { scanToDelete = scan; showDeleteAlert = true })
                            }
                        }
                        .padding(.horizontal, 16).padding(.bottom, 24)
                    }
                }
            }
        }
        .statusBarHidden(true)
        .onAppear { loadScans() }
        .alert("Delete Scan", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let s = scanToDelete { deleteScan(s) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(""\(scanToDelete?.name ?? "")" will be permanently deleted.")
        }
        // Item-driven cover: SwiftUI reacts to the item value itself,
        // so the content closure always has the correct destination.
        .fullScreenCover(item: $destination) { dest in
            switch dest {
            case .objViewer(let scan):
                MeshViewerView(scanURL: scan.url, scanName: scan.name)
            case .quickLook(let url):
                QuickLookView(url: url).ignoresSafeArea()
            }
        }
    }

    // MARK: - Actions

    private func openScan(_ scan: ScanFile) {
        switch scan.format {
        case .obj:
            destination = .objViewer(scan)
        case .usdz:
            destination = .quickLook(scan.url)
        case .ply:
            destination = .objViewer(scan)
        }
    }

    private func loadScans() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir  = docs.appendingPathComponent("LiDARMapper/exports")
            var found = [ScanFile]()
            if let items = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: .skipsHiddenFiles) {
                for url in items where ["obj","ply","usdz"].contains(url.pathExtension.lowercased()) {
                    let attrs = try? url.resourceValues(
                        forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size  = Int64(attrs?.fileSize ?? 0)
                    let date  = attrs?.contentModificationDate ?? Date()
                    let name  = url.deletingPathExtension().lastPathComponent
                    let fmt   = ScanFileFormat(extension: url.pathExtension)
                    found.append(ScanFile(url: url, name: name, date: date,
                                         sizeBytes: size, format: fmt))
                }
            }
            found.sort { $0.date > $1.date }
            log.log("Library: \(found.count) scan(s)")
            DispatchQueue.main.async { scans = found; isLoading = false }
        }
    }

    private func deleteScan(_ scan: ScanFile) {
        try? FileManager.default.removeItem(at: scan.url)
        if scan.format == .obj {
            let base = scan.url.deletingPathExtension()
            let dir  = scan.url.deletingLastPathComponent()
            [base.appendingPathExtension("mtl"),
             dir.appendingPathComponent(base.lastPathComponent + "_texture.jpg"),
             dir.appendingPathComponent(base.lastPathComponent + "_face_texture.jpg")]
                .forEach { try? FileManager.default.removeItem(at: $0) }
        }
        scans.removeAll { $0.id == scan.id }
        log.log("Deleted: \(scan.name)")
    }
}

// MARK: - ScanRowView

struct ScanRowView: View {
    let scan: ScanFile; let onOpen: () -> Void; let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(scan.format.color.opacity(0.15)).frame(width: 52, height: 52)
                Image(systemName: scan.format.icon)
                    .font(.system(size: 22, weight: .light)).foregroundStyle(scan.format.color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(scan.name)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 6) {
                    Text(scan.format.label)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(scan.format.color)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(scan.format.color.opacity(0.15), in: Capsule())
                    Text(scan.formattedSize)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    Text("•").foregroundStyle(.white.opacity(0.25))
                    Text(scan.formattedDate)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
                if !scan.format.canView {
                    Text("Point Cloud — RGB coloured")
                        .font(.system(size: 10)).foregroundStyle(.orange.opacity(0.7))
                }
            }
            Spacer()
            VStack(spacing: 8) {
                if scan.format.canView {
                    Button(action: onOpen) {
                        Image(systemName: scan.format == .usdz ? "arkit" : "eye.fill")
                            .font(.system(size: 14)).foregroundStyle(scan.format.color)
                            .padding(8).background(scan.format.color.opacity(0.15),
                                                   in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13)).foregroundStyle(.red.opacity(0.7))
                        .padding(8).background(Color.red.opacity(0.10),
                                               in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - QuickLookView

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        let nav = UINavigationController(rootViewController: ql)
        nav.navigationBar.tintColor = .white
        nav.navigationBar.barStyle  = .black
        return nav
    }
    func updateUIViewController(_ nav: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL; init(url: URL) { self.url = url }
        func numberOfPreviewItems(in c: QLPreviewController) -> Int { 1 }
        func previewController(_ c: QLPreviewController,
                               previewItemAt i: Int) -> QLPreviewItem { url as NSURL }
    }
}
