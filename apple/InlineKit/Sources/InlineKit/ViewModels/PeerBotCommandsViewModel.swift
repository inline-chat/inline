import Foundation
import InlineProtocol
import Logger
import Observation

public struct PeerBotCommandSuggestion: Identifiable, Equatable, Sendable {
  public let command: String
  public let description: String
  public let normalizedCommand: String
  public let botId: Int64
  public let botUsername: String?
  public let botDisplayName: String
  public let botUserInfo: UserInfo
  public let isAmbiguous: Bool

  public var id: String {
    "\(botId):\(normalizedCommand)"
  }

  public var botLabel: String? {
    guard let botUsername, !botUsername.isEmpty else { return nil }
    return "@\(botUsername)"
  }

  public var insertionText: String {
    if isAmbiguous, let botUsername, !botUsername.isEmpty {
      return "/\(command)@\(botUsername) "
    }
    return "/\(command) "
  }
}

@MainActor
@Observable
public final class PeerBotCommandsViewModel {
  public enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  public typealias Fetcher = @Sendable (Peer) async throws -> [InlineProtocol.PeerBotCommands]
  public typealias UserInfoResolver = @MainActor (Int64, InlineProtocol.User) -> UserInfo

  public private(set) var peer: Peer
  public private(set) var loadState: LoadState = .idle
  public private(set) var botGroups: [InlineProtocol.PeerBotCommands] = []

  @ObservationIgnored private let fetcher: Fetcher
  @ObservationIgnored private let userInfoResolver: UserInfoResolver
  @ObservationIgnored private let log = Log.scoped("PeerBotCommandsViewModel")
  @ObservationIgnored private var cache: [Peer: [InlineProtocol.PeerBotCommands]] = [:]

  public init(peer: Peer, fetcher: @escaping Fetcher) {
    self.peer = peer
    self.fetcher = fetcher
    userInfoResolver = PeerBotCommandsViewModel.resolveUserInfo
  }

  public init(
    peer: Peer,
    fetcher: @escaping Fetcher,
    userInfoResolver: @escaping UserInfoResolver
  ) {
    self.peer = peer
    self.fetcher = fetcher
    self.userInfoResolver = userInfoResolver
  }

  public convenience init(peer: Peer) {
    self.init(peer: peer, fetcher: Self.fetchPeerBotCommands)
  }

  public var suggestions: [PeerBotCommandSuggestion] {
    Self.flattenSuggestions(from: botGroups, userInfoResolver: userInfoResolver)
  }

  public var shouldAttemptLoad: Bool {
    switch loadState {
      case .idle, .failed:
        return true
      case .loading, .loaded:
        return false
    }
  }

  public func suggestions(matching query: String) -> [PeerBotCommandSuggestion] {
    let normalizedQuery = query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    guard !normalizedQuery.isEmpty else {
      return suggestions
    }

    let parts = normalizedQuery.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    let commandQuery = parts.first.map(String.init) ?? ""
    let botQuery = parts.count > 1 ? String(parts[1]) : nil

    return suggestions.filter { suggestion in
      let commandMatches = commandQuery.isEmpty || suggestion.normalizedCommand.contains(commandQuery)
      if let botQuery {
        guard commandMatches else { return false }
        return suggestion.botUsername?.lowercased().contains(botQuery) == true
      }

      if commandMatches {
        return true
      }

      let descriptionMatches = suggestion.description.lowercased().contains(normalizedQuery)
      let usernameMatches = suggestion.botUsername?.lowercased().contains(normalizedQuery) == true
      return descriptionMatches || usernameMatches
    }
  }

  public func ensureLoaded() async {
    if let cached = cache[peer] {
      botGroups = cached
      loadState = .loaded
      return
    }

    guard loadState != .loading else { return }
    await fetchAndStore(for: peer)
  }

  public func refresh() async {
    await fetchAndStore(for: peer, forceRefresh: true)
  }

  public func setPeer(_ peer: Peer) {
    guard self.peer != peer else { return }

    self.peer = peer
    if let cached = cache[peer] {
      botGroups = cached
      loadState = .loaded
      return
    }

    botGroups = []
    loadState = .idle
  }

  private func fetchAndStore(for peer: Peer, forceRefresh: Bool = false) async {
    if !forceRefresh, let cached = cache[peer] {
      botGroups = cached
      loadState = .loaded
      return
    }

    loadState = .loading

    do {
      let groups = try await fetcher(peer)
      cache[peer] = groups

      guard self.peer == peer else {
        return
      }

      botGroups = groups
      loadState = .loaded
    } catch {
      log.error("Failed to fetch peer bot commands", error: error)
      guard self.peer == peer else { return }
      loadState = .failed(String(describing: error))
    }
  }

  private static func fetchPeerBotCommands(for peer: Peer) async throws -> [InlineProtocol.PeerBotCommands] {
    let response = try await Realtime.shared.invoke(
      .getPeerBotCommands,
      input: .getPeerBotCommands(.with {
        $0.peerID = peer.toInputPeer()
      })
    )

    guard case let .getPeerBotCommands(result)? = response else {
      throw PeerBotCommandsViewModelError.invalidResponse
    }

    return result.bots
  }

  private static func flattenSuggestions(
    from groups: [InlineProtocol.PeerBotCommands],
    userInfoResolver: UserInfoResolver
  ) -> [PeerBotCommandSuggestion] {
    var countsByNormalizedCommand: [String: Int] = [:]
    for group in groups {
      for command in group.commands {
        let normalized = command.command.lowercased()
        countsByNormalizedCommand[normalized, default: 0] += 1
      }
    }

    return groups.flatMap { group in
      let bot = group.bot
      let botUsername = bot.username.nilIfEmpty
      let botDisplayName = displayName(for: bot)
      let botUserInfo = userInfoResolver(bot.id, bot)

      return group.commands.map { command in
        let normalizedCommand = command.command.lowercased()
        return PeerBotCommandSuggestion(
          command: command.command,
          description: command.description_p,
          normalizedCommand: normalizedCommand,
          botId: bot.id,
          botUsername: botUsername,
          botDisplayName: botDisplayName,
          botUserInfo: botUserInfo,
          isAmbiguous: (countsByNormalizedCommand[normalizedCommand] ?? 0) > 1
        )
      }
    }
  }

  private static func resolveUserInfo(botId: Int64, fallbackProtocolUser: InlineProtocol.User) -> UserInfo {
    if let cached = ObjectCache.shared.getUser(id: botId) {
      return cached
    }
    return UserInfo(user: User(from: fallbackProtocolUser))
  }

  private static func displayName(for user: InlineProtocol.User) -> String {
    let explicit = [user.firstName.nilIfEmpty, user.lastName.nilIfEmpty]
      .compactMap { $0 }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !explicit.isEmpty {
      return explicit
    }
    if let username = user.username.nilIfEmpty {
      return "@\(username)"
    }
    return "Bot"
  }
}

private enum PeerBotCommandsViewModelError: Error {
  case invalidResponse
}

private extension String {
  var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
