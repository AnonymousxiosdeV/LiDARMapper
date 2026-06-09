// LiDARMapperApp.swift — LiDARMapper
// SwiftUI app entry point. Pass --debug as a launch argument to enable file logging.
// Nyxian: Project Settings → Arguments → Launch Arguments → add: --debug

import SwiftUI

@main
struct LiDARMapperApp: App {

    init() {
        let log = AppLogger.shared
        log.log("LiDARMapper v1.0 launched")
        log.log("File logging: \(log.isFileLoggingEnabled ? "ENABLED (--debug)" : "disabled")")
        log.debug("Launch args: \(CommandLine.arguments.joined(separator: " "))")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
