import AppKit
import Darwin
import Foundation

enum InventoryDiscovery {
  private struct AppDefinition: Sendable {
    let id: String
    let name: String
    let bundleIdentifier: String
    let applicationFileName: String
  }

  private struct AppMetadata: Sendable {
    let bundleIdentifier: String
    let executableName: String?
    let version: String?
  }

  private struct DeviceListResponse: Decodable {
    struct Result: Decodable {
      let devices: [Device]
    }

    struct Device: Decodable {
      struct HardwareProperties: Decodable {
        let marketingName: String?
        let platform: String?
        let productType: String?
        let reality: String?
        let udid: String?
      }

      struct DeviceProperties: Decodable {
        let name: String?
        let osVersionNumber: String?
      }

      struct ConnectionProperties: Decodable {
        let pairingState: String?
        let transportType: String?
      }

      struct SoftwareProperties: Decodable {
        struct OSVersionNumber: Decodable {
          let stringValue: String

          private enum CodingKeys: String, CodingKey {
            case stringValue
          }

          init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) {
              stringValue = value
              return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            stringValue = try container.decode(String.self, forKey: .stringValue)
          }
        }

        let osVersionNumber: OSVersionNumber?
      }

      struct StateProperties: Decodable {
        let name: String?
      }

      struct Properties: Decodable {
        let connection: ConnectionProperties?
        let hardware: HardwareProperties?
        let software: SoftwareProperties?
        let state: StateProperties?
      }

      let identifier: String?
      let hardwareProperties: HardwareProperties?
      let deviceProperties: DeviceProperties?
      let connectionProperties: ConnectionProperties?
      let properties: Properties?
    }

    let result: Result
  }

  private struct DeviceAppsResponse: Decodable {
    struct Result: Decodable {
      let apps: [Application]
    }

    struct Application: Decodable {
      let bundleIdentifier: String
      let bundleVersion: String?
      let name: String
      let version: String?
    }

    let result: Result
  }

  private struct DeviceProcessesResponse: Decodable {
    struct Result: Decodable {
      let runningProcesses: [RunningProcess]
    }

    struct RunningProcess: Decodable {
      let executable: String
      let processIdentifier: Int32
    }

    let result: Result
  }

  private struct PackageManifest: Decodable {
    let name: String
    let version: String
  }

  private struct ScannedInventory: Sendable {
    let applications: [InventoryItem]
    let iOSDevices: [ConnectedIOSDevice]
    let tools: [InventoryItem]
  }

  private struct CommandResult: Sendable {
    let status: Int32
    let output: Data
  }

  private final class CommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ data: Data) {
      lock.lock()
      self.data = data
      lock.unlock()
    }

    func load() -> Data {
      lock.lock()
      defer { lock.unlock() }
      return data
    }
  }

  private static let appDefinitions = [
    AppDefinition(
      id: "inline-debug",
      name: "Inline Debug",
      bundleIdentifier: "chat.inline.InlineMac.debug",
      applicationFileName: "Inline Debug.app"
    ),
    AppDefinition(
      id: "inline-debug-2",
      name: "Inline Debug 2",
      bundleIdentifier: "chat.inline.InlineMac.debug2",
      applicationFileName: "Inline Debug.app"
    ),
    AppDefinition(
      id: "inline-dev",
      name: "Inline-Dev",
      bundleIdentifier: "chat.inline.InlineMac.devbuild",
      applicationFileName: "Inline-Dev.app"
    ),
    AppDefinition(
      id: "inline-official",
      name: "Inline",
      bundleIdentifier: "chat.inline.InlineMac",
      applicationFileName: "Inline.app"
    ),
  ]

  static let iOSDebugBundleIdentifier = "chat.inline.InlineIOS.debug"

  @MainActor
  static func snapshot() async -> InventorySnapshot {
    let scan = await Task.detached(priority: .utility) {
      scanLocalInventory()
    }.value

    let applications = zip(appDefinitions, scan.applications).map { definition, item in
      let installedItem: InventoryItem
      if item.isInstalled {
        installedItem = item
      } else if let launchServicesURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: definition.bundleIdentifier
      ), let discovered = applicationItem(definition: definition, url: launchServicesURL) {
        installedItem = discovered
      } else {
        installedItem = item
      }

      let processIDs = NSRunningApplication
        .runningApplications(withBundleIdentifier: definition.bundleIdentifier)
        .map(\.processIdentifier)
        .sorted()
      return installedItem.withRunningProcessIDs(processIDs)
    }

    return InventorySnapshot(
      applications: applications,
      iOSDevices: scan.iOSDevices,
      tools: scan.tools,
      refreshedAt: Date()
    )
  }

  private static func scanLocalInventory() -> ScannedInventory {
    let derivedDataCandidates = derivedDataApplications()
    let applications = appDefinitions.map { definition in
      var candidates = preferredApplicationURLs(for: definition)
      if definition.id == "inline-debug" || definition.id == "inline-debug-2" {
        candidates.append(contentsOf: derivedDataCandidates)
      }
      return newestApplicationItem(definition: definition, candidates: candidates)
        ?? missingApplicationItem(definition)
    }

    return ScannedInventory(
      applications: applications,
      iOSDevices: discoverConnectedIOSDevices(),
      tools: [
        discoverInlineCLI(),
        discoverOpenClawPlugin(),
        discoverHermesPlugin(),
      ]
    )
  }

  private static func preferredApplicationURLs(for definition: AppDefinition) -> [URL] {
    let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
    switch definition.id {
    case "inline-debug":
      return [applications.appending(path: "Inline Debug.app", directoryHint: .isDirectory)]
    case "inline-debug-2":
      return [applications.appending(path: "Inline Debug 2.app", directoryHint: .isDirectory)]
    case "inline-dev":
      return [
        repositoryRoot
          .appending(path: "build/InlineMacDirectLocal/Build/Products/DevBuild", directoryHint: .isDirectory)
          .appending(path: definition.applicationFileName, directoryHint: .isDirectory),
        applications.appending(path: definition.applicationFileName, directoryHint: .isDirectory),
      ]
    case "inline-official":
      return [applications.appending(path: definition.applicationFileName, directoryHint: .isDirectory)]
    default:
      return []
    }
  }

  private static func derivedDataApplications() -> [URL] {
    let derivedData = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Developer/Xcode/DerivedData", directoryHint: .isDirectory)
    guard let projects = try? FileManager.default.contentsOfDirectory(
      at: derivedData,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    var applications: [URL] = []
    for project in projects where project.lastPathComponent.hasPrefix("Inline-") {
      let products = project.appending(path: "Build/Products", directoryHint: .isDirectory)
      guard let configurations = try? FileManager.default.contentsOfDirectory(
        at: products,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      ) else {
        continue
      }
      applications.append(
        contentsOf: configurations.map {
          $0.appending(path: "Inline Debug.app", directoryHint: .isDirectory)
        }
      )
    }
    return applications
  }

  private static func newestApplicationItem(
    definition: AppDefinition,
    candidates: [URL]
  ) -> InventoryItem? {
    var seen = Set<String>()
    let matching = candidates.compactMap { candidate -> InventoryItem? in
      let path = candidate.standardizedFileURL.path
      guard seen.insert(path).inserted else { return nil }
      return applicationItem(definition: definition, url: candidate)
    }
    return matching.max { lhs, rhs in
      (lhs.modifiedAt ?? .distantPast) < (rhs.modifiedAt ?? .distantPast)
    }
  }

  private static func applicationItem(
    definition: AppDefinition,
    url: URL
  ) -> InventoryItem? {
    guard FileManager.default.fileExists(atPath: url.path),
          let metadata = appMetadata(at: url),
          metadata.bundleIdentifier == definition.bundleIdentifier else {
      return nil
    }

    let executableURL = metadata.executableName.map {
      url.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        .appending(path: $0, directoryHint: .notDirectory)
    }
    return InventoryItem(
      id: definition.id,
      kind: .application,
      name: definition.name,
      systemImage: "app.dashed",
      bundleIdentifier: definition.bundleIdentifier,
      location: url,
      version: metadata.version,
      modifiedAt: modificationDate(of: executableURL ?? url),
      runningProcessIDs: []
    )
  }

  private static func missingApplicationItem(_ definition: AppDefinition) -> InventoryItem {
    InventoryItem(
      id: definition.id,
      kind: .application,
      name: definition.name,
      systemImage: "app.dashed",
      bundleIdentifier: definition.bundleIdentifier,
      location: nil,
      version: nil,
      modifiedAt: nil,
      runningProcessIDs: []
    )
  }

  private static func appMetadata(at applicationURL: URL) -> AppMetadata? {
    let infoURL = applicationURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
    guard let data = try? Data(contentsOf: infoURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let dictionary = plist as? [String: Any],
          let bundleIdentifier = dictionary["CFBundleIdentifier"] as? String else {
      return nil
    }

    let shortVersion = dictionary["CFBundleShortVersionString"] as? String
    let buildVersion = dictionary["CFBundleVersion"] as? String
    let version: String?
    if let shortVersion, let buildVersion {
      version = "\(shortVersion) (\(buildVersion))"
    } else {
      version = shortVersion ?? buildVersion
    }
    return AppMetadata(
      bundleIdentifier: bundleIdentifier,
      executableName: dictionary["CFBundleExecutable"] as? String,
      version: version
    )
  }

  private static func discoverConnectedIOSDevices() -> [ConnectedIOSDevice] {
    let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun", isDirectory: false)
    guard let deviceList = runCommand(
      executable: xcrun,
      arguments: [
        "devicectl", "list", "devices",
        "--json-output", "-",
        "--quiet",
        "--omit-deprecated-fields-in-json",
      ],
      timeout: 4
    ), deviceList.status == 0,
      let response = try? JSONDecoder().decode(DeviceListResponse.self, from: deviceList.output)
    else {
      return []
    }

    return response.result.devices.compactMap { device in
      let hardware = device.properties?.hardware ?? device.hardwareProperties
      let connection = device.properties?.connection ?? device.connectionProperties
      guard hardware?.platform == "iOS",
            hardware?.reality == "physical",
            connection?.pairingState == "paired",
            let id = hardware?.udid ?? device.identifier,
            let name = device.properties?.state?.name ?? device.deviceProperties?.name else {
        return nil
      }

      let appsResult = runCommand(
        executable: xcrun,
        arguments: [
          "devicectl", "device", "info", "apps",
          "--device", id,
          "--bundle-id", iOSDebugBundleIdentifier,
          "--json-output", "-",
          "--quiet",
        ],
        timeout: 5
      )

      // CoreDevice remembers disconnected devices. A successful device-info query is the
      // reliable distinction between a remembered phone and one available to developer tools.
      guard let appsResult, appsResult.status == 0,
            (try? JSONDecoder().decode(
              DeviceAppsResponse.self,
              from: appsResult.output
            )) != nil else {
        return nil
      }

      let installedApplication = parseInstalledIOSApplication(appsResult.output)

      let processesResult = runCommand(
        executable: xcrun,
        arguments: [
          "devicectl", "device", "info", "processes",
          "--device", id,
          "--search", "InlineIOS",
          "--json-output", "-",
          "--quiet",
        ],
        timeout: 4
      )
      let runningProcessID = processesResult.flatMap { result in
        result.status == 0 ? parseRunningIOSProcessID(result.output) : nil
      }

      return ConnectedIOSDevice(
        id: id,
        name: name,
        model: hardware?.marketingName ?? hardware?.productType,
        osVersion: device.properties?.software?.osVersionNumber?.stringValue
          ?? device.deviceProperties?.osVersionNumber,
        connectionTransport: displayConnectionTransport(
          connection?.transportType
        ),
        installedApplication: installedApplication,
        runningProcessID: runningProcessID
      )
    }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private static func displayConnectionTransport(_ transport: String?) -> String? {
    switch transport {
    case "wired":
      "USB"
    case "localNetwork":
      "Wi-Fi"
    case let value?:
      value
    case nil:
      nil
    }
  }

  static func parseInstalledIOSApplication(_ data: Data) -> IOSInstalledApplication? {
    guard let response = try? JSONDecoder().decode(DeviceAppsResponse.self, from: data),
          let application = response.result.apps.first else {
      return nil
    }
    return IOSInstalledApplication(
      name: application.name,
      bundleIdentifier: application.bundleIdentifier,
      version: application.version,
      buildVersion: application.bundleVersion
    )
  }

  static func parseRunningIOSProcessID(_ data: Data) -> Int32? {
    guard let response = try? JSONDecoder().decode(DeviceProcessesResponse.self, from: data) else {
      return nil
    }
    return response.result.runningProcesses.first {
      URL(fileURLWithPath: $0.executable).lastPathComponent == "InlineIOS"
    }?.processIdentifier
  }

  static func parsePhysicalIOSDeviceNames(_ data: Data) -> [String] {
    guard let response = try? JSONDecoder().decode(DeviceListResponse.self, from: data) else {
      return []
    }
    return response.result.devices.compactMap { device in
      let hardware = device.properties?.hardware ?? device.hardwareProperties
      guard hardware?.platform == "iOS", hardware?.reality == "physical" else {
        return nil
      }
      return device.properties?.state?.name ?? device.deviceProperties?.name
    }
  }

  static func currentProcessIDs(for kind: InventoryKind) async -> [Int32] {
    await Task.detached(priority: .userInitiated) {
      switch kind {
      case .application:
        []
      case .inlineCLI:
        processIDs(exactName: "inline")
      case .openClawPlugin:
        processIDs(matching: [
          "openclaw/dist/index\\.js gateway",
          "(^|/)openclaw gateway",
        ])
      case .hermesPlugin:
        processIDs(matching: [
          "hermes_cli\\.main gateway",
          "/\\.hermes/plugins/inline/sidecar/index\\.mjs",
        ])
      }
    }.value
  }

  private static func discoverInlineCLI() -> InventoryItem {
    let executable = findExecutable(named: "inline")
    let rawVersion = executable.flatMap {
      let result = runCommand(executable: $0, arguments: ["--version"], timeout: 2)
      return result?.status == 0 ? result?.output : nil
    }.flatMap { String(data: $0, encoding: .utf8) }
    let version = rawVersion?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \Character.isWhitespace)
      .last
      .map(String.init)

    return InventoryItem(
      id: "inline-cli",
      kind: .inlineCLI,
      name: "Inline CLI",
      systemImage: "terminal",
      bundleIdentifier: nil,
      location: executable,
      version: version,
      modifiedAt: executable.flatMap(modificationDate),
      runningProcessIDs: processIDs(exactName: "inline")
    )
  }

  private static func discoverOpenClawPlugin() -> InventoryItem {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let openClawHome = home.appending(path: ".openclaw", directoryHint: .isDirectory)
    var candidates = [
      openClawHome.appending(path: "extensions/inline/package.json", directoryHint: .notDirectory),
      openClawHome.appending(path: "plugins/inline/package.json", directoryHint: .notDirectory),
      openClawHome.appending(
        path: "extensions/@inline-openclaw/inline/package.json",
        directoryHint: .notDirectory
      ),
    ]

    let projects = openClawHome.appending(path: "npm/projects", directoryHint: .isDirectory)
    if let projectURLs = try? FileManager.default.contentsOfDirectory(
      at: projects,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) {
      candidates.append(
        contentsOf: projectURLs.map {
          $0.appending(
            path: "node_modules/@inline-openclaw/inline/package.json",
            directoryHint: .notDirectory
          )
        }
      )
    }

    let installation = newestPackage(
      candidates: candidates,
      expectedName: "@inline-openclaw/inline"
    )
    return InventoryItem(
      id: "openclaw-inline-plugin",
      kind: .openClawPlugin,
      name: "OpenClaw Inline Plugin",
      systemImage: "puzzlepiece.extension",
      bundleIdentifier: nil,
      location: installation?.url.deletingLastPathComponent(),
      version: installation?.version,
      modifiedAt: installation?.modifiedAt,
      runningProcessIDs: processIDs(matching: [
        "openclaw/dist/index\\.js gateway",
        "(^|/)openclaw gateway",
      ])
    )
  }

  private static func discoverHermesPlugin() -> InventoryItem {
    let pluginDirectory = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".hermes/plugins/inline", directoryHint: .isDirectory)
    let manifest = pluginDirectory.appending(path: "plugin.yaml", directoryHint: .notDirectory)
    let contents = try? String(contentsOf: manifest, encoding: .utf8)
    let installed = contents != nil

    return InventoryItem(
      id: "hermes-inline-plugin",
      kind: .hermesPlugin,
      name: "Hermes Inline Plugin",
      systemImage: "puzzlepiece.extension",
      bundleIdentifier: nil,
      location: installed ? pluginDirectory : nil,
      version: contents.flatMap(parseHermesVersion),
      modifiedAt: installed ? modificationDate(of: manifest) : nil,
      runningProcessIDs: processIDs(matching: [
        "hermes_cli\\.main gateway",
        "/\\.hermes/plugins/inline/sidecar/index\\.mjs",
      ])
    )
  }

  private static func findExecutable(named name: String) -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let inheritedPaths = ProcessInfo.processInfo.environment["PATH"]?
      .split(separator: ":")
      .map(String.init) ?? []
    let fallbackPaths = [
      "\(home)/.local/bin",
      "\(home)/.cargo/bin",
      "\(home)/.bun/bin",
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
    ]

    var seen = Set<String>()
    for directory in inheritedPaths + fallbackPaths where seen.insert(directory).inserted {
      let candidate = URL(fileURLWithPath: directory, isDirectory: true)
        .appending(path: name, directoryHint: .notDirectory)
      guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
      return candidate.resolvingSymlinksInPath()
    }
    return nil
  }

  private static func newestPackage(
    candidates: [URL],
    expectedName: String
  ) -> (url: URL, version: String, modifiedAt: Date)? {
    candidates.compactMap { candidate -> (URL, String, Date)? in
      guard let data = try? Data(contentsOf: candidate),
            let version = parsePackageVersion(data, expectedName: expectedName),
            let modifiedAt = modificationDate(of: candidate) else {
        return nil
      }
      return (candidate, version, modifiedAt)
    }.max { lhs, rhs in
      lhs.2 < rhs.2
    }
  }

  static func parsePackageVersion(_ data: Data, expectedName: String) -> String? {
    guard let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data),
          manifest.name == expectedName,
          !manifest.version.isEmpty else {
      return nil
    }
    return manifest.version
  }

  static func parseHermesVersion(_ contents: String) -> String? {
    for line in contents.split(whereSeparator: \Character.isNewline) {
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2,
            parts[0].trimmingCharacters(in: .whitespaces) == "version" else {
        continue
      }
      let version = parts[1]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      return version.isEmpty ? nil : version
    }
    return nil
  }

  private static func processIDs(exactName: String) -> [Int32] {
    processIDs(arguments: ["-x", exactName])
  }

  private static func processIDs(matching patterns: [String]) -> [Int32] {
    Array(Set(patterns.flatMap { processIDs(arguments: ["-f", $0]) })).sorted()
  }

  private static func processIDs(arguments: [String]) -> [Int32] {
    let pgrep = URL(fileURLWithPath: "/usr/bin/pgrep", isDirectory: false)
    guard let result = runCommand(executable: pgrep, arguments: arguments, timeout: 1),
          result.status == 0,
          let output = String(data: result.output, encoding: .utf8) else {
      return []
    }
    return output
      .split(whereSeparator: \Character.isNewline)
      .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
      .filter { $0 != ProcessInfo.processInfo.processIdentifier }
  }

  private static func runCommand(
    executable: URL,
    arguments: [String],
    timeout: TimeInterval
  ) -> CommandResult? {
    let process = Process()
    let output = Pipe()
    let completion = DispatchSemaphore(value: 0)
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in completion.signal() }

    do {
      try process.run()
    } catch {
      return nil
    }

    let capturedOutput = CommandOutputBuffer()
    let outputRead = DispatchGroup()
    outputRead.enter()
    DispatchQueue.global(qos: .utility).async {
      capturedOutput.store((try? output.fileHandleForReading.readToEnd()) ?? Data())
      outputRead.leave()
    }

    if completion.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if completion.wait(timeout: .now() + 0.25) == .timedOut {
        Darwin.kill(process.processIdentifier, SIGKILL)
        guard completion.wait(timeout: .now() + 0.25) == .success else {
          return nil
        }
      }
    }
    guard outputRead.wait(timeout: .now() + 1) == .success else { return nil }
    return CommandResult(status: process.terminationStatus, output: capturedOutput.load())
  }

  private static func modificationDate(of url: URL) -> Date? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return attributes?[.modificationDate] as? Date
  }

  private static var repositoryRoot: URL {
    var url = URL(fileURLWithPath: #filePath, isDirectory: false)
    for _ in 0..<5 {
      url.deleteLastPathComponent()
    }
    return url
  }
}
