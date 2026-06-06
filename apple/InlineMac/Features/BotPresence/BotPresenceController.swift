import Combine
import Foundation
import InlineKit
import InlineProtocol
import RealtimeV2

typealias BotPresencePeer = InlineKit.Peer

struct BotPresenceToolbarItem {
  let peer: BotPresencePeer
  let botId: Int64
  let displayName: String
  let avatar: InlineProtocol.BotAvatar
  let isVisible: Bool

  var avatarKey: String {
    BotAvatarAtlasCache.cacheKey(for: avatar)
  }
}

@MainActor
final class BotPresenceController: ObservableObject {
  static let shared = BotPresenceController()

  private let window = BotPresenceWindow()
  private var currentPeer: BotPresencePeer?
  private var currentBotId: Int64?
  private var currentAvatar: InlineProtocol.BotAvatar?
  private var currentState = InlineProtocol.BotPresenceState.with {
    $0.kind = .idle
  }
  private var visibleBotId: Int64?
  private var latestPeerByBotId: [Int64: BotPresencePeer] = [:]
  private var loadTask: Task<Void, Never>?
  private var observer: NSObjectProtocol?

  @Published private var currentToolbarItem: BotPresenceToolbarItem?

  private init() {
    observer = NotificationCenter.default.addObserver(
      forName: BotPresenceNotifications.update,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let update = BotPresenceNotifications.update(from: notification) else { return }
      Task { @MainActor in
        self?.apply(update)
      }
    }
  }

  deinit {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func setContext(peer: BotPresencePeer, realtimeV2: RealtimeV2) {
    currentPeer = peer
    currentBotId = nil
    currentAvatar = nil
    currentToolbarItem = nil
    loadTask?.cancel()
    loadTask = Task { [weak self] in
      await self?.load(peer: peer, realtimeV2: realtimeV2)
    }
  }

  func clearContext(peer: BotPresencePeer) {
    guard currentPeer == peer else { return }
    currentPeer = nil
    currentBotId = nil
    currentAvatar = nil
    currentToolbarItem = nil
    loadTask?.cancel()
  }

  func toolbarItem(for peer: BotPresencePeer) -> BotPresenceToolbarItem? {
    guard currentToolbarItem?.peer == peer else { return nil }
    return currentToolbarItem
  }

  func showCurrent() {
    guard let botId = currentBotId, let avatar = currentAvatar else { return }
    visibleBotId = botId
    show(avatar: avatar, state: currentState, botId: botId)
    refreshToolbarItem()
  }

  func close() {
    visibleBotId = nil
    window.hide()
    refreshToolbarItem()
  }

  private func load(peer: BotPresencePeer, realtimeV2: RealtimeV2) async {
    do {
      let result = try await realtimeV2.send(.getBotPresence(peer: peer))
      guard !Task.isCancelled, currentPeer == peer else { return }
      guard case let .getBotPresence(response) = result else {
        clearAvailability()
        return
      }
      apply(response)
    } catch {
      guard !Task.isCancelled, currentPeer == peer else { return }
      clearAvailability()
    }
  }

  private func apply(_ response: InlineProtocol.GetBotPresenceResult) {
    guard response.hasAvatar, response.hasBotUserID else {
      clearAvailability()
      return
    }

    let botId = response.botUserID
    let peer = response.peerID.toPeer()
    currentBotId = botId
    currentAvatar = response.avatar
    currentState = response.state
    latestPeerByBotId[botId] = peer
    refreshToolbarItem()
    prewarmAvatar(response.avatar)

    if visibleBotId == botId {
      show(avatar: response.avatar, state: response.state, botId: botId)
    }
  }

  private func apply(_ update: InlineProtocol.UpdateBotPresence) {
    let peer = update.peerID.toPeer()
    guard currentPeer == peer else { return }

    if update.avatarChanged {
      applyAvatarChange(update, peer: peer)
      return
    }

    guard currentBotId == update.botUserID else { return }

    latestPeerByBotId[update.botUserID] = peer
    currentState = update.state
    refreshToolbarItem()

    guard visibleBotId == update.botUserID, let currentAvatar = currentAvatar else {
      return
    }

    show(avatar: currentAvatar, state: update.state, botId: update.botUserID)
  }

  private func applyAvatarChange(_ update: InlineProtocol.UpdateBotPresence, peer: BotPresencePeer) {
    if let currentBotId, currentBotId != update.botUserID {
      return
    }

    currentBotId = update.botUserID
    currentState = update.state
    latestPeerByBotId[update.botUserID] = peer

    guard update.hasAvatar else {
      clearAvailability()
      return
    }

    currentAvatar = update.avatar
    refreshToolbarItem()
    prewarmAvatar(update.avatar)

    if visibleBotId == update.botUserID {
      show(avatar: update.avatar, state: update.state, botId: update.botUserID)
    }
  }

  private func clearAvailability() {
    let botId = currentBotId
    currentBotId = nil
    currentAvatar = nil
    currentToolbarItem = nil
    guard visibleBotId == botId else { return }
    visibleBotId = nil
    window.hide()
  }

  private func refreshToolbarItem() {
    guard let peer = currentPeer, let botId = currentBotId, let avatar = currentAvatar else {
      currentToolbarItem = nil
      return
    }

    currentToolbarItem = BotPresenceToolbarItem(
      peer: peer,
      botId: botId,
      displayName: avatar.displayName.isEmpty ? "Bot presence" : avatar.displayName,
      avatar: avatar,
      isVisible: visibleBotId == botId
    )
  }

  private func prewarmAvatar(_ avatar: InlineProtocol.BotAvatar) {
    Task {
      await BotAvatarAtlasCache.shared.prewarm(avatar: avatar)
    }
  }

  private func show(
    avatar: InlineProtocol.BotAvatar,
    state: InlineProtocol.BotPresenceState,
    botId: Int64
  ) {
    window.show(
      avatar: avatar,
      state: state,
      onClick: { [weak self] in
        guard let self, let peer = self.latestPeerByBotId[botId] else { return }
        MainWindowOpenCoordinator.shared.openWindow(.chat(peer: peer))
      },
      onClose: { [weak self] in
        self?.close()
      }
    )
  }
}
