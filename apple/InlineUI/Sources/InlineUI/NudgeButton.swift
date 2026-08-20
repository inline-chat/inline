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
        holdDuration: NudgeButtonState.iOSHoldDuration,
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
        holdDuration: NudgeButtonState.macOSHoldDuration,
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
  let holdDuration: TimeInterval
  let onCompleted: () -> Void

  @State private var holdTask: Task<Void, Never>?
  @State private var isPressing = false
  @State private var completedCurrentHold = false
  @State private var cancelledCurrentHold = false

  func body(content: Content) -> some View {
    content
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .onChanged(updatePressing)
          .onEnded { _ in endPress() }
      )
      .onDisappear {
        cancelPress()
      }
      .onChange(of: isDisabled) { _, disabled in
        if disabled {
          cancelPress()
        }
      }
  }

  private func updatePressing(_ value: DragGesture.Value) {
    guard !isDisabled, !cancelledCurrentHold, !completedCurrentHold else { return }

    let distance = hypot(value.translation.width, value.translation.height)
    guard distance <= NudgeButtonState.maximumHoldMovement else {
      cancelPress(cancelledUntilRelease: true)
      return
    }

    guard !isPressing else { return }
    beginPress()
  }

  private func beginPress() {
    isPressing = true
    completedCurrentHold = false
    cancelledCurrentHold = false
    withAnimation(.linear(duration: holdDuration)) {
      progress = 1
    }

    holdTask?.cancel()
    holdTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(holdDuration))
      guard !Task.isCancelled, isPressing else { return }
      completeHold()
    }
  }

  private func completeHold() {
    guard !isDisabled, isPressing, !completedCurrentHold else { return }
    holdTask = nil
    completedCurrentHold = true
    suppressNextTap = true
    resetProgress()
    onCompleted()
    isConfirmationPresented = true
  }

  private func endPress() {
    holdTask?.cancel()
    holdTask = nil
    isPressing = false
    cancelledCurrentHold = false
    let releaseState = NudgeButtonState.releaseState(completed: completedCurrentHold)
    completedCurrentHold = releaseState.completedCurrentHold
    suppressNextTap = releaseState.suppressNextTap
    resetProgress()
  }

  private func cancelPress(cancelledUntilRelease: Bool = false) {
    holdTask?.cancel()
    holdTask = nil
    isPressing = false
    completedCurrentHold = false
    cancelledCurrentHold = cancelledUntilRelease
    resetProgress()
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
  static let iOSHoldDuration: TimeInterval = 0.5
  static let macOSHoldDuration: TimeInterval = 1.2
  static let maximumHoldMovement: CGFloat = 44

  static func releaseState(completed: Bool) -> (suppressNextTap: Bool, completedCurrentHold: Bool) {
    (suppressNextTap: completed, completedCurrentHold: false)
  }
}

#Preview {
  NudgeButton(peer: .user(id: 1))
}
