import Foundation

struct SnapshotStore: Sendable {
  let fileURL: URL

  static func shared() throws -> SnapshotStore {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "MetricsAppGroup") as? String,
          !group.contains("$("),
          let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    else { throw CocoaError(.fileNoSuchFile) }
    return SnapshotStore(fileURL: container.appendingPathComponent("metrics-snapshot.json"))
  }

  func read() -> MetricsSnapshot {
    guard let data = try? Data(contentsOf: fileURL),
          let snapshot = try? JSONDecoder().decode(MetricsSnapshot.self, from: data)
    else { return .signedOut }
    return snapshot
  }

  func write(_ snapshot: MetricsSnapshot) throws {
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }
}
