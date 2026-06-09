// ARClassification+SwiftUI.swift — LiDARMapper
// SwiftUI Color helpers for ARMeshClassification.
// Kept in a separate file so SwiftUI is never imported in
// ARGeometry+Extensions.swift (avoids View.offset() compiler conflict).

import SwiftUI
import ARKit

extension ARMeshClassification {

    /// SwiftUI Color for HUD legend dots and status views.
    var swiftUIColor: Color {
        Color(overlayColor.withAlphaComponent(1.0))
    }
}
