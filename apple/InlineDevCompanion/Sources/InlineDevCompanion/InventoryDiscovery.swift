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

  private struct PackageManifest: Decodable {
    let name: String
    let version: String
  }

  private struct ScannedInventory: Sendable {
    let applications: [InventoryItem]
    let tools: [InventoryItem]
  }

  private struct CommandResult: Sendable {
    let status: Int32
    let output: Data
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
    process.standardError = output
    process.terminationHandler = { _ in completion.signal() }

    do {
      try process.run()
    } catch {
      return nil
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
    let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
    return CommandResult(status: process.terminationStatus, output: data)
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
