import CryptoKit
import Foundation
import InlineNotificationFence

/// A value the iOS app publishes for its extensions. Each kind is one JSON file in the app group.
public protocol SharedSnapshotPayload: Codable, Sendable {
  /// File name stem, stable across releases.
  static var kind: String { get }
  /// Bump when a change would make an older reader misread the payload. A reader ignores a file
  /// with another version until the app rewrites it.
  static var schemaVersion: Int { get }
}

/// The signed-in account a snapshot was written for, as published in the notification account
/// fence. The generation changes on every owner change, including logout and the same account
/// signing in again, so a snapshot from an earlier sign-in never reads as current.
public struct SharedSnapshotOwner: Codable, Equatable, Sendable {
  public var userID: Int64
  public var fenceGeneration: UInt64

  public init(userID: Int64, fenceGeneration: UInt64) {
    self.userID = userID
    self.fenceGeneration = fenceGeneration
  }
}

public struct SharedSnapshot<Payload: SharedSnapshotPayload>: Sendable {
  public let owner: SharedSnapshotOwner
  public let writtenAt: Date
  public let payload: Payload
}

public enum SharedSnapshotRead<Payload: SharedSnapshotPayload>: Sendable {
  /// Written for the account signed in now.
  case current(SharedSnapshot<Payload>)
  /// The account fence could not be read (keychain locked before first unlock), so the owner is
  /// unchecked.
  case unverified(SharedSnapshot<Payload>)
  /// No account is signed in.
  case signedOut
  /// No snapshot yet: the app hasn't run since install or update.
  case missing
  /// Written for another account or an earlier sign-in.
  case otherOwner
  /// Another schema version, another kind, or unreadable.
  case incompatible

  /// The snapshot when its owner is the signed-in account.
  public var current: SharedSnapshot<Payload>? {
    if case let .current(snapshot) = self { snapshot } else { nil }
  }
}

public enum SharedSnapshotWrite: Equatable, Sendable {
  case written
  /// Same owner and content as the file on disk; nothing was written.
  case unchanged
}

public enum SharedSnapshotError: Error, Equatable, Sendable {
  case containerUnavailable
  case signedOut
  case fenceUnavailable
}

/// Reads and writes app-group snapshots. Writes are atomic renames, so a reader in another process
/// sees the previous file or the new one, never a partial write, and no file lock is held.
public struct SharedSnapshotStore: Sendable {
  public static let appGroupIdentifier = "group.chat.inline"
  static let directoryName = "Snapshots"

  public let containerURL: URL
  /// Suffix that keeps Release, Debug, DevBuild and debug profiles apart in the shared container.
  public let scope: String
  private let fence: any NotificationAccountFenceStorage

  public init(
    containerURL: URL,
    scope: String,
    fence: any NotificationAccountFenceStorage = KeychainNotificationAccountFenceStorage()
  ) {
    self.containerURL = containerURL
    self.scope = scope
    self.fence = fence
  }

  /// The store in Inline's app group. `userProfile` defaults to the `INLINE_USER_PROFILE` value in
  /// the running bundle's Info.plist; the app passes its resolved profile, which can also come from
  /// launch arguments.
  public static func appGroup(
    userProfile: String? = infoPlistUserProfile,
    fence: any NotificationAccountFenceStorage = KeychainNotificationAccountFenceStorage()
  ) -> SharedSnapshotStore? {
    guard let containerURL = appGroupContainerURL else { return nil }
    return SharedSnapshotStore(
      containerURL: containerURL,
      scope: scope(namespace: InlineInstallNamespace.current, userProfile: userProfile),
      fence: fence
    )
  }

  public static var appGroupContainerURL: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
  }

  public static var infoPlistUserProfile: String? {
    let value = Bundle.main.object(forInfoDictionaryKey: "INLINE_USER_PROFILE") as? String
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // An unexpanded build setting means no profile was configured.
    return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
  }

  static func scope(namespace: String, userProfile: String?) -> String {
    [namespace, userProfile ?? ""]
      .filter { !$0.isEmpty }
      .map { "." + $0 }
      .joined()
  }

  /// Resolves a path the app stored relative to the app group, refusing anything that escapes it.
  public static func appGroupFileURL(
    relativePath: String?,
    containerURL: URL? = appGroupContainerURL
  ) -> URL? {
    guard let relativePath = relativePath?.trimmingCharacters(in: .whitespacesAndNewlines),
          !relativePath.isEmpty,
          !relativePath.hasPrefix("/"),
          !relativePath.split(separator: "/").contains(".."),
          let containerURL
    else { return nil }

    let root = containerURL.standardizedFileURL
    let fileURL = root.appendingPathComponent(relativePath).standardizedFileURL
    guard fileURL.path.hasPrefix(root.path + "/") else { return nil }
    return fileURL
  }

  public func fileURL<Payload: SharedSnapshotPayload>(for _: Payload.Type) -> URL {
    fileURL(kind: Payload.kind)
  }

  func fileURL(kind: String) -> URL {
    containerURL
      .appendingPathComponent(Self.directoryName, isDirectory: true)
      .appendingPathComponent("\(kind)\(scope).json")
  }

  /// The owner the app would stamp on a snapshot right now.
  public func currentOwner() throws(SharedSnapshotError) -> SharedSnapshotOwner {
    switch fence.read() {
    case let .present(fence):
      guard let userID = fence.userID else { throw .signedOut }
      return SharedSnapshotOwner(userID: userID, fenceGeneration: fence.generation)
    case .missing:
      throw .signedOut
    case .unavailable:
      throw .fenceUnavailable
    }
  }

  /// Writes the payload for the signed-in account, unless the file already holds the same content
  /// for the same owner. Call from the app only.
  @discardableResult
  public func write<Payload: SharedSnapshotPayload>(_ payload: Payload) throws -> SharedSnapshotWrite {
    let owner = try currentOwner()
    let payloadData = try Self.encoder.encode(payload)
    let contentHash = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
    let url = fileURL(for: Payload.self)

    if let data = try? Data(contentsOf: url),
       let header = try? Self.decoder.decode(Header.self, from: data),
       header.kind == Payload.kind,
       header.schemaVersion == Payload.schemaVersion,
       header.owner == owner,
       header.contentHash == contentHash
    {
      return .unchanged
    }

    let envelope = Envelope(
      kind: Payload.kind,
      schemaVersion: Payload.schemaVersion,
      owner: owner,
      writtenAt: Date(),
      contentHash: contentHash,
      payload: payload
    )
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Self.encoder.encode(envelope).write(to: url, options: Self.writingOptions)
    return .written
  }

  public func read<Payload: SharedSnapshotPayload>(_: Payload.Type) -> SharedSnapshotRead<Payload> {
    let fenceRead = fence.read()
    switch fenceRead {
    case .missing:
      return .signedOut
    case let .present(fence) where fence.userID == nil:
      return .signedOut
    default:
      break
    }

    guard let data = try? Data(contentsOf: fileURL(for: Payload.self)) else { return .missing }
    guard let header = try? Self.decoder.decode(Header.self, from: data),
          header.kind == Payload.kind,
          header.schemaVersion == Payload.schemaVersion,
          let envelope = try? Self.decoder.decode(Envelope<Payload>.self, from: data)
    else { return .incompatible }

    let snapshot = SharedSnapshot(owner: envelope.owner, writtenAt: envelope.writtenAt, payload: envelope.payload)
    guard case let .present(fence) = fenceRead else { return .unverified(snapshot) }
    let isOwner = fence.userID == envelope.owner.userID && fence.generation == envelope.owner.fenceGeneration
    return isOwner ? .current(snapshot) : .otherOwner
  }

  public func remove<Payload: SharedSnapshotPayload>(_: Payload.Type) throws {
    try remove(kind: Payload.kind)
  }

  func remove(kind: String) throws {
    let url = fileURL(kind: kind)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  // MARK: - Encoding

  private struct Header: Decodable {
    var kind: String
    var schemaVersion: Int
    var owner: SharedSnapshotOwner
    var contentHash: String
  }

  private struct Envelope<Payload: Codable>: Codable {
    var kind: String
    var schemaVersion: Int
    var owner: SharedSnapshotOwner
    var writtenAt: Date
    var contentHash: String
    var payload: Payload
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    // Sorted keys keep the content hash stable for equal payloads.
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }

  private static var writingOptions: Data.WritingOptions {
    #if os(iOS)
    // Widgets and the share extension run while the device is locked after first unlock.
    [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    #else
    [.atomic]
    #endif
  }
}
