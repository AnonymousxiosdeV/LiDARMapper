# LiDARMapper

SwiftUI iOS app for real-time LiDAR 3D scanning, mesh export (OBJ/PLY/USDZ with high-quality textures), RoomPlan integration, interactive 3D viewer, and post-processing tools.

## Features
- Real-time LiDAR mesh scanning (rear camera) and TrueDepth face scanning
- Export to OBJ (with seamless photographic textures), PLY (colored point cloud), USDZ
- RoomPlan structured room scans
- 3D viewer with textured/solid/wireframe modes + mesh enhancement
- Library for saved scans with quick preview and in-place processing
- IPA export for sideloading

## Fixes & Improvements Applied
- Corrected UV texture baking and display on saved OBJ scans (proper orientation, seamless projection from camera frames)
- Cleaner texture file naming and MTL handling
- Library deduplication (hides duplicate plain .obj when textured version exists)
- Improved delete logic for all companion files
- Memory-safe frame capping during long scans
- Removed duplicate code (BitmapSampler)
- Various robustness and comment updates

## Requirements
- iPhone 12 Pro or later with LiDAR (or TrueDepth for face mode)
- iOS 17+
- Swift Playgrounds or Xcode

## Getting Started
1. Open in Swift Playgrounds on iPad
2. Add `--debug` launch argument for file logging (optional)
3. Build and run on your iPhone

## Project Structure
All source files are in the root. Main components:
- `ContentView.swift` & navigation
- `ScanViewModel.swift` & AR scanning logic
- `MeshExporter.swift` & textured OBJ/PLY export
- `MeshViewerView.swift` & 3D rendering
- `ScanLibraryView.swift` & saved scans management
- And more...

Built and enhanced for iPhone 17 Pro Max / latest iOS.

## License
MIT or as per your preference.