import InlineKit
import SwiftUI

enum ToastType {
  case info
  case success
  case loading
  case error

  var duration: Double {
    switch self {
      case .success: 4.0
      case .info: 4.0
      case .loading: .infinity
      case .error: 4.0
    }
  }
}

struct ToastData: Identifiable {
  let id = UUID()
  let message: String
  let type: ToastType
  var action: (() -> Void)?
  var actionTitle: String?
  var systemImage: String?
  var shouldStayVisible: Bool = false
  var progressStep: Int = 0
  var totalSteps: Int = 4
}

class ToastManager: ObservableObject {
  static let shared = ToastManager()

  @Published private(set) var currentToast: ToastData?
  private var timer: Timer?
  private var progressToastId: UUID?

  private init() {}

  func showToast(
    _ message: String,
    type: ToastType,
    systemImage: String? = nil,
    action: (() -> Void)? = nil,
    actionTitle: String? = nil,
    shouldStayVisible: Bool = false
  ) {
    // If this is a progress update for an existing progress toast, update smoothly
    if let currentToast,
       currentToast.shouldStayVisible,
       currentToast.type == .info,
       type == .info,
       shouldStayVisible
    {
      updateProgressToast(message: message, systemImage: systemImage)
      return
    }

    // If current toast is info and should stay visible, only replace it with success or error
    if let currentToast,
       currentToast.shouldStayVisible,
       currentToast.type == .info,
       type != .success, type != .error
    {
      return
    }

    let newToast = ToastData(
      message: message,
      type: type,
      action: action,
      actionTitle: actionTitle,
      systemImage: systemImage,
      shouldStayVisible: shouldStayVisible
    )

    // Store the ID for progress tracking
    if type == .info, shouldStayVisible {
      progressToastId = newToast.id
    } else {
      progressToastId = nil
    }

    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
      currentToast = newToast
    }

    if type != .loading, !shouldStayVisible {
      setupTimer(duration: type.duration)
    }
  }

  func updateProgressToast(message: String, systemImage: String? = nil) {
    guard let currentToast,
          currentToast.shouldStayVisible,
          currentToast.type == .info else { return }

    let updatedToast = ToastData(
      message: message,
      type: currentToast.type,
      action: currentToast.action,
      actionTitle: currentToast.actionTitle,
      systemImage: systemImage ?? currentToast.systemImage,
      shouldStayVisible: currentToast.shouldStayVisible
    )

    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
      self.currentToast = updatedToast
    }
  }

  func showProgressStep(_ step: Int, message: String, systemImage: String? = nil) {
    guard step >= 1, step <= 4 else { return }

    let progressMessage = message
    showToast(
      progressMessage,
      type: .info,
      systemImage: systemImage,
      shouldStayVisible: true
    )
  }

  func hideToast() {
    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
      currentToast = nil
    }
    timer?.invalidate()
    timer = nil
    progressToastId = nil
  }

  private func setupTimer(duration: Double) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
      withAnimation(.linear(duration: 0.2)) {
        self?.hideToast()
      }
    }
  }
}
