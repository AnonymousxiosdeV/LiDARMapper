// ExportView.swift — LiDARMapper
// NOTE: IPAFile, UTType.ipa, and exportIPA() all live in IPAExporter.swift.
// Do NOT add those definitions here — having them in both files causes
// "invalid redeclaration" errors.

import SwiftUI

struct ExportView: View {
    @State private var isExporting  = false
    @State private var ipaFile:     IPAFile?
    @State private var isBuilding   = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 30) {
                Image(systemName: "square.and.arrow.up.fill")
                    .font(.system(size: 60, weight: .ultraLight))
                    .foregroundStyle(.orange)

                Text("Export IPA")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text("Packages this app as an .ipa file\nfor sideloading onto your device.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)

                if let err = errorMessage {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                Button(action: export) {
                    HStack(spacing: 10) {
                        if isBuilding {
                            ProgressView().tint(.black).scaleEffect(0.85)
                        }
                        Text(isBuilding ? "Building…" : "Export IPA")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(isBuilding ? Color.orange.opacity(0.5) : Color.orange,
                                in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isBuilding)
                .padding(.horizontal, 40)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .fileExporter(
            isPresented: $isExporting,
            document:    ipaFile,
            contentType: .ipa
        ) { result in
            if case .failure(let e) = result {
                errorMessage = e.localizedDescription
            }
        }
    }

    private func export() {
        errorMessage = nil
        isBuilding   = true
        Task { @MainActor in
            do {
                let path    = try await exportIPA()
                let url     = URL(fileURLWithPath: path)
                ipaFile     = try IPAFile(ipaURL: url)
                isBuilding  = false
                isExporting = true
            } catch {
                isBuilding   = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
