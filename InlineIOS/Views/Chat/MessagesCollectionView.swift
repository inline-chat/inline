import InlineKit
import SwiftUI
import UIKit

struct MessagesCollectionView: UIViewRepresentable {
  var fullMessages: [FullMessage]

  func makeUIView(context: Context) -> UICollectionView {
    let layout = UICollectionViewFlowLayout()
    layout.minimumInteritemSpacing = 0
    layout.minimumLineSpacing = 0
    layout.scrollDirection = .vertical

    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.backgroundColor = .clear
    collectionView.delegate = context.coordinator
    collectionView.dataSource = context.coordinator

    // Register cell with UIHostingConfiguration
    collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "MessageCell")

    // Enable bottom-up scrolling
    collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
    collectionView.contentInset = UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
    collectionView.alwaysBounceVertical = true
    collectionView.keyboardDismissMode = .none

    // Add rotation observer
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.orientationDidChange),
      name: UIDevice.orientationDidChangeNotification,
      object: nil
    )

    return collectionView
  }

  func updateUIView(_ collectionView: UICollectionView, context: Context) {
    context.coordinator.fullMessages = fullMessages
    collectionView.reloadData()

    if !fullMessages.isEmpty {
      collectionView.scrollToItem(at: IndexPath(item: 0, section: 0), at: .bottom, animated: false)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(fullMessages: fullMessages)
  }

  class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var fullMessages: [FullMessage]

    init(fullMessages: [FullMessage]) {
      self.fullMessages = fullMessages
      super.init()
    }

    @objc func orientationDidChange(_ notification: Notification) {
      guard
        let collectionView = (notification.object as? UIDevice)?.keyWindow?.rootViewController?.view
          .findCollectionView()
      else {
        return
      }

      // Wait for rotation animation to complete
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        guard let self = self else { return }

        UIView.performWithoutAnimation {
          // Reset and reapply collection view transform
          collectionView.transform = .identity
          collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)

          // Update layout
          collectionView.collectionViewLayout.invalidateLayout()
          collectionView.setNeedsLayout()
          collectionView.layoutIfNeeded()

          // Force update all visible cells
          collectionView.visibleCells.forEach { cell in
            cell.transform = .identity
            cell.transform = CGAffineTransform(scaleX: 1, y: -1)
          }

          if !self.fullMessages.isEmpty {
            collectionView.scrollToItem(
              at: IndexPath(item: 0, section: 0), at: .bottom, animated: false)
          }
        }
      }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      guard let collectionView = scrollView as? UICollectionView else { return }

      // Ensure all visible cells have correct transform
      collectionView.visibleCells.forEach { cell in
        if cell.transform == .identity {
          UIView.performWithoutAnimation {
            cell.transform = CGAffineTransform(scaleX: 1, y: -1)
          }
        }
      }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
      -> Int
    {
      return fullMessages.count
    }

    private func isTransitionFromOtherSender(at indexPath: IndexPath) -> Bool {
      let currentMessage = fullMessages[indexPath.item]
      let previousIndex = indexPath.item - 1

      guard previousIndex >= 0 else { return false }
      let previousMessage = fullMessages[previousIndex]

      return currentMessage.message.out == true && previousMessage.message.out == false
    }

    private func isTransitionToOtherSender(at indexPath: IndexPath) -> Bool {
      let currentMessage = fullMessages[indexPath.item]
      let nextIndex = indexPath.item + 1

      guard nextIndex < fullMessages.count else { return false }
      let nextMessage = fullMessages[nextIndex]

      return currentMessage.message.out == true && nextMessage.message.out == false
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
      -> UICollectionViewCell
    {
      let cell = collectionView.dequeueReusableCell(
        withReuseIdentifier: "MessageCell", for: indexPath
      )
      let fullMessage = fullMessages[indexPath.item]

      let topPadding = isTransitionFromOtherSender(at: indexPath) ? 25.0 : 1.0
      let bottomPadding = isTransitionToOtherSender(at: indexPath) ? 25.0 : 1.0
      cell.contentConfiguration = UIHostingConfiguration {
        MessageView(fullMessage: fullMessage)
          .padding(.bottom, topPadding)
          .padding(.top, bottomPadding)
      }

      cell.transform = CGAffineTransform(scaleX: 1, y: -1)
      return cell
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
      let fullMessage = fullMessages[indexPath.item]
      let width = collectionView.bounds.width - 32

      let topPadding = isTransitionFromOtherSender(at: indexPath) ? 25.0 : 1.0
      let bottomPadding = isTransitionToOtherSender(at: indexPath) ? 25.0 : 1.0

      let messageView = MessageView(fullMessage: fullMessage)
      let messageSize = UIHostingController(rootView: messageView).sizeThatFits(
        in: CGSize(width: width, height: .infinity))

      return CGSize(width: width, height: messageSize.height + bottomPadding + topPadding)
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      minimumLineSpacingForSectionAt section: Int
    ) -> CGFloat {
      return 0
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      insetForSectionAt section: Int
    ) -> UIEdgeInsets {
      return UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      minimumInteritemSpacingForSectionAt section: Int
    ) -> CGFloat {
      return 0
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      referenceSizeForFooterInSection section: Int
    ) -> CGSize {
      return .zero
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      referenceSizeForHeaderInSection section: Int
    ) -> CGSize {
      return .zero
    }
  }
}

// Helper extension to find CollectionView in view hierarchy
extension UIView {
  fileprivate func findCollectionView() -> UICollectionView? {
    if let collectionView = self as? UICollectionView {
      return collectionView
    }

    for subview in subviews {
      if let found = subview.findCollectionView() {
        return found
      }
    }

    return nil
  }
}

// Helper extension to get key window
extension UIDevice {
  fileprivate var keyWindow: UIWindow? {
    UIApplication.shared.connectedScenes
      .filter { $0.activationState == .foregroundActive }
      .first(where: { $0 is UIWindowScene })
      .flatMap { $0 as? UIWindowScene }?.windows
      .first(where: { $0.isKeyWindow })
  }
}
