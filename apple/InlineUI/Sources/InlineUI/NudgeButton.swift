import GRDB
import InlineKit
import Logger
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Native toolbar control that sends a regular Nudge on tap and reveals Urgent Nudge on hold.
public struct NudgeButton: View {
  private let log = Log.scoped("NudgeButton")

  public let peer: Peer
  public let chatId: Int64?
  @State private var isSending = false

  public init(
    peer: Peer,
    chatId: Int64? = nil
  ) {
    self.peer = peer
    self.chatId = chatId
  }

  @ViewBuilder
  public var body: some View {
#if os(iOS)
    IOSNudgeToolbarButton(
      isSending: isSending,
      onNudge: {
        triggerHaptic()
        sendNudge()
      },
      onHoldCompleted: triggerUrgentHaptic,
      onSendUrgentNudge: {
        sendNudge(nudgeText: NudgeButtonState.urgentNudgeText)
      }
    )
#elseif os(macOS)
    MacNudgeToolbarButton(
      isSending: isSending,
      onNudge: {
        triggerHaptic()
        sendNudge()
      },
      onHoldCompleted: triggerUrgentHaptic,
      onSendUrgentNudge: {
        sendNudge(nudgeText: NudgeButtonState.urgentNudgeText)
      }
    )
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

#if os(iOS)
private struct IOSNudgeToolbarButton: View {
  let isSending: Bool
  let onNudge: () -> Void
  let onHoldCompleted: () -> Void
  let onSendUrgentNudge: () -> Void

  @State private var holdProgress: CGFloat = 0
  @State private var suppressNextTap = false
  @State private var isUrgentConfirmationPresented = false

  var body: some View {
    Button {
      if suppressNextTap {
        suppressNextTap = false
      } else {
        onNudge()
      }
    } label: {
      Image(systemName: NudgeButtonState.nudgeIconName)
        .font(.body.weight(.regular))
        .imageScale(.medium)
        .frame(width: 24, height: 24)
    }
    .overlay {
      NudgeHoldProgressRing(progress: holdProgress, size: 32, lineWidth: 3)
        .allowsHitTesting(false)
    }
    .modifier(
      NudgeHoldGestureModifier(
        progress: $holdProgress,
        suppressNextTap: $suppressNextTap,
        isConfirmationPresented: $isUrgentConfirmationPresented,
        isDisabled: isSending,
        onCompleted: onHoldCompleted
      )
    )
    .popover(isPresented: $isUrgentConfirmationPresented, arrowEdge: .top) {
      UrgentNudgeConfirmationView(
        isSending: isSending,
        onSend: {
          isUrgentConfirmationPresented = false
          onSendUrgentNudge()
        }
      )
      .presentationCompactAdaptation(.popover)
    }
    .accessibilityLabel("Send Nudge")
    .accessibilityHint("Double-tap to send a Nudge. Press and hold for Urgent Nudge.")
    .accessibilityAction(named: "Urgent Nudge") {
      onHoldCompleted()
      isUrgentConfirmationPresented = true
    }
    .help("Send Nudge. Hold for Urgent Nudge.")
    .disabled(isSending)
  }
}
#elseif os(macOS)
private struct MacNudgeToolbarButton: View {
  let isSending: Bool
  let onNudge: () -> Void
  let onHoldCompleted: () -> Void
  let onSendUrgentNudge: () -> Void

  @State private var holdProgress: CGFloat = 0
  @State private var suppressNextTap = false
  @State private var isUrgentConfirmationPresented = false

  var body: some View {
    Button {
      if suppressNextTap {
        suppressNextTap = false
      } else {
        onNudge()
      }
    } label: {
      Image(systemName: NudgeButtonState.nudgeIconName)
        .font(.system(size: 16, weight: .regular))
        .imageScale(.medium)
        .frame(width: 24, height: 24)
        .frame(minWidth: 32)
    }
    .overlay {
      NudgeHoldProgressRing(progress: holdProgress, size: 26, lineWidth: 2)
        .allowsHitTesting(false)
    }
    .modifier(
      NudgeHoldGestureModifier(
        progress: $holdProgress,
        suppressNextTap: $suppressNextTap,
        isConfirmationPresented: $isUrgentConfirmationPresented,
        isDisabled: isSending,
        onCompleted: onHoldCompleted
      )
    )
    .popover(isPresented: $isUrgentConfirmationPresented, arrowEdge: .top) {
      UrgentNudgeConfirmationView(
        isSending: isSending,
        onSend: {
          isUrgentConfirmationPresented = false
          onSendUrgentNudge()
        }
      )
      .presentationCompactAdaptation(.popover)
      .presentationSizing(.fitted)
    }
    .accessibilityLabel("Send Nudge")
    .accessibilityHint("Press to send a Nudge. Press and hold for Urgent Nudge.")
    .accessibilityAction(named: "Urgent Nudge") {
      onHoldCompleted()
      isUrgentConfirmationPresented = true
    }
    .help("Send Nudge. Hold for Urgent Nudge.")
    .disabled(isSending)
  }
}
#endif

private struct NudgeHoldGestureModifier: ViewModifier {
  @Binding var progress: CGFloat
  @Binding var suppressNextTap: Bool
  @Binding var isConfirmationPresented: Bool

  let isDisabled: Bool
  let onCompleted: () -> Void

  @State private var pressStartedAt: Date?
  @State private var completedCurrentHold = false

  func body(content: Content) -> some View {
    content.onLongPressGesture(
      minimumDuration: NudgeButtonState.holdDuration,
      maximumDistance: 44,
      pressing: updatePressing,
      perform: completeHold
    )
  }

  private func updatePressing(_ isPressing: Bool) {
    guard !isDisabled else { return }

    if isPressing {
      pressStartedAt = Date()
      completedCurrentHold = false
      withAnimation(.linear(duration: NudgeButtonState.holdDuration)) {
        progress = 1
      }
      return
    }

    if let pressStartedAt,
       NudgeButtonState.shouldSuppressTap(
         holdDuration: Date().timeIntervalSince(pressStartedAt),
         completed: completedCurrentHold
       ) {
      suppressNextTap = true
    }
    pressStartedAt = nil
    resetProgress()
  }

  private func completeHold() {
    guard !isDisabled else { return }
    completedCurrentHold = true
    suppressNextTap = true
    resetProgress()
    onCompleted()
    isConfirmationPresented = true
  }

  private func resetProgress() {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      progress = 0
    }
  }
}

private struct NudgeHoldProgressRing: View {
  let progress: CGFloat
  let size: CGFloat
  let lineWidth: CGFloat

  var body: some View {
    Circle()
      .trim(from: 0, to: progress)
      .stroke(.red, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
      .frame(width: size, height: size)
      .rotationEffect(.degrees(-90))
      .opacity(progress > 0 ? 1 : 0)
      .accessibilityHidden(true)
  }
}

private struct UrgentNudgeConfirmationView: View {
  let isSending: Bool
  let onSend: () -> Void

  var body: some View {
    VStack(spacing: 14) {
      Text(NudgeButtonState.urgentNudgeText)
        .font(.system(size: 48))
        .accessibilityHidden(true)

      Text("Send an Urgent Nudge?")
        .font(.title3.weight(.semibold))

      Text(
        "Urgent Nudge asks Inline to notify them immediately with sound, even when Inline is muted. iOS or macOS settings can still limit delivery."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)

      Text("Available after both of you have sent a message in this chat.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Button(action: onSend) {
        Label {
          Text("Send Urgent Nudge")
        } icon: {
          Text(NudgeButtonState.urgentNudgeText)
        }
        .font(.headline)
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(isSending)
    }
    .padding(20)
    .frame(minWidth: 300, idealWidth: 320, maxWidth: 340)
  }
}

enum NudgeButtonState {
  static let nudgeIconName = "hand.wave"
  static let nudgeText = "👋"
  static let urgentNudgeText = "🚨"
  static let holdDuration: TimeInterval = 1.2
  static let tapSuppressionDelay: TimeInterval = 0.2

  static func shouldSuppressTap(holdDuration: TimeInterval, completed: Bool) -> Bool {
    completed || holdDuration >= tapSuppressionDelay
  }
}

#Preview {
  NudgeButton(peer: .user(id: 1))
}
