import Auth
import GRDB
import InlineKit
import Logger
import Nuke
import NukeUI
import SwiftUI
import UIKit

// MARK: - UI

extension UIMessageView {
  static func createBubbleView() -> UIView {
    let view = UIView()
    UIView.performWithoutAnimation {
      view.layer.cornerRadius = 18
    }
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  func createContainerStack() -> UIStackView {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 0
    stack.alignment = .fill
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }

  func createSingleLineStack() -> UIStackView {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 6
    stack.alignment = .center
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }

  func createMultiLineStack() -> UIStackView {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 10
    stack.alignment = .fill
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }

  func createMessageLabel() -> UILabel {
    let label = UILabel()
    label.backgroundColor = .clear
    label.textAlignment = .natural
    label.font = .systemFont(ofSize: 18)
    label.textColor = textColor
    label.numberOfLines = 0

    return label
  }

  func createUnsupportedLabel() -> UILabel {
    let label = UILabel()
    label.text = "Unsupported message"
    label.backgroundColor = .clear
    label.textAlignment = .natural
    label.font = .italicSystemFont(ofSize: 18)
    label.textColor = textColor.withAlphaComponent(0.9)
    label.numberOfLines = 0

    return label
  }

  func createEmbedView() -> EmbedMessageView {
    let view = EmbedMessageView()
    return view
  }

  func createAttachmentView() -> MessageAttachmentEmbed {
    let view = MessageAttachmentEmbed()
    return view
  }

  func createPhotoView() -> PhotoView {
    let view = PhotoView(fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  func createNewPhotoView() -> NewPhotoView {
    let view = NewPhotoView(fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  func createFloatingMetadataView() -> FloatingMetadataView {
    let view = FloatingMetadataView(fullMessage: fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  func createDocumentView() -> DocumentView {
    let view = DocumentView(fullMessage: fullMessage, outgoing: outgoing)
    view.translatesAutoresizingMaskIntoConstraints = false

    return view
  }
}

// MARK: - Context Menu

extension UIMessageView: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      guard let self else { return UIMenu(children: []) }

      let isMessageSending = message.status == .sending

      let copyAction = UIAction(title: "Copy", image: UIImage(systemName: "square.on.square")) { _ in
        UIPasteboard.general.string = self.message.text
      }

      if isMessageSending {
        let cancelAction = UIAction(title: "Cancel", attributes: .destructive) { [weak self] _ in
          guard let self else { return }

          if let transactionId = message.transactionId, !transactionId.isEmpty {
            Log.shared.debug("Canceling message with transaction ID: \(transactionId)")

            Transactions.shared.cancel(transactionId: transactionId)
            Task {
              let _ = try? await AppDatabase.shared.dbWriter.write { db in
                try Message
                  .filter(Column("chatId") == self.message.chatId)
                  .filter(Column("messageId") == self.message.messageId)
                  .deleteAll(db)
              }

              // Remove from cache
              MessagesPublisher.shared
                .messagesDeleted(messageIds: [self.message.messageId], peer: self.message.peerId)
            }
          }
        }
        return UIMenu(children: [copyAction, cancelAction])
      }
      var actions: [UIAction] = [copyAction]

      if fullMessage.photoInfo != nil {
        let copyPhotoAction = UIAction(title: "Copy Photo", image: UIImage(systemName: "photo.fill.on.rectangle")) { [weak self] _ in
          guard let self else { return }
          if let image = newPhotoView.getCurrentImage() {
            UIPasteboard.general.image = image
            ToastManager.shared.showToast(
              "Photo copied to clipboard",
              type: .success,
              systemImage: "doc.on.clipboard"
            )
          }
        }
        actions.append(copyPhotoAction)
      }

      let replyAction = UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
        ChatState.shared.setReplyingMessageId(peer: self.message.peerId, id: self.message.messageId)
      }
      actions.append(replyAction)

      if message.fromId == Auth.shared.getCurrentUserId() ?? 0, message.hasText {
        let editAction = UIAction(title: "Edit", image: UIImage(systemName: "bubble.and.pencil")) { _ in
          ChatState.shared.setEditingMessageId(peer: self.message.peerId, id: self.message.messageId)
        }
        actions.append(editAction)
      }

      let openLinkAction = UIAction(title: "Open Link", image: UIImage(systemName: "arrow.up.right.square")) { _ in
        if let url = self.getURLAtLocation(location) {
          self.linkTapHandler?(url)
        }
      }
      if getURLAtLocation(location) != nil {
        actions.append(openLinkAction)
      }

      let deleteAction = UIAction(
        title: "Delete",
        image: UIImage(systemName: "trash"),
        attributes: .destructive
      ) { _ in
        self.showDeleteConfirmation()
      }

      actions.append(deleteAction)
      return UIMenu(children: actions)
    }
  }

  private func getURLAtLocation(_ location: CGPoint) -> URL? {
    guard !links.isEmpty else { return nil }

    let textContainer = NSTextContainer(size: messageLabel.bounds.size)
    textContainer.lineFragmentPadding = 0
    textContainer.lineBreakMode = messageLabel.lineBreakMode
    textContainer.maximumNumberOfLines = messageLabel.numberOfLines

    let layoutManager = NSLayoutManager()
    let textStorage = NSTextStorage(attributedString: messageLabel.attributedText ?? NSAttributedString())

    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)

    let index = layoutManager.characterIndex(
      for: location,
      in: textContainer,
      fractionOfDistanceBetweenInsertionPoints: nil
    )

    for link in links where NSLocationInRange(index, link.range) {
      return link.url
    }

    return nil
  }

  static var contextMenuOpen: Bool = false

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    Self.contextMenuOpen = true
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willEndFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    Self.contextMenuOpen = false
  }
}

// MARK: - UIGestureRecognizerDelegate

extension UIMessageView: UIGestureRecognizerDelegate {
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    // Allow simultaneous recognition with context menu interaction
    if otherGestureRecognizer is UILongPressGestureRecognizer, gestureRecognizer is UITapGestureRecognizer {
      let tapGesture = gestureRecognizer as! UITapGestureRecognizer
      return tapGesture.numberOfTapsRequired == 2
    }
    return false
  }
}

// MARK: - UIColor

extension UIColor {
  static let adaptiveBackground = UIColor { traitCollection in
    traitCollection.userInterfaceStyle == .dark ?
      UIColor(hex: "#6E242D")! : UIColor(hex: "#FFC4CB")!
  }

  static let adaptiveTitle = UIColor { traitCollection in
    traitCollection.userInterfaceStyle == .dark ?
      UIColor(hex: "#FFC2C0")! : UIColor(hex: "#D5312B")!
  }
}

// MARK: - Emoji detection

extension String {
  var containsEmoji: Bool {
    contains { $0.isEmoji }
  }

  var containsOnlyEmojis: Bool {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.allSatisfy(\.isEmoji)
  }
}

extension Character {
  /// A simple emoji is one scalar and presented to the user as an Emoji
  var isSimpleEmoji: Bool {
    guard let firstScalar = unicodeScalars.first else { return false }
    return firstScalar.properties.isEmoji && firstScalar.value > 0x238C
  }

  /// Checks if the scalars will be merged into an emoji
  var isCombinedIntoEmoji: Bool { unicodeScalars.count > 1 && unicodeScalars.first?.properties.isEmoji ?? false }

  var isEmoji: Bool { isSimpleEmoji || isCombinedIntoEmoji }
}

// MARK: - Other

extension NSLayoutConstraint {
  func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
    self.priority = priority
    return self
  }
}
