import Auth
import InlineKit
import Logger
import SwiftUI
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
    var outgoing: Bool { message.message.outgoing == true }

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

    let scrollView = UIScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.backgroundColor = .clear
    scrollView.isOpaque = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.alwaysBounceVertical = true
    scrollView.alwaysBounceHorizontal = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.isScrollEnabled = true
    scrollView.clipsToBounds = false

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

    let defaultReactions = [
      "🥹",
      "❤️",
      "🫡",
      "👍",
      "👎",
      "💯",
      "😂",
      "🔥",
      "🎉",
      "✔️",
      "👏",
      "🙏",
      "🤔",
      "😮",
      "😢",
      "😡",
      "🫠",
      "🤯",
      "☕️",
    ]

    let reactionPicker = ReactionPickerHostingController(
      emojis: defaultReactions,
      onEmojiSelected: { selectedEmoji in
        let currentUserId = Auth.shared.getCurrentUserId() ?? 0
        if message.reactions
          .contains(where: { $0.reaction.emoji == selectedEmoji && $0.reaction.userId == currentUserId })
        {
          Transactions.shared.mutate(transaction: .deleteReaction(.init(
            message: message.message,
            emoji: selectedEmoji,
            peerId: message.message.peerId,
            chatId: message.message.chatId
          )))
        } else {
          Transactions.shared.mutate(transaction: .addReaction(.init(
            message: message.message,
            emoji: selectedEmoji,
            userId: currentUserId,
            peerId: message.message.peerId
          )))
        }
        self.hide()
      },
      onWillDoTapped: {},
      contextMenuInteraction: nil
    )

    let reactionPickerView = reactionPicker.view!
    reactionPickerView.translatesAutoresizingMaskIntoConstraints = false

    rootVC.addChild(reactionPicker)
    reactionPicker.didMove(toParent: rootVC)

    // Add scroll view to root view controller first
    rootVC.view.addSubview(scrollView)

    // Set up scroll view constraints
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: rootVC.view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: rootVC.view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: rootVC.view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: rootVC.view.bottomAnchor),
    ])

    rootVC.view.addSubview(reactionPickerView)
    setupInitialAnimationState(for: reactionPickerView)

    let contextMenu = ContextMenuView(elements: menuElements)
    contextMenu.translatesAutoresizingMaskIntoConstraints = false
    currentMenu = contextMenu

    contextMenu.prepareForPresentation()

    rootVC.view.addSubview(contextMenu)

    // Ensure the menu never compresses — lock its intrinsic size
    contextMenu.setNeedsLayout()
    contextMenu.layoutIfNeeded()
    let menuSize = contextMenu.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    let menuWidth = contextMenu.widthAnchor.constraint(equalToConstant: menuSize.width)
    let menuHeight = contextMenu.heightAnchor.constraint(equalToConstant: menuSize.height)
    menuWidth.priority = .required
    menuHeight.priority = .required
    NSLayoutConstraint.activate([menuWidth, menuHeight])

    let screenBounds = UIScreen.main.bounds
    let sourceFrame = sourceView.convert(sourceView.bounds, to: nil)
    let menuSpacing: CGFloat = 8
    let menuEdgeSpace: CGFloat = 8
    let minimumBottomSpacing: CGFloat = 14

    // Safe-area insets (use source window while overlay is still off-screen)
    let windowSafeInsets = sourceView.window?.safeAreaInsets ?? .zero
    let safeAreaTop = windowSafeInsets.top
    let safeAreaBottom = windowSafeInsets.bottom
    
    // Configure scroll view content insets for proper scrolling
    scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: safeAreaBottom, right: 0)
    scrollView.scrollIndicatorInsets = scrollView.contentInset

    reactionPickerView.setNeedsLayout()
    reactionPickerView.layoutIfNeeded()
    let reactionPickerHeight = reactionPickerView
      .systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height

    let reactionPickerTopOffset: CGFloat = safeAreaTop + 20
    var messageTopPosition = sourceFrame.minY

    // Can we show reaction picker above the message?
    let hasSpaceAbove = (sourceFrame.minY - safeAreaTop) >= (reactionPickerHeight + 20)

    if !hasSpaceAbove {
      // Keep message below the top-anchored reaction picker
      let minTop = reactionPickerTopOffset + reactionPickerHeight + 10
      if messageTopPosition < minTop {
        messageTopPosition = minTop
      }
    }

    let messageView = UIMessageView(fullMessage: message, spaceId: spaceId)
    messageView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(messageView)

    rootVC.view.bringSubviewToFront(contextMenu)

    var messageTopConstraint: NSLayoutConstraint
    var contextMenuTopConstraint: NSLayoutConstraint

    // Shift message up if we need space for context menu
    let currentBottomSpace = screenBounds.height - (messageTopPosition + sourceFrame.height) - safeAreaBottom
    let bottomGapNeeded = menuSpacing + menuSize.height + minimumBottomSpacing
    if currentBottomSpace < bottomGapNeeded {
      messageTopPosition -= (bottomGapNeeded - currentBottomSpace)
    }

    messageTopConstraint = messageView.topAnchor.constraint(
      equalTo: scrollView.topAnchor,
      constant: messageTopPosition
    )

    let menuTopConstant = messageTopPosition + sourceFrame.height + menuSpacing

    contextMenuTopConstraint = contextMenu.topAnchor.constraint(
      equalTo: messageView.bottomAnchor,
      constant: menuSpacing
    )

    var constraints: [NSLayoutConstraint] = []

    let pickerPositionConstraint: NSLayoutConstraint = hasSpaceAbove ?
      reactionPickerView.bottomAnchor.constraint(equalTo: messageView.topAnchor, constant: -8) :
      reactionPickerView.topAnchor.constraint(
        equalTo: rootVC.view.safeAreaLayoutGuide.topAnchor,
        constant: reactionPickerTopOffset - safeAreaTop
      )
    let pickerSideConstraint: NSLayoutConstraint = outgoing ?
      reactionPickerView.trailingAnchor.constraint(equalTo: messageView.trailingAnchor) :
      reactionPickerView.leadingAnchor.constraint(equalTo: messageView.leadingAnchor)
    constraints.append(contentsOf: [
      pickerPositionConstraint,
      pickerSideConstraint,
      reactionPickerView.leadingAnchor.constraint(
        greaterThanOrEqualTo: rootVC.view.leadingAnchor,
        constant: menuEdgeSpace
      ),
      reactionPickerView.trailingAnchor.constraint(
        lessThanOrEqualTo: rootVC.view.trailingAnchor,
        constant: -menuEdgeSpace
      ),
    ])

    constraints.append(
      contentsOf: [
        messageView.leadingAnchor.constraint(
          equalTo: scrollView.leadingAnchor,
          constant: sourceFrame.minX
        ),
        messageView.widthAnchor.constraint(equalToConstant: sourceView.bounds.width),
        messageView.heightAnchor.constraint(equalToConstant: sourceView.bounds.height),
        messageTopConstraint,
        contextMenuTopConstraint,
      ]
    )

    if outgoing {
      constraints.append(
        contentsOf: [
          contextMenu.trailingAnchor.constraint(equalTo: messageView.trailingAnchor, constant: -menuEdgeSpace),
        ]
      )
    } else {
      constraints.append(
        contentsOf: [
          contextMenu.leadingAnchor.constraint(equalTo: messageView.leadingAnchor, constant: menuEdgeSpace),
        ]
      )
    }

    // Ensure context menu has enough space both from screen bottom and scroll content
    constraints.append(contentsOf: [
      contextMenu.bottomAnchor.constraint(
        lessThanOrEqualTo: rootVC.view.safeAreaLayoutGuide.bottomAnchor,
        constant: -minimumBottomSpacing
      ).withPriority(.defaultHigh),
      // Also ensure the menu stays within the scroll view's content bounds
      contextMenu.bottomAnchor.constraint(
        lessThanOrEqualTo: scrollView.bottomAnchor,
        constant: -minimumBottomSpacing
      ).withPriority(.required)
    ])

    NSLayoutConstraint.activate(constraints)

    // Calculate total content height to ensure message and menu are never cut off
    let messageEndPosition = messageTopPosition + sourceFrame.height
    let menuEndPosition = messageEndPosition + menuSpacing + menuSize.height + minimumBottomSpacing
    let reactionPickerEnd = hasSpaceAbove ? 
      reactionPickerTopOffset + reactionPickerHeight + 20 : 
      reactionPickerTopOffset + reactionPickerHeight
    
    let totalContentHeight = max(
      menuEndPosition,
      reactionPickerEnd,
      screenBounds.height + 100 // Extra padding for comfortable scrolling
    )
    scrollView.contentSize = CGSize(width: screenBounds.width, height: totalContentHeight)

    if messageTopPosition < safeAreaTop {
      let targetOffset = safeAreaTop - messageTopPosition
      scrollView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
    }

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
    tapGesture.cancelsTouchesInView = false
    rootVC.view.addGestureRecognizer(tapGesture)

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

    UIView.animate(withDuration: 0.15, delay: 0.1, options: .curveEaseOut) {
      reactionPickerView.alpha = 1
      reactionPickerView.transform = .identity
    }
  }

  private func setupInitialAnimationState(for reactionPickerView: UIView) {
    reactionPickerView.alpha = 0
    reactionPickerView.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
  }

  func hide() {
    if let rootVC = overlayWindow.rootViewController,
       let dimmingView = rootVC.view.subviews
       .first(where: { $0.backgroundColor?.cgColor.alpha ?? 0 > 0 })
    {
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
