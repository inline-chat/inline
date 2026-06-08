import AppKit
import Foundation
import InlineConfig
import UniformTypeIdentifiers
import Darwin

enum MacDevtoolsReportExporter {
  enum ExportError: Error {
    case cancelled
  }

  @MainActor
  static func export() throws -> URL {
    let panel = NSSavePanel()
    panel.title = "Export MacDevtools Report"
    panel.nameFieldStringValue = defaultFileName()
    panel.allowedContentTypes = [.plainText]
    panel.canCreateDirectories = true

    guard panel.runModal() == .OK,
          let url = panel.url
    else {
      throw ExportError.cancelled
    }

    let report = try makeReport()
    try report.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private static func makeReport() throws -> String {
    let logURL = MacDevtools.logFileURL
    let logs = logURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    return """
    Inline MacDevtools Report
    Generated: \(ISO8601DateFormatter().string(from: Date()))

    \(systemInfo(logURL: logURL))

    --- Logs ---
    \(logs)
    """
  }

  private static func systemInfo(logURL: URL?) -> String {
    let info = Bundle.main.infoDictionary ?? [:]
    let appName = (info["CFBundleName"] as? String) ?? ProcessInfo.processInfo.processName
    let version = (info["CFBundleShortVersionString"] as? String) ?? "unknown"
    let build = (info["CFBundleVersion"] as? String) ?? "unknown"
    let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
    let process = ProcessInfo.processInfo

    return """
    --- System Information ---
    App: \(appName) \(version) (\(build))
    Bundle ID: \(bundleID)
    Profile: \(MacDevtoolsPaths.profileName)
    OS: \(process.operatingSystemVersionString)
    Device: \(hardwareModel())
    Architecture: \(architecture())
    CPU Cores: \(process.processorCount)
    Memory: \(ByteCountFormatter.string(fromByteCount: Int64(process.physicalMemory), countStyle: .memory))
    Locale: \(Locale.current.identifier)
    Time Zone: \(TimeZone.current.identifier)
    Log File: \(logURL?.path ?? "unavailable")
    Capture Enabled: \(MacDevtools.captureEnabled ? "yes" : "no")
    Log Entry Cap: \(MacDevtoolsLogCapture.maxFileEntries)
    """
  }

  private static func defaultFileName() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return "inline-macdevtools-\(formatter.string(from: Date())).txt"
  }

  private static func hardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
      return "unknown"
    }

    var model = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else {
      return "unknown"
    }

    let bytes = model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }

  private static func architecture() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    return withUnsafeBytes(of: &systemInfo.machine) { buffer in
      let bytes = buffer.prefix { $0 != 0 }
      return String(decoding: bytes, as: UTF8.self)
    }
  }
}
