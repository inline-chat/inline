import Auth
import Combine
import Foundation
import GRDB
import InlineProtocol
import Logger

public struct SpaceUrlPreviewExclusionPattern: Equatable, Sendable {
  public let host: String
  public let pathPrefix: String?

  public var displayValue: String {
    guard let pathPrefix else { return host }
    return "\(host)\(pathPrefix)"
  }

  public init?(value: String) {
    guard let parsed = Self.parse(value) else { return nil }
    self = parsed
  }

  public static func hostOnly(from url: URL) -> SpaceUrlPreviewExclusionPattern? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let scheme = components.scheme?.lowercased()
    guard scheme == "http" || scheme == "https" else { return nil }
    guard components.user == nil, components.password == nil, components.port == nil else { return nil }
    guard let host = normalizeHost(components.host ?? "") else { return nil }
    return SpaceUrlPreviewExclusionPattern(host: host, pathPrefix: nil)
  }

  private init(host: String, pathPrefix: String?) {
    self.host = host
    self.pathPrefix = pathPrefix
  }

  private static func parse(_ value: String) -> SpaceUrlPreviewExclusionPattern? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return nil }

    let hasScheme = trimmed.range(
      of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#,
      options: .regularExpression
    ) != nil
    let raw = hasScheme ? trimmed : "https://\(trimmed)"
    guard let components = URLComponents(string: raw) else { return nil }
    let scheme = components.scheme?.lowercased()
    guard scheme == "http" || scheme == "https" else { return nil }
    guard components.user == nil, components.password == nil, components.port == nil else { return nil }
    guard components.query == nil, components.fragment == nil else { return nil }
    guard let host = normalizeHost(components.host ?? "") else { return nil }

    let pathPrefix = normalizePathPrefix(components.percentEncodedPath)
    guard pathPrefix != .invalid else { return nil }
    return SpaceUrlPreviewExclusionPattern(host: host, pathPrefix: pathPrefix.value)
  }

  private static func normalizeHost(_ hostname: String) -> String? {
    let host = hostname
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .trimmingSuffix(".")

    guard host.isEmpty == false, host.count <= 253, host.contains("..") == false else { return nil }
    guard host.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil else { return nil }
    guard host.first != ".", host.last != ".", host.first != "-", host.last != "-" else { return nil }

    for label in host.split(separator: ".", omittingEmptySubsequences: false) {
      guard label.isEmpty == false, label.first != "-", label.last != "-" else { return nil }
    }

    return host
  }

  private static func normalizePathPrefix(_ path: String) -> PathPrefixResult {
    guard path.count <= 2_048 else { return .invalid }
    guard path.isEmpty == false, path != "/" else { return .valid(nil) }
    guard path.first == "/" else { return .invalid }
    return .valid(path)
  }

  private enum PathPrefixResult: Equatable {
    case valid(String?)
    case invalid

    var value: String? {
      guard case let .valid(value) = self else { return nil }
      return value
    }
  }
}

public struct SpaceUrlPreviewExclusionItem: Identifiable, Equatable, Sendable {
  public let id: Int64
  public let spaceId: Int64
  public let host: String
  public let pathPrefix: String?
  public let createdBy: Int64
  public let date: Date

  public var displayValue: String {
    guard let pathPrefix else { return host }
    return "\(host)\(pathPrefix)"
  }

  public init(_ exclusion: InlineProtocol.SpaceUrlPreviewExclusion) {
    id = exclusion.id
    spaceId = exclusion.spaceID
    host = exclusion.host
    pathPrefix = exclusion.hasPathPrefix && exclusion.pathPrefix.isEmpty == false ? exclusion.pathPrefix : nil
    createdBy = exclusion.createdBy
    date = Date(timeIntervalSince1970: TimeInterval(exclusion.date))
  }
}

public struct SpaceUrlPreviewExclusionContext: Sendable {
  public let spaceId: Int64
  public let pattern: SpaceUrlPreviewExclusionPattern
}

public enum SpaceUrlPreviewExclusionAccess {
  public static func context(peer: Peer, url: URL, db: AppDatabase = .shared) -> SpaceUrlPreviewExclusionContext? {
    guard let pattern = SpaceUrlPreviewExclusionPattern.hostOnly(from: url) else { return nil }
    guard case let .thread(chatId) = peer else { return nil }
    guard let currentUserId = Auth.shared.getCurrentUserId() else { return nil }

    do {
      return try db.dbWriter.read { database in
        guard let chat = try Chat.fetchOne(database, key: chatId), let spaceId = chat.spaceId else { return nil }
        guard try canManage(spaceId: spaceId, currentUserId: currentUserId, database: database) else { return nil }
        return SpaceUrlPreviewExclusionContext(spaceId: spaceId, pattern: pattern)
      }
    } catch {
      Log.shared.error("Failed to read URL preview exclusion access", error: error)
      return nil
    }
  }

  public static func canManage(spaceId: Int64, db: AppDatabase = .shared) -> Bool {
    guard let currentUserId = Auth.shared.getCurrentUserId() else { return false }

    do {
      return try db.dbWriter.read { database in
        try canManage(spaceId: spaceId, currentUserId: currentUserId, database: database)
      }
    } catch {
      Log.shared.error("Failed to read URL preview exclusion permission", error: error)
      return false
    }
  }

  private static func canManage(spaceId: Int64, currentUserId: Int64, database: Database) throws -> Bool {
    guard let member = try Member
      .filter(Member.Columns.spaceId == spaceId)
      .filter(Member.Columns.userId == currentUserId)
      .fetchOne(database)
    else {
      return false
    }

    return member.role == .owner || member.role == .admin
  }
}

@MainActor
public final class SpaceUrlPreviewExclusionsViewModel: ObservableObject {
  @Published public private(set) var exclusions: [SpaceUrlPreviewExclusionItem] = []
  @Published public private(set) var isLoading = false
  @Published public private(set) var isMutating = false
  @Published public var errorMessage: String?

  private let spaceId: Int64
  private var didLoad = false

  public init(spaceId: Int64) {
    self.spaceId = spaceId
  }

  public func loadIfNeeded() async {
    guard didLoad == false else { return }
    await load()
  }

  public func load() async {
    guard isLoading == false else { return }
    isLoading = true
    defer { isLoading = false }

    do {
      let result = try await Api.realtime.send(.getSpaceUrlPreviewExclusions(spaceId: spaceId))
      guard case let .getSpaceURLPreviewExclusions(response)? = result else {
        throw SpaceUrlPreviewExclusionsError.invalidResponse
      }
      exclusions = response.exclusions.map(SpaceUrlPreviewExclusionItem.init).sorted()
      didLoad = true
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
      Log.shared.error("Failed to load URL preview exclusions", error: error)
    }
  }

  public func add(value: String) async {
    guard let pattern = SpaceUrlPreviewExclusionPattern(value: value) else {
      errorMessage = SpaceUrlPreviewExclusionsError.invalidPattern.localizedDescription
      return
    }

    await add(pattern: pattern)
  }

  public func add(pattern: SpaceUrlPreviewExclusionPattern) async {
    guard isMutating == false else { return }
    isMutating = true
    defer { isMutating = false }

    do {
      let result = try await Api.realtime.send(.addSpaceUrlPreviewExclusion(
        spaceId: spaceId,
        host: pattern.host,
        pathPrefix: pattern.pathPrefix
      ))
      guard case let .addSpaceURLPreviewExclusion(response)? = result, response.hasExclusion else {
        throw SpaceUrlPreviewExclusionsError.invalidResponse
      }

      upsert(SpaceUrlPreviewExclusionItem(response.exclusion))
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
      Log.shared.error("Failed to add URL preview exclusion", error: error)
    }
  }

  public func remove(id: Int64) async {
    guard isMutating == false else { return }
    isMutating = true
    defer { isMutating = false }

    do {
      _ = try await Api.realtime.send(.removeSpaceUrlPreviewExclusion(spaceId: spaceId, exclusionId: id))
      exclusions.removeAll { $0.id == id }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
      Log.shared.error("Failed to remove URL preview exclusion", error: error)
    }
  }

  private func upsert(_ item: SpaceUrlPreviewExclusionItem) {
    exclusions.removeAll { existing in
      existing.id == item.id || (existing.host == item.host && existing.pathPrefix == item.pathPrefix)
    }
    exclusions.append(item)
    exclusions.sort()
  }
}

extension SpaceUrlPreviewExclusionItem: Comparable {
  public static func < (lhs: SpaceUrlPreviewExclusionItem, rhs: SpaceUrlPreviewExclusionItem) -> Bool {
    if lhs.host != rhs.host {
      return lhs.host < rhs.host
    }
    return (lhs.pathPrefix ?? "") < (rhs.pathPrefix ?? "")
  }
}

private enum SpaceUrlPreviewExclusionsError: LocalizedError {
  case invalidPattern
  case invalidResponse

  var errorDescription: String? {
    switch self {
      case .invalidPattern:
        "Enter a valid host or URL path."
      case .invalidResponse:
        "The server returned an invalid URL preview exclusion response."
    }
  }
}

private extension String {
  func trimmingSuffix(_ suffix: Character) -> String {
    var value = self
    while value.last == suffix {
      value.removeLast()
    }
    return value
  }
}
