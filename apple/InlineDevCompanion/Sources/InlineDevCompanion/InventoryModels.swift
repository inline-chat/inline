import Foundation

enum InventoryKind: String, Sendable {
  case application
  case inlineCLI
  case openClawPlugin
  case hermesPlugin

  var isApplication: Bool {
    self == .application
  }
}

struct InventoryItem: Identifiable, Equatable, Sendable {
  let id: String
  let kind: InventoryKind
  let name: String
  let systemImage: String
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

enum InventoryBuildStatus: Equatable, Sendable {
  case building(startedAt: Date)
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
    case .building:
      nil
    case let .succeeded(_, logURL):
      logURL
    case let .failed(_, _, logURL):
      logURL
    }
  }
}

struct InventorySnapshot: Equatable, Sendable {
  let applications: [InventoryItem]
  let tools: [InventoryItem]
  let refreshedAt: Date

  static let empty = InventorySnapshot(
    applications: [],
    tools: [],
    refreshedAt: .distantPast
  )
}
