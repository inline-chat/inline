import Foundation

struct DevToolActionResult: Equatable, Sendable {
  let succeeded: Bool
  let message: String?
  let artifactURL: URL?
}

enum DevToolRunner {
  static func launch(_ device: ConnectedIOSDevice) async -> DevToolActionResult {
    guard let application = device.installedApplication else {
      return DevToolActionResult(
        succeeded: false,
        message: "Inline Debug is not installed on \(device.name).",
        artifactURL: nil
      )
    }
    return await run(
      arguments: [
        "devicectl", "device", "process", "launch",
        "--device", device.id,
        "--terminate-existing",
        application.bundleIdentifier,
      ]
    )
  }

  static func stop(_ device: ConnectedIOSDevice) async -> DevToolActionResult {
    let process: IOSProcessLookup
    do {
      process = try await currentInlineIOSProcess(on: device)
    } catch {
      return DevToolActionResult(
        succeeded: false,
        message: error.localizedDescription,
        artifactURL: nil
      )
    }
    guard let processID = process.processID else {
      return DevToolActionResult(succeeded: true, message: nil, artifactURL: nil)
    }
    return await run(
      arguments: [
        "devicectl", "device", "process", "terminate",
        "--device", device.id,
        "--pid", String(processID),
      ]
    )
  }

  static func profile(
    name: String,
    processID: Int32,
    deviceID: String? = nil
  ) async -> DevToolActionResult {
    let traceURL: URL
    do {
      traceURL = try makeTraceURL(name: name)
    } catch {
      return DevToolActionResult(
        succeeded: false,
        message: "Could not prepare an Instruments trace: \(error.localizedDescription)",
        artifactURL: nil
      )
    }

    var arguments = [
      "xctrace", "record",
      "--template", "Time Profiler",
      "--time-limit", "30s",
      "--output", traceURL.path,
    ]
    if let deviceID {
      arguments.append(contentsOf: ["--device", deviceID])
    }
    arguments.append(contentsOf: ["--attach", String(processID)])

    let result = await run(arguments: arguments)
    return DevToolActionResult(
      succeeded: result.succeeded,
      message: result.message,
      artifactURL: result.succeeded ? traceURL : nil
    )
  }

  static func profile(_ device: ConnectedIOSDevice) async -> DevToolActionResult {
    let process: IOSProcessLookup
    do {
      process = try await currentInlineIOSProcess(on: device)
    } catch {
      return DevToolActionResult(
        succeeded: false,
        message: error.localizedDescription,
        artifactURL: nil
      )
    }
    guard let processID = process.processID else {
      return DevToolActionResult(
        succeeded: false,
        message: "Inline Debug is no longer running on \(device.name).",
        artifactURL: nil
      )
    }
    return await profile(
      name: "Inline iOS on \(device.name)",
      processID: processID,
      deviceID: device.id
    )
  }

  private static func run(arguments: [String]) async -> DevToolActionResult {
    let execution = await execute(arguments: arguments)
    guard let status = execution.status else {
      return DevToolActionResult(
        succeeded: false,
        message: execution.launchError ?? "Could not start the developer tool.",
        artifactURL: nil
      )
    }
    guard status == 0 else {
      return DevToolActionResult(
        succeeded: false,
        message: failureMessage(output: execution.output, status: status),
        artifactURL: nil
      )
    }
    return DevToolActionResult(succeeded: true, message: nil, artifactURL: nil)
  }

  private struct IOSProcessLookup {
    let processID: Int32?
  }

  private struct ProcessLookupError: LocalizedError {
    let deviceName: String
    let detail: String

    var errorDescription: String? {
      "Could not verify Inline on \(deviceName): \(detail)"
    }
  }

  private struct CommandExecution: Sendable {
    let status: Int32?
    let output: Data
    let launchError: String?
  }

  private enum ProcessCompletion: Sendable {
    case exited(Int32)
    case timedOut
    case cancelled
  }

  private static func currentInlineIOSProcess(
    on device: ConnectedIOSDevice
  ) async throws -> IOSProcessLookup {
    let execution = await execute(arguments: [
      "devicectl", "device", "info", "processes",
      "--device", device.id,
      "--search", "InlineIOS",
      "--json-output", "-",
      "--quiet",
    ])
    guard let status = execution.status else {
      throw ProcessLookupError(
        deviceName: device.name,
        detail: execution.launchError ?? "devicectl did not start."
      )
    }
    guard status == 0 else {
      throw ProcessLookupError(
        deviceName: device.name,
        detail: failureMessage(output: execution.output, status: status)
      )
    }
    return IOSProcessLookup(
      processID: InventoryDiscovery.parseRunningIOSProcessID(execution.output)
    )
  }

  private static func execute(arguments: [String]) async -> CommandExecution {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun", isDirectory: false)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output

    do {
      try process.run()
    } catch {
      return CommandExecution(status: nil, output: Data(), launchError: error.localizedDescription)
    }

    let outputTask = Task.detached(priority: .utility) {
      readOutputTail(from: output.fileHandleForReading)
    }
    let completion = await withTaskGroup(of: ProcessCompletion.self) { group in
      group.addTask(priority: .userInitiated) {
        process.waitUntilExit()
        return .exited(process.terminationStatus)
      }
      group.addTask(priority: .utility) {
        do {
          try await Task.sleep(for: .seconds(45))
          return .timedOut
        } catch {
          return .cancelled
        }
      }

      let first = await group.next() ?? .cancelled
      group.cancelAll()
      switch first {
      case .exited:
        break
      case .timedOut, .cancelled:
        if process.isRunning {
          process.terminate()
          try? await Task.sleep(for: .milliseconds(250))
        }
        if process.isRunning {
          Darwin.kill(process.processIdentifier, SIGKILL)
        }
      }
      return first
    }
    let data = await outputTask.value
    switch completion {
    case let .exited(status):
      return CommandExecution(status: status, output: data, launchError: nil)
    case .timedOut:
      return CommandExecution(
        status: nil,
        output: data,
        launchError: "Developer tool timed out after 45 seconds."
      )
    case .cancelled:
      return CommandExecution(
        status: nil,
        output: data,
        launchError: "Developer action was cancelled."
      )
    }
  }

  private static func readOutputTail(from handle: FileHandle) -> Data {
    let limit = 64 * 1_024
    var result = Data()
    while let chunk = try? handle.read(upToCount: 8 * 1_024), !chunk.isEmpty {
      result.append(chunk)
      if result.count > limit {
        result = result.suffix(limit)
      }
    }
    return result
  }

  private static func failureMessage(output: Data, status: Int32) -> String {
    let rawMessage = String(decoding: output, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !rawMessage.isEmpty {
      return String(rawMessage.suffix(1_200))
    }
    return "Developer tool exited with code \(status)."
  }

  private static func makeTraceURL(name: String) throws -> URL {
    let traces = repositoryRoot.appending(path: ".traces", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)
    let safeName = name
      .lowercased()
      .map { $0.isLetter || $0.isNumber ? $0 : "-" }
      .reduce(into: "") { result, character in
        if character != "-" || result.last != "-" {
          result.append(character)
        }
      }
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let timestamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    return traces.appending(
      path: "\(timestamp)-\(safeName)-time-profiler.trace",
      directoryHint: .notDirectory
    )
  }

  private static var repositoryRoot: URL {
    var url = URL(fileURLWithPath: #filePath, isDirectory: false)
    for _ in 0..<5 {
      url.deleteLastPathComponent()
    }
    return url
  }
}
