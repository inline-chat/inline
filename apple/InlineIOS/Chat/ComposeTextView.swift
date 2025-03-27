import SwiftUI
import UIKit

class ComposeTextView: UITextView {
  private var placeholderLabel: UILabel?
  
  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    setupTextView()
    setupPlaceholder()
  }
  
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  private func setupTextView() {
    backgroundColor = .clear
    font = .systemFont(ofSize: 17)
    textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    translatesAutoresizingMaskIntoConstraints = false
  }
  
  // MARK: Placeholder Management
  
  private func setupPlaceholder() {
    let label = UILabel()
    label.text = "Write a message"
    label.font = .systemFont(ofSize: 17)
    label.textColor = .secondaryLabel
    label.translatesAutoresizingMaskIntoConstraints = false
    label.textAlignment = .left
    addSubview(label)
    
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textContainer.lineFragmentPadding + textContainerInset.left),
      label.topAnchor.constraint(equalTo: topAnchor, constant: textContainerInset.top)
    ])
    
    placeholderLabel = label
  }
  
  func showPlaceholder(_ show: Bool) {
    placeholderLabel?.alpha = show ? 1 : 0
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
    backgroundColor = .clear
    addSubview(textView)
    
    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: topAnchor),
      textView.bottomAnchor.constraint(equalTo: bottomAnchor),
      textView.leadingAnchor.constraint(equalTo: leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -42)
    ])
  }
}
