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
  private weak var currentMenu: ContextMenuView?

  func show(for gesture: UIGestureRecognizer, message: FullMessage, spaceId: Int64) {
    guard let sourceView = gesture.view else { return }

    previousKeyWindow = sourceView.window

    let rootVC = UIViewController()
    rootVC.view.backgroundColor = .clear

    let dimmingView = UIView(frame: rootVC.view.bounds)
    dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.25)
    dimmingView.alpha = 0
    rootVC.view.addSubview(dimmingView)

    let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
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

    let menuElements: [ContextMenuElement] = [
      .item(ContextMenuItem(
        title: "Reply",
        icon: UIImage(systemName: "arrowshape.turn.up.left"),
        action: { [weak self] in
          print("Reply tapped")
          self?.hide()
        }
      )),
      .separator,
      .item(ContextMenuItem(
        title: "Copy",
        icon: UIImage(systemName: "doc.on.doc"),
        action: { [weak self] in
          print("Copy tapped")
          self?.hide()
        }
      )),
      .separator,
      .item(ContextMenuItem(
        title: "Forward",
        icon: UIImage(systemName: "arrowshape.turn.up.right"),
        action: { [weak self] in
          print("Forward tapped")
          self?.hide()
        }
      )),
      .separator,
      .item(ContextMenuItem(
        title: "Delete",
        icon: UIImage(systemName: "trash"),
        isDestructive: true,
        action: { [weak self] in
          print("Delete tapped")
          self?.hide()
        }
      )),
    ]

    let contextMenu = ContextMenuView(elements: menuElements)
    contextMenu.translatesAutoresizingMaskIntoConstraints = false
    currentMenu = contextMenu

    // Prepare for animated presentation
    contextMenu.prepareForPresentation()

    // Add context menu to get its size
    scrollView.addSubview(contextMenu)

    // Get menu size by laying it out
    contextMenu.setNeedsLayout()
    contextMenu.layoutIfNeeded()
    let menuSize = contextMenu.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)

    // Calculate available space and positioning
    let screenBounds = UIScreen.main.bounds
    let sourceFrame = sourceView.convert(sourceView.bounds, to: nil)
    let menuSpacing: CGFloat = 20
    let safeAreaBottom = rootVC.view.safeAreaInsets.bottom

    let availableSpaceBelow = screenBounds.height - sourceFrame.maxY - safeAreaBottom - menuSpacing
    let menuFitsBelow = availableSpaceBelow >= menuSize.height

    let messageView = UIMessageView(fullMessage: message, spaceId: spaceId)
    messageView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(messageView)

    var messageTopConstraint: NSLayoutConstraint
    var contextMenuTopConstraint: NSLayoutConstraint

    if menuFitsBelow {
      // Menu fits below - normal positioning
      let originalFrame = sourceView.convert(sourceView.bounds, to: scrollView)
      messageTopConstraint = messageView.topAnchor.constraint(
        equalTo: scrollView.topAnchor,
        constant: originalFrame.minY
      )
      contextMenuTopConstraint = contextMenu.topAnchor.constraint(
        equalTo: messageView.bottomAnchor,
        constant: menuSpacing
      )
    } else {
      // Menu doesn't fit below - push message up
      let requiredHeight = sourceFrame.height + menuSpacing + menuSize.height
      let pushUpAmount = requiredHeight - availableSpaceBelow - sourceFrame.height
      let adjustedY = max(rootVC.view.safeAreaInsets.top + 20, sourceFrame.minY - pushUpAmount)

      messageTopConstraint = messageView.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: adjustedY)
      contextMenuTopConstraint = contextMenu.topAnchor.constraint(
        equalTo: messageView.bottomAnchor,
        constant: menuSpacing
      )
    }

    NSLayoutConstraint.activate([
      messageView.leadingAnchor.constraint(
        equalTo: scrollView.leadingAnchor,
        constant: sourceView.convert(sourceView.bounds, to: scrollView).minX
      ),
      messageView.widthAnchor.constraint(equalToConstant: sourceView.bounds.width),
      messageView.heightAnchor.constraint(equalToConstant: sourceView.bounds.height),
      messageTopConstraint,

      contextMenu.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
      contextMenuTopConstraint,
    ])

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
    tapGesture.cancelsTouchesInView = false
    rootVC.view.addGestureRecognizer(tapGesture)

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
    UIView.animate(withDuration: 0.25) {
      dimmingView.alpha = 1
    }
    contextMenu.animateIn(after: 0)
  }

  func hide() {
    // If rootViewController still exists, animate fade-out before removal.
    if let rootVC = overlayWindow.rootViewController,
       let dimmingView = rootVC.view.subviews
       .first(where: { $0.backgroundColor?.cgColor.alpha ?? 0 > 0 && $0 is UIView })
    {
      // Run both menu and dimming animations in parallel.
      currentMenu?.animateOut()

      UIView.animate(withDuration: 0.15, animations: {
        dimmingView.alpha = 0
      }) { _ in
        self.overlayWindow.isHidden = true
        self.overlayWindow.windowScene = nil
        self.overlayWindow.rootViewController = nil
        self.overlayWindow.resignKey()

        self.previousKeyWindow?.makeKeyAndVisible()
        self.currentMenu = nil
      }
    } else {
      overlayWindow.isHidden = true
      overlayWindow.windowScene = nil
      overlayWindow.rootViewController = nil
      overlayWindow.resignKey()

      previousKeyWindow?.makeKeyAndVisible()
      currentMenu = nil
    }
  }

  @objc private func backgroundTapped() {
    hide()
  }
}
