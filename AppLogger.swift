// AppLogger.swift — LiDARMapper
// File logging is activated by passing --debug as a launch argument.
// Nyxian: Project Settings → Arguments → Launch Arguments → add: --debug
// Logs saved to: Files App → On My iPhone → LiDARMapper → logs/

import Foundation
import UIKit

// MARK: - Log Level

enum LogLevel: String {
    case debug   = "DEBUG"
    case info    = "INFO "
    case warning = "WARN "
    case error   = "ERROR"
}

// MARK: - AppLogger

final class AppLogger {

    static let shared = AppLogger()

    let isFileLoggingEnabled: Bool

    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.lidarmapper.logger", qos: .utility)
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let args = CommandLine.arguments
        isFileLoggingEnabled = args.contains("--debug") || args.contains("-debug")
        if isFileLoggingEnabled { setupLogFile() }
        else { print("[AppLogger] Pass --debug to enable file logging.") }
    }

    // MARK: - Setup

    private func setupLogFile() {
        let docs   = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logDir = docs.appendingPathComponent("LiDARMapper/logs", isDirectory: true)

        try? FileManager.default.createDirectory(at: logDir,
                                                  withIntermediateDirectories: true)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = logDir.appendingPathComponent("scan_\(fmt.string(from: Date())).log")

        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)

        writeRaw(String(repeating: "=", count: 72))
        writeRaw("LiDARMapper | Started: \(iso.string(from: Date()))")
        writeRaw("Device: \(UIDevice.current.name) | iOS \(UIDevice.current.systemVersion)")
        writeRaw(String(repeating: "=", count: 72))
        print("[AppLogger] Logging to \(url.lastPathComponent)")
    }

    // MARK: - Public

    func log(_ msg: String,
             level: LogLevel = .info,
             file: String = #file,
             line: Int = #line) {
        queue.async { [weak self] in
            guard let self else { return }
            let src  = (file as NSString).lastPathComponent
            let line = "[\(self.iso.string(from: Date()))] [\(level.rawValue)] [\(src):\(line)] \(msg)"
            print(line)
            guard self.isFileLoggingEnabled else { return }
            self.writeRaw(line)
        }
    }

    func debug(_ msg: String, file: String = #file, line: Int = #line) {
        log(msg, level: .debug, file: file, line: line)
    }

    func warn(_ msg: String, file: String = #file, line: Int = #line) {
        log(msg, level: .warning, file: file, line: line)
    }

    func error(_ msg: String, file: String = #file, line: Int = #line) {
        log(msg, level: .error, file: file, line: line)
    }

    private func writeRaw(_ text: String) {
        fileHandle?.write((text + "\n").data(using: .utf8) ?? Data())
    }

    deinit { fileHandle?.closeFile() }
}
