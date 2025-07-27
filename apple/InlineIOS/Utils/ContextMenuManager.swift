import InlineKit
import UIKit

final class ContextMenuManager {
  static let shared = ContextMenuManager()
  private init() {}

  private lazy var overlayWindow: UIWindow = {
    let window = UIWindow()
    window.backgroundColor = .clear
    window.isOpaque = false
    window.windowLevel = .alert
    return window
  }()

  private weak var previousKeyWindow: UIWindow?

  func show(for gesture: UIGestureRecognizer, message: FullMessage, spaceId: Int64) {
    guard let sourceView = gesture.view else { return }

    previousKeyWindow = sourceView.window

    let rootVC = UIViewController()
    rootVC.view.backgroundColor = .clear

    let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    blurView.frame = rootVC.view.bounds
    blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    rootVC.view.addSubview(blurView)

    let scrollView = UIScrollView(frame: rootVC.view.bounds)
    scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    scrollView.backgroundColor = .clear
    scrollView.isOpaque = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.alwaysBounceVertical = true
    scrollView.contentInsetAdjustmentBehavior = .never

    let messageView = UIMessageView(fullMessage: message, spaceId: spaceId)
    messageView.frame = sourceView.convert(sourceView.bounds, to: scrollView)
    scrollView.addSubview(messageView)

    rootVC.view.addSubview(scrollView)

    overlayWindow.rootViewController = rootVC
    overlayWindow.frame = UIScreen.main.bounds

    if let scene = sourceView.window?.windowScene ??
      UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive })
    {
      overlayWindow.windowScene = scene
    }

    overlayWindow.isHidden = false
    overlayWindow.makeKeyAndVisible()
  }

  func hide() {
    overlayWindow.isHidden = true
    overlayWindow.windowScene = nil
    overlayWindow.rootViewController = nil
    overlayWindow.resignKey()

    previousKeyWindow?.makeKeyAndVisible()
  }
}
