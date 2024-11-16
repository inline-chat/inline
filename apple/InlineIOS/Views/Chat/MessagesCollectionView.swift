import InlineKit
import SwiftUI
import UIKit

struct MessagesCollectionView: UIViewRepresentable {
  var fullMessages: [FullMessage]

  func makeUIView(context: Context) -> UICollectionView {
    let layout = UICollectionViewFlowLayout()
    layout.minimumInteritemSpacing = 2
    layout.minimumLineSpacing = 2
    layout.scrollDirection = .vertical

    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.backgroundColor = .clear
    collectionView.delegate = context.coordinator
    collectionView.dataSource = context.coordinator

    // Register cell with UIHostingConfiguration
    collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "MessageCell")

    // Enable bottom-up scrolling
    collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
    collectionView.contentInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    collectionView.alwaysBounceVertical = true
    collectionView.keyboardDismissMode = .interactive

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

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
      -> UICollectionViewCell
    {
      let cell = collectionView.dequeueReusableCell(
        withReuseIdentifier: "MessageCell", for: indexPath)
      let fullMessage = fullMessages[indexPath.item]

      // Configure cell using UIHostingConfiguration
      cell.contentConfiguration = UIHostingConfiguration {
        MessageView(fullMessage: fullMessage)
      }

      // Apply transform to maintain correct orientation
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

      let messageView = MessageView(fullMessage: fullMessage)
      let size = UIHostingController(rootView: messageView).sizeThatFits(
        in: CGSize(width: width, height: .infinity))
      return CGSize(width: width, height: size.height)
    }
  }
}
