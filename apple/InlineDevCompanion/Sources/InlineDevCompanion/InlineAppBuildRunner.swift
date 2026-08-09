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
  static func build(_ target: InlineAppBuildTarget) async -> InlineAppBuildResult {
    let repositoryRoot = repositoryRoot
    return await Task.detached(priority: .userInitiated) {
      run(target, repositoryRoot: repositoryRoot)
    }.value
  }

  static func command(
    for target: InlineAppBuildTarget,
    repositoryRoot: URL
  ) -> InlineAppBuildCommand {
    let scripts = repositoryRoot.appending(path: "scripts/macos", directoryHint: .isDirectory)
    switch target {
    case .debug:
      return InlineAppBuildCommand(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: [
          scripts.appending(path: "open-debug-app.sh").path,
          "--no-stop",
          "--no-open",
          "--no-logs",
        ],
        currentDirectoryURL: repositoryRoot,
        displayCommand: "scripts/macos/open-debug-app.sh --no-stop --no-open --no-logs"
      )
    case .debug2:
      return InlineAppBuildCommand(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: [
          scripts.appending(path: "open-debug-app.sh").path,
          "--second",
          "--no-stop",
          "--no-open",
          "--no-logs",
        ],
        currentDirectoryURL: repositoryRoot,
        displayCommand: "scripts/macos/open-debug-app.sh --second --no-stop --no-open --no-logs"
      )
    case .dev:
      return InlineAppBuildCommand(
        executableURL: URL(fileURLWithPath: "/bin/bash"),
        arguments: [
          scripts.appending(path: "build-local-app.sh").path,
          "--channel",
          "stable",
        ],
        currentDirectoryURL: repositoryRoot,
        displayCommand: "scripts/macos/build-local-app.sh --channel stable"
      )
    }
  }

  private static func run(
    _ target: InlineAppBuildTarget,
    repositoryRoot: URL
  ) -> InlineAppBuildResult {
    let command = command(for: target, repositoryRoot: repositoryRoot)
    let marker = "Inline Dev Companion [\(getpid())]: \(command.displayCommand)"
    let runningURL = repositoryRoot.appending(path: ".running", directoryHint: .notDirectory)

    switch reserveBuild(marker: marker, at: runningURL) {
    case .busy:
      return InlineAppBuildResult(
        succeeded: false,
        message: "Another repository build is already listed in .running.",
        logURL: nil
      )
    case let .failed(message):
      return InlineAppBuildResult(succeeded: false, message: message, logURL: nil)
    case .reserved:
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

    let logURL: URL
    do {
      logURL = try makeLogURL(for: target)
    } catch {
      return InlineAppBuildResult(
        succeeded: false,
        message: "Could not create a build log: \(error.localizedDescription)",
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

  private enum ReservationResult {
    case reserved
    case busy
    case failed(String)
  }

  private static func reserveBuild(marker: String, at runningURL: URL) -> ReservationResult {
    do {
      let current = try String(contentsOf: runningURL, encoding: .utf8)
      guard current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .busy
      }
      try "\(marker)\n".write(to: runningURL, atomically: true, encoding: .utf8)
      return .reserved
    } catch {
      return .failed("Could not reserve the repository build slot: \(error.localizedDescription)")
    }
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

  private static func makeLogURL(for target: InlineAppBuildTarget) throws -> URL {
    let logs = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Logs/Inline Dev Companion", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let timestamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    return logs.appending(path: "\(target.rawValue)-\(timestamp).log", directoryHint: .notDirectory)
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
