import Foundation

enum InventoryKind: String, Sendable {
  case application
  case inlineCLI
  case openClawPlugin
  case hermesPlugin

  var isMacApplication: Bool {
    self == .application
  }
}

struct InventoryItem: Identifiable, Equatable, Sendable {
  let id: String
  let kind: InventoryKind
  let name: String
  let systemImage: String
  let bundleIdentifier: String?
  let location: URL?
  let version: String?
  let modifiedAt: Date?
  let runningProcessIDs: [Int32]

  var isInstalled: Bool {
    location != nil
  }

  var isRunning: Bool {
    !runningProcessIDs.isEmpty
  }

  var buildTarget: InlineAppBuildTarget? {
    InlineAppBuildTarget(rawValue: id)
  }

  func withRunningProcessIDs(_ processIDs: [Int32]) -> InventoryItem {
    InventoryItem(
      id: id,
      kind: kind,
      name: name,
      systemImage: systemImage,
      bundleIdentifier: bundleIdentifier,
      location: location,
      version: version,
      modifiedAt: modifiedAt,
      runningProcessIDs: processIDs
    )
  }
}

enum InlineAppBuildTarget: String, Sendable {
  case debug = "inline-debug"
  case debug2 = "inline-debug-2"
  case dev = "inline-dev"
}

enum InlineBuildTarget: Equatable, Sendable {
  case macOS(InlineAppBuildTarget)
  case iOS(deviceID: String, deviceName: String)

  var id: String {
    switch self {
    case let .macOS(target):
      target.rawValue
    case let .iOS(deviceID, _):
      "inline-ios-\(deviceID)"
    }
  }

  var logName: String {
    switch self {
    case let .macOS(target):
      target.rawValue
    case .iOS:
      "inline-ios"
    }
  }
}

struct IOSInstalledApplication: Equatable, Sendable {
  let name: String
  let bundleIdentifier: String
  let version: String?
  let buildVersion: String?

  var displayVersion: String? {
    if let version, let buildVersion {
      return "\(version) (\(buildVersion))"
    }
    return version ?? buildVersion
  }
}

struct ConnectedIOSDevice: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let model: String?
  let osVersion: String?
  let connectionTransport: String?
  let installedApplication: IOSInstalledApplication?
  let runningProcessID: Int32?

  var buildID: String {
    InlineBuildTarget.iOS(deviceID: id, deviceName: name).id
  }

  var isRunning: Bool {
    runningProcessID != nil
  }
}

enum InventoryBuildStatus: Equatable, Sendable {
  case building(startedAt: Date, logURL: URL)
  case succeeded(elapsed: TimeInterval, logURL: URL)
  case failed(String, elapsed: TimeInterval, logURL: URL?)

  var isBuilding: Bool {
    if case .building = self {
      return true
    }
    return false
  }

  var logURL: URL? {
    switch self {
    case let .building(_, logURL):
      logURL
    case let .succeeded(_, logURL):
      logURL
    case let .failed(_, _, logURL):
      logURL
    }
  }
}

struct InventorySnapshot: Equatable, Sendable {
  let applications: [InventoryItem]
  let iOSDevices: [ConnectedIOSDevice]
  let tools: [InventoryItem]
  let refreshedAt: Date

  static let empty = InventorySnapshot(
    applications: [],
    iOSDevices: [],
    tools: [],
    refreshedAt: .distantPast
  )
}
