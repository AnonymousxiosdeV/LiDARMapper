// IPAExporter.swift — LiDARMapper
// Self-contained IPA export. All types (IPAFile, UTType.ipa, exportIPA) live here.
// Robust for Swift Playgrounds on iPad (handles bundle copy edge cases).

import SwiftUI
import UniformTypeIdentifiers

// MARK: - UTType

extension UTType {
    static let ipa = UTType(filenameExtension: "ipa")!
}

// MARK: - IPAFile
// @unchecked Sendable: FileWrapper is not Sendable but we only read it on the main actor.

struct IPAFile: FileDocument, @unchecked Sendable {
    let file: FileWrapper

    static var readableContentTypes: [UTType] { [.ipa] }
    static var writableContentTypes: [UTType] { [.ipa] }

    init(ipaURL: URL) throws {
        self.file = try FileWrapper(url: ipaURL, options: .immediate)
    }

    init(configuration: ReadConfiguration) throws {
        self.file = configuration.file
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return self.file
    }
}

// MARK: - exportIPA

/// Packages the running app bundle into a .ipa and returns the file path.
/// Returns String (not URL) — returning URL from async throws crashes in Nyxian/Playgrounds.
/// Improved error messages for Swift Playgrounds bundle layout differences.
func exportIPA() async throws -> String {
    let bundleURL = Bundle.main.bundleURL

    let tmpDir     = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let payloadDir = tmpDir.appendingPathComponent("Payload")
    try FileManager.default.createDirectory(at: payloadDir,
                                             withIntermediateDirectories: true)

    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let appName = Bundle.main.object(forInfoDictionaryKey: kCFBundleNameKey as String)
                    as? String ?? "App"
    let appURL  = payloadDir.appendingPathComponent("\(appName).app")
    let ipaURL  = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(appName).ipa")

    try FileManager.default.copyItem(at: bundleURL, to: appURL)

    // Strip "swift-playgrounds-" — Apple forbids it in registered App IDs
    let bundleID = Bundle.main.bundleIdentifier ?? "com.app"
    let updatedID = bundleID.replacingOccurrences(of: "swift-playgrounds-", with: "")

    let plistURL  = appURL.appendingPathComponent("Info.plist")

    // Robust check for Playgrounds / custom bundle layouts
    guard FileManager.default.fileExists(atPath: plistURL.path) else {
        throw NSError(domain: "IPAExporter", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Info.plist not in directory after copying bundle. This can happen in Swift Playgrounds on iPad due to special bundle structure. Try running in a standard Xcode iOS app project instead."])
    }

    let plistData  = try Data(contentsOf: plistURL)
    guard let infoPlist = try PropertyListSerialization
            .propertyList(from: plistData, format: nil) as? NSMutableDictionary else {
        throw NSError(domain: "IPAExporter", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Info.plist is not a dictionary"])
    }
    infoPlist[kCFBundleIdentifierKey as String] = updatedID
    try infoPlist.write(to: plistURL)

    // forUploading zips the Payload/ directory automatically
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        let intent      = NSFileAccessIntent.readingIntent(with: payloadDir, options: .forUploading)
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(with: [intent], queue: .main) { coordError in
            if let coordError {
                cont.resume(throwing: coordError)
                return
            }
            do {
                _ = try FileManager.default.replaceItemAt(ipaURL, withItemAt: intent.url)
                cont.resume()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    return ipaURL.path
}

// MARK: - View Modifier (attach to any SwiftUI view)

extension View {
    /// Three-finger tap anywhere → IPA export sheet.
    func ipaExportOnTripleTap() -> some View {
        modifier(IPAExportModifier())
    }
}

private struct IPAExportModifier: ViewModifier {
    @State private var showSheet = false
    func body(content: Content) -> some View {
        content
            .overlay(IPAGestureLayer(showSheet: $showSheet).allowsHitTesting(true))
            .sheet(isPresented: $showSheet) {
                IPAExportSheet(isPresented: $showSheet).preferredColorScheme(.dark)
            }
    }
}

private struct IPAGestureLayer: UIViewRepresentable {
    @Binding var showSheet: Bool
    func makeCoordinator() -> Coord { Coord(showSheet: $showSheet) }
    func makeUIView(context: Context) -> UIView {
        let v   = PassthroughView()
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coord.fired))
        tap.numberOfTouchesRequired = 3
        tap.numberOfTapsRequired    = 1
        v.addGestureRecognizer(tap)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coord: NSObject {
        @Binding var showSheet: Bool
        init(showSheet: Binding<Bool>) { _showSheet = showSheet }
        @objc func fired() {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            DispatchQueue.main.async { self.showSheet = true }
        }
    }
}

private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self {
            let active = gestureRecognizers?.contains {
                $0.state == .possible || $0.state == .began || $0.state == .changed
            } ?? false
            return active ? self : nil
        }
        return hit
    }
}

private struct IPAExportSheet: View {
    @Binding var isPresented: Bool
    @State private var ipaFile:  IPAFile?
    @State private var building  = false
    @State private var exporting = false
    @State private var errMsg:   String?

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: building ? "gearshape.2" : "square.and.arrow.up.fill")
                    .font(.system(size: 50, weight: .ultraLight)).foregroundStyle(.orange)
                Text("Export IPA")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                if let e = errMsg {
                    Text(e).font(.caption).foregroundStyle(.red)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }
                VStack(spacing: 12) {
                    Button(action: go) {
                        HStack(spacing: 8) {
                            if building { ProgressView().tint(.black).scaleEffect(0.8) }
                            Text(building ? "Building…" : (ipaFile != nil ? "Save / Share" : "Build & Export"))
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(.black).frame(maxWidth: .infinity).frame(height: 50)
                        .background(building ? Color.orange.opacity(0.5) : Color.orange,
                                    in: RoundedRectangle(cornerRadius: 13))
                    }
                    .disabled(building)
                    Button("Dismiss") { isPresented = false }
                        .font(.system(size: 15)).foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 28)
            }
            .padding(.vertical, 40)
        }
        .fileExporter(isPresented: $exporting, document: ipaFile,
                      contentType: .ipa) { result in
            if case .failure(let e) = result { errMsg = e.localizedDescription }
            else { isPresented = false }
        }
    }

    private func go() {
        if ipaFile != nil { exporting = true; return }
        errMsg = nil; building = true
        Task { @MainActor in
            do {
                let path   = try await exportIPA()
                ipaFile    = try IPAFile(ipaURL: URL(fileURLWithPath: path))
                building   = false
                exporting  = true
            } catch {
                building = false; errMsg = error.localizedDescription
            }
        }
    }
}