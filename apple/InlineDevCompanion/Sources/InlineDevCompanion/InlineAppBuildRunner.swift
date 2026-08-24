import Darwin
import Foundation

struct InlineAppBuildCommand: Equatable, Sendable {
  let executableURL: URL
  let arguments: [String]
  let currentDirectoryURL: URL
  let displayCommand: String
}

struct InlineAppBuildResult: Equatable, Sendable {
  let succeeded: Bool
  let message: String?
  let logURL: URL?
}

enum InlineAppBuildRunner {
  static func build(
    _ target: InlineBuildTarget,
    logURL: URL
  ) async -> InlineAppBuildResult {
    let repositoryRoot = repositoryRoot
    return await Task.detached(priority: .userInitiated) {
      run(target, repositoryRoot: repositoryRoot, logURL: logURL)
    }.value
  }

  static func command(
    for target: InlineBuildTarget,
    repositoryRoot: URL
  ) -> InlineAppBuildCommand {
    let macOSScripts = repositoryRoot.appending(path: "scripts/macos", directoryHint: .isDirectory)
    switch target {
    case .macOS(.debug):
      return InlineAppBuildCommand(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: [
          macOSScripts.appending(path: "open-debug-app.sh").path,
          "--no-stop",
          "--no-open",
          "--no-logs",
          "--verbose",
        ],
        currentDirectoryURL: repositoryRoot,
        displayCommand: "scripts/macos/open-debug-app.sh --no-stop --no-open --no-logs --verbose"
      )
    case .macOS(.debug2):
      return InlineAppBuildCommand(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: [
          macOSScripts.appending(path: "open-debug-app.sh").path,
          "--second",
          "--no-stop",
          "--no-open",
          "--no-logs",
          "--verbose",
        ],
        currentDirectoryURL: repositoryRoot,
        displayCommand: "scripts/macos/open-debug-app.sh --second --no-stop --no-open --no-logs --verbose"
      )
    case .macOS(.dev):
      return InlineAppBuildCommand(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: [
          macOSScripts.appending(path: "build-local-app.sh").path,
          "--channel",
          "stable",
        ],
        currentDirectoryURL: repositoryRoot,
        displayCommand: "scripts/macos/build-local-app.sh --channel stable"
      )
    case let .iOS(deviceID, _):
      let script = repositoryRoot
        .appending(path: "scripts/ios/open-debug-app.sh", directoryHint: .notDirectory)
      return InlineAppBuildCommand(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: [
          script.path,
          "--device",
          deviceID,
          "--no-logs",
          "--verbose",
        ],
        currentDirectoryURL: repositoryRoot,
        displayCommand: "scripts/ios/open-debug-app.sh --device \(deviceID) --no-logs --verbose"
      )
    }
  }

  static func makeLogURL(for target: InlineBuildTarget) throws -> URL {
    let logs = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Logs/Inline Dev Companion", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let timestamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    return logs.appending(
      path: "\(target.logName)-\(timestamp).log",
      directoryHint: .notDirectory
    )
  }

  private static func run(
    _ target: InlineBuildTarget,
    repositoryRoot: URL,
    logURL: URL
  ) -> InlineAppBuildResult {
    let command = command(for: target, repositoryRoot: repositoryRoot)
    let marker = "Inline Dev Companion [\(getpid())]: \(command.displayCommand)"
    let runningURL = repositoryRoot.appending(path: ".running", directoryHint: .notDirectory)

    switch recordBuild(marker: marker, at: runningURL) {
    case let .failed(message):
      return InlineAppBuildResult(succeeded: false, message: message, logURL: nil)
    case .recorded:
      break
    }
    defer { releaseBuild(marker: marker, at: runningURL) }

    if hasActiveXcodeBuild() {
      return InlineAppBuildResult(
        succeeded: false,
        message: "Another xcodebuild process is already running.",
        logURL: nil
      )
    }

    guard FileManager.default.createFile(atPath: logURL.path, contents: nil),
          let logHandle = try? FileHandle(forWritingTo: logURL) else {
      return InlineAppBuildResult(
        succeeded: false,
        message: "Could not open the build log.",
        logURL: logURL
      )
    }
    defer { try? logHandle.close() }

    let process = Process()
    process.executableURL = command.executableURL
    process.arguments = command.arguments
    process.currentDirectoryURL = command.currentDirectoryURL
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = logHandle
    process.standardError = logHandle
    process.environment = buildEnvironment()

    do {
      try logHandle.write(contentsOf: Data("$ \(command.displayCommand)\n\n".utf8))
      try process.run()
      process.waitUntilExit()
    } catch {
      return InlineAppBuildResult(
        succeeded: false,
        message: "Could not start the build: \(error.localizedDescription)",
        logURL: logURL
      )
    }

    guard process.terminationStatus == 0 else {
      return InlineAppBuildResult(
        succeeded: false,
        message: "Build failed with exit code \(process.terminationStatus).",
        logURL: logURL
      )
    }
    return InlineAppBuildResult(succeeded: true, message: nil, logURL: logURL)
  }

  private enum BuildMarkerResult {
    case recorded
    case failed(String)
  }

  private static func recordBuild(marker: String, at runningURL: URL) -> BuildMarkerResult {
    do {
      let current = try String(contentsOf: runningURL, encoding: .utf8)
      try runningFileContents(current, appending: marker)
        .write(to: runningURL, atomically: true, encoding: .utf8)
      return .recorded
    } catch {
      return .failed("Could not record the repository build: \(error.localizedDescription)")
    }
  }

  static func runningFileContents(_ current: String, appending marker: String) -> String {
    let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
    return "\(current)\(separator)\(marker)\n"
  }

  private static func releaseBuild(marker: String, at runningURL: URL) {
    guard let current = try? String(contentsOf: runningURL, encoding: .utf8) else { return }
    let remaining = current
      .split(whereSeparator: \Character.isNewline)
      .map(String.init)
      .filter { $0 != marker }
    let updated = remaining.isEmpty ? "" : "\(remaining.joined(separator: "\n"))\n"
    try? updated.write(to: runningURL, atomically: true, encoding: .utf8)
  }

  private static func hasActiveXcodeBuild() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "xcodebuild"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  private static func buildEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let preferredPaths = [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "\(home)/.local/bin",
      "\(home)/.bun/bin",
      "\(home)/.cargo/bin",
      "/usr/bin",
      "/bin",
      "/usr/sbin",
      "/sbin",
    ]
    let inheritedPaths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    var seen = Set<String>()
    environment["PATH"] = (preferredPaths + inheritedPaths)
      .filter { seen.insert($0).inserted }
      .joined(separator: ":")
    return environment
  }

  private static var repositoryRoot: URL {
    var url = URL(fileURLWithPath: #filePath, isDirectory: false)
    for _ in 0..<5 {
      url.deleteLastPathComponent()
    }
    return url
  }
}
