import GRDB
import InlineKit
import Logger
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Nudge button used in iOS nav bar and macOS toolbar for DMs.
public struct NudgeButton: View {
  private let log = Log.scoped("NudgeButton")

  public let peer: Peer
  public let chatId: Int64?

  @AppStorage("nudgeGuideSeen", store: UserDefaults.shared) private var hasSeenGuide = false
  @State private var showGuide = false
  @State private var isSending = false
  @State private var peerDisplayName: String? = nil

  public init(peer: Peer, chatId: Int64? = nil) {
    self.peer = peer
    self.chatId = chatId
  }

  public var body: some View {
    if let userId = peerUserId {
      content
        .onAppear {
          refreshPeerName(userId: userId)
        }
        .onReceive(ObjectCache.shared.getUserPublisher(id: userId)) { userInfo in
          peerDisplayName = userInfo?.user.displayName
        }
    } else {
      content
    }
  }

  @ViewBuilder
  private var content: some View {
    Button {
      handleTap()
    } label: {
      Image(systemName: "hand.wave")
        .font(.system(size: 16, weight: .regular))
    }
    .accessibilityLabel("Send nudge")
    .disabled(isSending)
    .popover(isPresented: $showGuide, arrowEdge: .bottom) {
      NudgeGuideView(attentionTarget: attentionTarget) {
        showGuide = false
      }
      .presentationCompactAdaptation(.popover)
    }
  }

  private var peerUserId: Int64? {
    if case let .user(id) = peer {
      return id
    }
    return nil
  }

  private var attentionTarget: String {
    NudgeButtonState.attentionTarget(displayName: peerDisplayName)
  }

  private func refreshPeerName(userId: Int64) {
    peerDisplayName = ObjectCache.shared.getUser(id: userId)?.user.displayName
  }

  private func handleTap() {
    triggerHaptic()
    if !hasSeenGuide {
      hasSeenGuide = true
      showGuide = true
      return
    }

    showGuide = false
    sendNudge()
  }

  private func sendNudge() {
    guard !isSending else { return }

    isSending = true

    Task {
      defer {
        Task { @MainActor in
          isSending = false
        }
      }

      guard let resolvedChatId = await resolveChatId() else {
        log.error("Unable to resolve chatId for nudge for peer \(peer)")
        return
      }

      do {
        _ = try await Api.realtime.send(
          .sendMessage(
            text: NudgeButtonState.nudgeText,
            peerId: peer,
            chatId: resolvedChatId,
            replyToMsgId: nil,
            isSticker: nil,
            isNudge: true,
            entities: nil,
            sendMode: nil
          )
        )
      } catch {
        log.error("Failed to send nudge", error: error)
      }
    }
  }

  private func resolveChatId() async -> Int64? {
    if let chatId, chatId > 0 {
      return chatId
    }

    do {
      return try await AppDatabase.shared.dbWriter.read { db in
        let dialogId = Dialog.getDialogId(peerId: peer)
        let dialog = try Dialog.fetchOne(db, id: dialogId)
        return dialog?.chatId
      }
    } catch {
      log.error("Failed to resolve chatId", error: error)
      return nil
    }
  }

  private func triggerHaptic() {
#if os(iOS)
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
#elseif os(macOS)
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
#endif
  }
}

enum NudgeButtonState {
  static let nudgeText = "👋"

  static func attentionTarget(displayName: String?) -> String {
    if let name = displayName, !name.isEmpty {
      return "\(name)'s"
    }

    return "their"
  }
}

private struct NudgeGuideView: View {
  let attentionTarget: String
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Nudge")
        .font(.headline)

      Text("Send a 👋 to get \(attentionTarget) attention. Nudges trigger a notification even if their notifications are off.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)

      Text("Tap again to send a nudge.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()
        Button("Got it") {
          onDismiss()
        }
#if os(iOS)
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
#elseif os(macOS)
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
#endif
      }
      .padding(.top, 4)
    }
    .padding(12)
    .frame(maxWidth: 260)
  }
}

#Preview {
  NudgeButton(peer: .user(id: 1))
}
