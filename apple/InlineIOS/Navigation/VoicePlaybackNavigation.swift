import Auth
import GRDB
import InlineIOSUI
import InlineKit
import Logger
import SwiftUI

@MainActor
enum VoicePlaybackNavigation {
  /// Resolve the target from an explicit tap, never from a rendering path.
  static func open(
    _ target: AudioPlaybackOpenTarget,
    router: Router,
    currentPeer: Peer? = nil,
    currentChatID: Int64? = nil,
    scrollToMessage: ((Int64) -> Void)? = nil
  ) {
    let auth = Auth.shared.handle
    // Bind authority to the selected voice at the tap, before the task can queue.
    guard let account = SharedAudioPlayer.shared.voiceNavigationAccount(for: target) else { return }
    let peer = target.peer.inlinePeer
    let initialTab = router.selectedTab
    let initialPath = router.selectedTabPath
    Task { @MainActor in
      do {
        if try await !hasChat(target) {
          try auth.validateAccountMutation(account)
          _ = try await Api.realtime.send(.getChat(peer: peer), expectedAccount: account)
        }
        try auth.validateAccountMutation(account)
        guard try await hasChat(target) else {
          try auth.validateAccountMutation(account)
          showUnavailable()
          return
        }
        if try await !hasMessage(target) {
          try auth.validateAccountMutation(account)
          _ = try await Api.realtime.send(
            .getMessages(peer: peer, messageIds: [target.messageId]),
            expectedAccount: account
          )
        }
        try auth.validateAccountMutation(account)
        guard try await hasMessage(target) else {
          try auth.validateAccountMutation(account)
          showUnavailable()
          return
        }
        try auth.validateAccountMutation(account)
        guard !Task.isCancelled, router.selectedTab == initialTab, router.selectedTabPath == initialPath else { return }
        if currentPeer == peer, currentChatID == target.chatId,
           router.selectedTabPath.last?.chatPeer == peer,
           let scrollToMessage
        {
          scrollToMessage(target.messageId)
        } else {
          routeToSource(peer: peer, messageID: target.messageId, router: router)
        }
      } catch is CancellationError {
        return
      } catch {
        guard (try? auth.validateAccountMutation(account)) != nil else { return }
        Log.shared.error("Failed to open voice source message", error: error)
        showUnavailable()
      }
    }
  }

  static func routeToSource(peer: Peer, messageID: Int64, router: Router) {
    let destination = Destination.voiceMessage(peer: peer, messageID: messageID)
    if router.selectedTabPath.last?.chatPeer == peer {
      guard router.selectedTabPath.last != destination else { return }
      var path = router.selectedTabPath
      path[path.count - 1] = destination
      router[router.selectedTab] = path
    } else {
      router.openPrimaryDestination(destination)
    }
  }

  private static func hasMessage(_ target: AudioPlaybackOpenTarget) async throws -> Bool {
    try await AppDatabase.shared.dbWriter.read { db in
      try Message
        .filter(Message.Columns.chatId == target.chatId)
        .filter(Message.Columns.messageId == target.messageId)
        .fetchCount(db) > 0
    }
  }

  private static func hasChat(_ target: AudioPlaybackOpenTarget) async throws -> Bool {
    try await AppDatabase.shared.dbWriter.read { db in
      try Chat.getByPeerId(db: db, peerId: target.peer.inlinePeer)?.id == target.chatId
    }
  }

  private static func showUnavailable() {
    ToastManager.shared.showToast(
      "Message unavailable",
      type: .error,
      systemImage: "exclamationmark.triangle"
    )
  }
}

/// Lives inside a navigation page so the capsule remains below its toolbar.
private struct RootVoicePlaybackSlot: View {
  let router: Router
  let destination: Destination?
  let tab: AppTab?
  var chatPlaceholderPeer: Peer?
  var isEnabled = true
  @ObservedObject private var player = SharedAudioPlayer.shared
  @State private var isVisible = false
  @Environment(\.scenePhase) private var scenePhase

  private var isActive: Bool {
    guard isEnabled, router.presentedSheet == nil else { return false }
    if let chatPlaceholderPeer {
      return router.selectedTabPath.last?.chatPeer == chatPlaceholderPeer
    }
    return router.selectedTabPath.last?.chatPeer == nil
      && router.selectedTabPath.last == destination
      && (tab == nil || router.selectedTab == tab)
  }

  var body: some View {
    Group {
      if isActive, player.isVoiceSelected {
        VoicePlaybackPill { target in
          VoicePlaybackNavigation.open(target, router: router)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
      } else {
        Color.clear.frame(height: 0)
      }
    }
    .onAppear { isVisible = true }
    .onDisappear { isVisible = false }
    .alert("Voice playback failed", isPresented: Binding(
      get: { isVisible && scenePhase == .active && isActive && player.playbackError != nil },
      set: {
        if !$0 {
          player.clearPlaybackError()
        }
      }
    )) {
      Button("OK", role: .cancel) { player.clearPlaybackError() }
    } message: {
      Text(player.playbackError ?? "")
    }
  }
}

extension View {
  func voicePlaybackRootPill(router: Router, destination: Destination? = nil, tab: AppTab? = nil) -> some View {
    safeAreaInset(edge: .top, spacing: 0) {
      RootVoicePlaybackSlot(router: router, destination: destination, tab: tab)
    }
  }

  func voicePlaybackChatPlaceholder(router: Router, peer: Peer, isPlaceholder: Bool) -> some View {
    safeAreaInset(edge: .top, spacing: 0) {
      RootVoicePlaybackSlot(
        router: router, destination: nil, tab: nil,
        chatPlaceholderPeer: peer, isEnabled: isPlaceholder
      )
    }
  }
}
