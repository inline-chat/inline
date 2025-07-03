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
    stack.spacing = 4
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

  func createMessageLabel() -> UITextView {
    let textView = UITextView()
    textView.backgroundColor = .clear
    textView.textAlignment = .natural
    textView.font = .systemFont(ofSize: 17)
    textView.textColor = textColor
    textView.isEditable = false
    textView.isSelectable = false
    textView.isScrollEnabled = false
    textView.dataDetectorTypes = []
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainerInset = .zero
    textView.linkTextAttributes = [:]
    return textView
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

  func createMessageAttachmentEmbed() -> MessageAttachmentEmbed {
    let view = MessageAttachmentEmbed()
    view.translatesAutoresizingMaskIntoConstraints = false

    return view
  }

  func createMessageTimeAndStatus() -> MessageTimeAndStatus {
    let view = MessageTimeAndStatus(fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false

    return view
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
