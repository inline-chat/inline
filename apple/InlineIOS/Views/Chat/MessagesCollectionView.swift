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
        withReuseIdentifier: "MessageCell", for: indexPath)
      let fullMessage = fullMessages[indexPath.item]

      let topPadding = isTransitionFromOtherSender(at: indexPath) ? 25.0 : 1.0
      let bottomPadding = isTransitionToOtherSender(at: indexPath) ? 25.0 : 1.0
      cell.contentConfiguration = UIHostingConfiguration {
        // VStack(spacing: 0) {
        MessageView(fullMessage: fullMessage)
          .padding(.bottom, topPadding)
          .padding(.top, bottomPadding)
        // }
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

      // Calculate message size without padding
      let messageView = MessageView(fullMessage: fullMessage)
      let messageSize = UIHostingController(rootView: messageView).sizeThatFits(
        in: CGSize(width: width, height: .infinity))

      // Add both paddings to total height
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
