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
  @State private var activePopover: NudgePopover?
  @State private var didLongPress = false
  @State private var showUrgent = false
  @State private var isHolding = false
  @State private var holdProgress: Double = 0
  @State private var holdHapticTask: Task<Void, Never>?
  @State private var longPressTask: Task<Void, Never>?
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
    let button = nudgeButton
#if os(iOS)
    button
      .alert(
        alertTitle,
        isPresented: Binding(
          get: { activePopover != nil },
          set: { isPresented in
            if !isPresented { activePopover = nil }
          }
        ),
        actions: {
          switch activePopover {
          case .guide:
            Button("Got it") {
              activePopover = nil
            }
          case .confirm:
            Button("Send \(NudgeButtonState.urgentNudgeText)", role: .destructive) {
              activePopover = nil
              triggerUrgentHaptic()
              sendNudge(nudgeText: NudgeButtonState.urgentNudgeText)
            }
          case .none:
            EmptyView()
          }
        },
        message: {
          Text(alertMessage)
        }
      )
#else
    button
      .popover(item: $activePopover, arrowEdge: .top) { popover in
        let content = popoverContent(popover)
          .presentationCompactAdaptation(.popover)

        if #available(macOS 15, *) {
          content.presentationSizing(.fitted)
        } else {
          content
        }
      }
#endif
  }

  private var nudgeButton: some View {
    Button {
      handleTap()
    } label: {
      ZStack {
        if holdProgress > 0 && !showUrgent {
          Circle()
            .trim(from: 0, to: holdProgress)
#if os(iOS)
            .stroke(Color.red.opacity(0.7), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            .frame(width: 32, height: 32)
#else
            .stroke(Color.red.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 28, height: 28)
#endif
            .rotationEffect(.degrees(-90))
        }
        if showUrgent {
          Text(NudgeButtonState.urgentNudgeText)
            .font(.title3.weight(.bold))
            .scaleEffect(isHolding ? 0.92 : 1)
        } else {
          Image(systemName: NudgeButtonState.nudgeIconName)
            .font(.body.weight(.regular))
            .imageScale(.medium)
            .scaleEffect(isHolding ? 0.92 : 1)
        }
      }
      .animation(.easeOut(duration: 0.15), value: isHolding)
    }
#if os(iOS)
    .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
      if pressing {
        scheduleLongPress()
      } else {
        cancelLongPress()
      }
    }, perform: {})
#else
    .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
      if pressing {
        scheduleLongPress()
      } else {
        cancelLongPress()
      }
    }, perform: {})
#endif
#if os(iOS)
    .frame(minWidth: 44, minHeight: 44)
    .contentShape(Rectangle())
#endif
    .accessibilityLabel("Send nudge")
    .disabled(isSending)
    .onChange(of: activePopover) { _, newValue in
      if newValue == nil {
        showUrgent = false
        holdProgress = 0
        cancelHoldHaptics()
      }
    }
  }

  @ViewBuilder
  private func popoverContent(_ popover: NudgePopover) -> some View {
    switch popover {
    case .guide:
      NudgeGuideView(attentionTarget: attentionTarget) {
        activePopover = nil
      }
    case .confirm:
      NudgeConfirmView(attentionTarget: attentionTarget, isSending: isSending) {
        activePopover = nil
        triggerUrgentHaptic()
        sendNudge(nudgeText: NudgeButtonState.urgentNudgeText)
      }
    }
  }

#if os(iOS)
  private var alertTitle: String {
    switch activePopover {
    case .guide:
      return "Nudge"
    case .confirm:
      return "🚨 Send an urgent nudge?"
    case .none:
      return ""
    }
  }

  private var alertMessage: String {
    switch activePopover {
    case .guide:
      return "Send a \(NudgeButtonState.nudgeText) to get \(attentionTarget) attention."
    case .confirm:
      return "An urgent nudge will pass through any notification setting and make a sound."
    case .none:
      return ""
    }
  }
#endif


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
    if didLongPress {
      didLongPress = false
      return
    }
    triggerHaptic()
    if !hasSeenGuide {
      hasSeenGuide = true
      activePopover = .guide
      return
    }

    activePopover = nil
    sendNudge()
  }

  private func handleLongPress() {
    guard !isSending else { return }
    didLongPress = true
    showUrgent = true
    cancelHoldHaptics()
    triggerHaptic()
    activePopover = .confirm
  }

  private func scheduleLongPress() {
    guard longPressTask == nil else { return }
    isHolding = true
    holdProgress = 0
    withAnimation(.linear(duration: 1.5)) {
      holdProgress = 1
    }
    startHoldHaptics()
    longPressTask = Task {
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      if Task.isCancelled { return }
      await MainActor.run {
        longPressTask = nil
        handleLongPress()
      }
    }
  }

  private func cancelLongPress() {
    longPressTask?.cancel()
    longPressTask = nil
    isHolding = false
    cancelHoldHaptics()
    withAnimation(.easeOut(duration: 0.15)) {
      holdProgress = 0
    }
    if activePopover == nil {
      showUrgent = false
    }
  }

  private func startHoldHaptics() {
#if os(iOS)
    guard holdHapticTask == nil else { return }
    holdHapticTask = Task { @MainActor in
      let generator = UIImpactFeedbackGenerator(style: .soft)
      generator.prepare()
      let total: Double = 1.5
      let step: Double = 0.3
      var elapsed: Double = 0
      while elapsed < total {
        try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
        if Task.isCancelled { return }
        elapsed += step
        let intensity = CGFloat(min(1.0, max(0.2, elapsed / total)))
        generator.impactOccurred(intensity: intensity)
        generator.prepare()
      }
      holdHapticTask = nil
    }
#endif
  }

  private func cancelHoldHaptics() {
#if os(iOS)
    holdHapticTask?.cancel()
    holdHapticTask = nil
#endif
  }

  private func sendNudge(nudgeText: String = NudgeButtonState.nudgeText) {
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
            text: nudgeText,
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

  private func triggerUrgentHaptic() {
#if os(iOS)
    let generator = UINotificationFeedbackGenerator()
    generator.notificationOccurred(.warning)
#elseif os(macOS)
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
#endif
  }
}

enum NudgeButtonState {
  static let nudgeIconName = "hand.wave"
  static let nudgeText = "👋"
  static let urgentNudgeText = "🚨"

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

#if os(iOS)
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

  private var maxWidth: CGFloat? {
#if os(iOS)
    return horizontalSizeClass == .compact ? 280 : 320
#else
    return 320
#endif
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Nudge")
        .font(.headline)

      Text(
        "Send a \(NudgeButtonState.nudgeText) to get \(attentionTarget) attention."
      )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)

      Text("Press and hold for an urgent \(NudgeButtonState.urgentNudgeText) that can notify even if their notifications are off.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()
        if #available(iOS 26, macOS 26, *) {
          Button("Got it") {
            onDismiss()
          }
          .buttonStyle(.glassProminent)
        } else {
          Button("Got it") {
            onDismiss()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.regular)
          .buttonBorderShape(.capsule)
        }
      }
      .padding(.top, 4)
    }
    .padding()
    .frame(maxWidth: maxWidth, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }
}

private struct NudgeConfirmView: View {
  let attentionTarget: String
  let isSending: Bool
  let onSend: () -> Void

#if os(iOS)
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

  private var maxWidth: CGFloat? {
#if os(iOS)
    return horizontalSizeClass == .compact ? 280 : 320
#else
    return 320
#endif
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("🚨 Send an urgent nudge?")
        .font(.headline)

      Text("An urgent nudge will pass through any notification setting and make a sound.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()
        if #available(iOS 26, macOS 26, *) {
          Button("Send") {
            onSend()
          }
          .buttonStyle(.glassProminent)
          .tint(.red)
          .disabled(isSending)
        } else {
          Button("Send") {
            onSend()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.regular)
          .buttonBorderShape(.capsule)
          .tint(.red)
          .disabled(isSending)
        }
      }
      .padding(.top, 4)
    }
    .padding()
    .frame(maxWidth: maxWidth, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
  }
}

private enum NudgePopover: Identifiable {
  case guide
  case confirm

  var id: Int {
    switch self {
    case .guide:
      return 0
    case .confirm:
      return 1
    }
  }
}

#Preview {
  NudgeButton(peer: .user(id: 1))
}
