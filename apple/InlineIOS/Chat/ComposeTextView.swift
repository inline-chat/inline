import SwiftUI
import UIKit

class ComposeTextView: UITextView {
  private var placeholderLabel: UILabel?

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    setupPlaceholder()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: Placeholder Management

  private func setupPlaceholder() {
    let label = UILabel()
    label.text = "Write a message"
    label.font = .systemFont(ofSize: 17)
    label.textColor = .secondaryLabel
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textContainerInset.left + 5),
      label.topAnchor.constraint(equalTo: topAnchor, constant: textContainerInset.top),
    ])

    placeholderLabel = label
  }

  func showPlaceholder(_ show: Bool) {
    UIView.animate(withDuration: 0.2) {
      self.placeholderLabel?.alpha = show ? 1 : 0
      self.placeholderLabel?.transform = show ? .identity : CGAffineTransform(translationX: 50, y: 0)
    }
  }

  // MARK: Paste Handling

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(paste(_:)) {
      return UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages
    }
    return super.canPerformAction(action, withSender: sender)
  }

  override func paste(_ sender: Any?) {
    if UIPasteboard.general.hasImages {
      (delegate as? ComposeView)?.handlePastedImage()
    } else {
      super.paste(sender)
    }
  }
}

// Add new container view class
class TextViewContainer: UIView {
  let textView: ComposeTextView

  init(textView: ComposeTextView) {
    self.textView = textView
    super.init(frame: .zero)

    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .systemBackground.withAlphaComponent(0.4)
    layer.cornerRadius = 22
    layer.borderWidth = 0.5
    layer.borderColor = UIColor.tertiaryLabel.cgColor

    addSubview(textView)

    enum Layout {
      static let textViewLeadingPadding: CGFloat = 10
      static let textViewTrailingPadding: CGFloat = 42
    }

    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: topAnchor),
      textView.bottomAnchor.constraint(equalTo: bottomAnchor),
      textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.textViewLeadingPadding),
      textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.textViewTrailingPadding),
    ])
  }
}
