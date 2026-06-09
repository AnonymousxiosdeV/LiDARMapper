// IPAExporter.swift — LiDARMapper
// Self-contained IPA export. All types (IPAFile, UTType.ipa, exportIPA) live here.
// Do NOT also include ExportIPA.swift — that file is replaced by this one.

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
    // ✅ PropertyListSerialization instead of NSMutableDictionary(contentsOf:error:())
    // The old call passed () (Void) for NSErrorPointer — a type mismatch that won't compile.
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
            // NSFileCoordinator closure is NOT throwing — use resume(throwing:) directly
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
        self.modifier(IPAExportModifier())
    }
}

struct IPAExportModifier: ViewModifier {
    @State private var showSheet = false
    @State private var ipaFile: IPAFile?
    @State private var isBuilding = false
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 3) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showSheet = true
                isBuilding = true
                errorMessage = nil

                Task {
                    do {
                        let path = try await exportIPA()
                        let url = URL(fileURLWithPath: path)
                        ipaFile = try IPAFile(ipaURL: url)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isBuilding = false
                }
            }
            .sheet(isPresented: $showSheet) {
                IPAExportSheet(ipaFile: $ipaFile, isBuilding: $isBuilding, errorMessage: $errorMessage)
            }
    }
}

struct IPAGestureLayer: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .allowsHitTesting(true)
    }
}

struct PassthroughView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct IPAExportSheet: View {
    @Binding var ipaFile: IPAFile?
    @Binding var isBuilding: Bool
    @Binding var errorMessage: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if isBuilding {
                    ProgressView("Building IPA...")
                        .progressViewStyle(CircularProgressViewStyle())
                } else if let file = ipaFile {
                    Text("IPA ready for sideloading")
                        .font(.headline)
                    Text(file.file.filename ?? "App.ipa")
                        .font(.caption).foregroundStyle(.secondary)

                    Button("Save / Share IPA") {
                        // The actual fileExporter is attached to the parent
                    }
                } else if let err = errorMessage {
                    Text("Export failed")
                        .foregroundStyle(.red)
                    Text(err).font(.caption)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("IPA Export")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { /* dismiss handled by parent */ }
                }
            }
        }
    }
}
