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
}

class ToastManager: ObservableObject {
  static let shared = ToastManager()

  @Published private(set) var currentToast: ToastData?
  private var timer: Timer?

  private init() {}

  func showToast(
    _ message: String,
    type: ToastType,
    systemImage: String? = nil,
    action: (() -> Void)? = nil,
    actionTitle: String? = nil,
    shouldStayVisible: Bool = false
  ) {
    // If current toast is info and should stay visible, only replace it with success or error
    if let currentToast,
       currentToast.shouldStayVisible,
       currentToast.type == .info,
       type != .success, type != .error
    {
      return
    }

    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
      currentToast = ToastData(
        message: message,
        type: type,
        action: action,
        actionTitle: actionTitle,
        systemImage: systemImage,
        shouldStayVisible: shouldStayVisible
      )
    }

    if type != .loading, !shouldStayVisible {
      setupTimer(duration: type.duration)
    }
  }

  func hideToast() {
    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
      currentToast = nil
    }
    timer?.invalidate()
    timer = nil
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
