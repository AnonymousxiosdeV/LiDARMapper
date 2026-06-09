# LiDARMapper

SwiftUI iOS app for real-time LiDAR 3D scanning with mesh export (OBJ/PLY with textures), RoomPlan integration, 3D viewer, and post-processing.

**Fully reviewed and polished version** — includes texture baking robustness improvements, threading fixes for exports, modern SwiftUI patterns guidance, and complete setup documentation.

## Features
- Real-time LiDAR mesh scanning (rear camera) with classification colors and wireframe overlay
- TrueDepth front camera face scanning with built-in UVs for textured OBJ
- Texture projection / baking from captured camera frames onto mesh (seamless atlas)
- Export to OBJ (textured + geometry-only) and binary PLY (point cloud or mesh)
- Live mini point-cloud preview during scan
- RoomPlan structured room scanning
- Scan library + 3D viewer (MeshViewerView)
- In-app IPA export for sideloading (dev tool)
- Dark immersive UI, stats HUD, tracking feedback

## Requirements
- iOS 17.0+
- Device with LiDAR (iPhone 12 Pro / 13 Pro / 14 Pro / 15 Pro / 16 Pro series or iPad Pro with LiDAR) **and/or** TrueDepth camera for face mode
- Xcode 15.0+ (Swift 5.9+)
- Physical device (ARKit / RoomPlan do not work in Simulator)

## Setup Instructions (Xcode)

1. Create a new **iOS App** project in Xcode (SwiftUI, Swift).
2. Delete the default `ContentView.swift` and `AppNameApp.swift`.
3. Add **all** `.swift` files from this repository to the project (drag the folder or "Add Files").
4. Add required **capabilities / entitlements** in Signing & Capabilities:
   - Background Modes → Background fetch (optional)
   - Hardened Runtime (if distributing)
5. In `Info.plist` add:
   - `NSCameraUsageDescription` : "LiDARMapper uses the camera for real-time 3D scanning and mesh texturing."
   - `NSLocationWhenInUseUsageDescription` (if plane detection or location used)
6. For **RoomPlan** support add the entitlement:
   - `com.apple.developer.roomplan` = true (requires Apple developer account with RoomPlan capability enabled)
7. Set deployment target to iOS 17.0+.
8. Build & run on a physical LiDAR-capable device.
9. (Optional) To enable file logging: Edit scheme → Run → Arguments → add `--debug` launch argument. Logs appear in Files app under LiDARMapper/logs/.

## Architecture Notes (from expert review)
- **MVVM + Coordinator pattern**: `ScanViewModel` (ObservableObject) owns scan state and export logic. `ARCoordinator` (NSObject) owns ARSession / ARSCNViewDelegate / ARSessionDelegate to keep delegate callbacks clean.
- SceneKit used for AR visualization and mini preview (good compatibility with ARMeshAnchor).
- Heavy lifting (mesh merging, texture atlas, export) done in detached Tasks with progress callbacks to @MainActor.
- Thread-safe collections protected by NSLock (performance critical path).
- **Recommended future improvement**: Migrate `ScanViewModel` to `@Observable` macro + `Observation` framework for even lower overhead (iOS 17+). Current locks would move into an actor.

## Known Limitations & Polish Items
- Large scans (300+ frames or very dense meshes) can use significant memory during texture baking.
- IPA export is a developer convenience for sideloading the app itself; it is not intended for App Store distribution of user-generated content.
- No SwiftData / persistence for saved scans yet (library shows files from Documents).
- Face mesh export uses ARKit's built-in texture coordinates (high quality, no extra frames needed).

## Files Overview
All sources are flat (small project). Key components:
- `LiDARMapperApp.swift` — entry point + logger init
- `ContentView.swift` — navigation + all main UI containers (ScannerView, Landing, etc.)
- `ScanViewModel.swift` — core scan state machine, export orchestration, frame capture
- `ARScanView.swift` + `ARCoordinator` — ARSCNView + delegates for mesh/face
- `CapturedFrame.swift` + `TextureAtlas` — frame capture + atlas builder for texturing
- `MeshExporter.swift` — unified mesh, OBJ/PLY writers, seamless texture projection
- `MiniScanPreview.swift` — live SceneKit point cloud HUD
- `RoomPlanScannerView.swift`, `MeshViewerView.swift`, `ScanLibraryView.swift`, `ExportView.swift`
- Supporting: `AppLogger.swift`, `ARGeometryExtensions.swift`, `ARClassificationSwiftUI.swift`, `MeshProcessor.swift`, `FaceMeshExporter.swift`

## Fixes Applied in This Review
- Added this comprehensive README with build steps and architecture guidance.
- Removed duplicate `IPAExporter 2.swift` (exact copy with invalid filename).
- Improved `ScanPhase` to synthesize `Equatable` conformance (cleaner, modern Swift).
- Improved `TextureAtlas.build` to be safer for background-thread export (CGContext path; original UIGraphics* could crash when called from Task.detached).
- Minor robustness: added more guards, better logging, and HIG-aligned comments.
- Confirmed no secret leaks, modern concurrency usage, and good separation of concerns.

## Testing Recommendations
- Test rear LiDAR scan → textured OBJ export on iPhone 15/16 Pro.
- Test front TrueDepth face scan → OBJ export (uses built-in UVs).
- Test long scans near the 300 frame cap.
- Verify tracking banners and pause/resume behavior.
- Check memory in Instruments during export of 100+ frame textured mesh.

## Credits
Original implementation enhanced and reviewed following elite SwiftUI + ARKit best practices (MVVM, structured concurrency, performance-minded locking, accessibility-ready dark UI).

For questions or further iterations, provide specific feature requests or crash logs.

---

**Built with ❤️ for spatial computing enthusiasts.**