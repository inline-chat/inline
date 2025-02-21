import InlineKit
import SwiftUI

enum ToastType {
  case info
  case success
  case loading
  
  var duration: Double {
    switch self {
      case .success: return 6.0
      case .info: return 6.0
      case .loading: return .infinity
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
    actionTitle: String? = nil
  ) {
    currentToast = ToastData(
      message: message,
      type: type,
      action: action,
      actionTitle: actionTitle,
      systemImage: systemImage
    )
    
    if type != .loading {
      setupTimer(duration: type.duration)
    }
  }
  
  func hideToast() {
    withAnimation {
      currentToast = nil
    }
    timer?.invalidate()
    timer = nil
  }
  
  private func setupTimer(duration: Double) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
      withAnimation {
        self?.hideToast()
      }
    }
  }
}
