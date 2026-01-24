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
#if os(iOS)
  @State private var chargeTask: Task<Void, Never>?
  @State private var chargeSendTask: Task<Void, Never>?
  @State private var isPressing = false
  @State private var isChargeCancelled = false
  private let chargeDuration: TimeInterval = 1.5
  private let chargeTick: TimeInterval = 0.15
  private let chargeMaxDistance: CGFloat = 32
#endif

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
#if os(iOS)
    .frame(minWidth: 40, minHeight: 40)
    .contentShape(Rectangle())
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          handlePressChanged(value)
        }
        .onEnded { _ in
          handlePressEnded()
        }
    )
    .onDisappear {
      handlePressEnded()
    }
#endif
    .accessibilityLabel("Send nudge")
#if os(iOS)
    .accessibilityHint("Press and hold to send a nudge.")
#endif
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
#if os(iOS)
    if !hasSeenGuide {
      hasSeenGuide = true
      showGuide = true
    }
#else
    triggerHaptic()
    if !hasSeenGuide {
      hasSeenGuide = true
      showGuide = true
      return
    }

    showGuide = false
    sendNudge()
#endif
  }

  private func sendNudge(shouldTriggerSentHaptic: Bool = false) {
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
#if os(iOS)
        if shouldTriggerSentHaptic {
          await MainActor.run {
            triggerSentHaptic()
          }
        }
#endif
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

#if os(iOS)
  private func beginCharging() {
    guard !isSending, chargeTask == nil, chargeSendTask == nil else { return }
    startChargeHaptics()
    scheduleChargedSend()
  }

  private func handleChargedSend() {
    cancelCharging()
    if !hasSeenGuide {
      hasSeenGuide = true
      showGuide = true
    } else {
      showGuide = false
    }

    sendNudge(shouldTriggerSentHaptic: true)
  }

  private func cancelCharging() {
    chargeTask?.cancel()
    chargeTask = nil
    chargeSendTask?.cancel()
    chargeSendTask = nil
  }

  private func startChargeHaptics() {
    let start = Date()

    chargeTask = Task { @MainActor in
      let generator = UIImpactFeedbackGenerator(style: .soft)
      generator.prepare()

      while !Task.isCancelled {
        let elapsed = Date().timeIntervalSince(start)
        let progress = min(max(elapsed / chargeDuration, 0), 1)
        let intensity = CGFloat(0.2 + (0.8 * progress))
        generator.impactOccurred(intensity: intensity)
        generator.prepare()

        if progress >= 1 {
          break
        }

        let delay = UInt64(chargeTick * 1_000_000_000)
        try? await Task.sleep(nanoseconds: delay)
      }
    }
  }

  private func scheduleChargedSend() {
    chargeSendTask = Task { @MainActor in
      let delay = UInt64(chargeDuration * 1_000_000_000)
      try? await Task.sleep(nanoseconds: delay)
      if Task.isCancelled {
        chargeSendTask = nil
        return
      }
      handleChargedSend()
      chargeSendTask = nil
    }
  }

  private func handlePressChanged(_ value: DragGesture.Value) {
    guard !isSending, !isChargeCancelled else { return }
    let distance = hypot(value.translation.width, value.translation.height)
    if distance > Double(chargeMaxDistance) {
      isChargeCancelled = true
      cancelCharging()
      return
    }
    if !isPressing {
      isPressing = true
      beginCharging()
    }
  }

  private func handlePressEnded() {
    isPressing = false
    isChargeCancelled = false
    cancelCharging()
  }

  private func triggerSentHaptic() {
    let generator = UIImpactFeedbackGenerator(style: .heavy)
    generator.impactOccurred()
  }
#endif
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

      guideHintText
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

  @ViewBuilder
  private var guideHintText: some View {
#if os(iOS)
    Text("Press and hold for 1.5 seconds to send a nudge.")
#elseif os(macOS)
    Text("Tap again to send a nudge.")
#endif
  }
}

#Preview {
  NudgeButton(peer: .user(id: 1))
}
