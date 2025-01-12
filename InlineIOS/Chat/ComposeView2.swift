import InlineKit
import SwiftUI
import UIKit

class ComposeTextView2: UITextView {
  private var placeholderLabel: UILabel?

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    setupPlaceholder()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupPlaceholder() {
    let label = UILabel()
    label.text = "Write a message"
    label.font = .systemFont(ofSize: 17)
    label.textColor = .placeholderText
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
      label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
    ])

    placeholderLabel = label
  }

  func showPlaceholder(_ show: Bool) {
    UIView.animate(withDuration: 0.2) {
      self.placeholderLabel?.alpha = show ? 1 : 0
      self.placeholderLabel?.transform = show ? .identity : CGAffineTransform(translationX: 40, y: 0)
    }
  }
}

class ComposeView2: UIView {
  private let minHeight: CGFloat = 48
  private let maxHeight: CGFloat = 300
  private var heightConstraint: NSLayoutConstraint!
  private var prevTextHeight: CGFloat = 0.0

  private lazy var textView: ComposeTextView2 = {
    let textView = ComposeTextView2()
    textView.font = .systemFont(ofSize: 17)
    textView.isScrollEnabled = true
    textView.backgroundColor = .clear
    textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 10)
    textView.delegate = self
    textView.translatesAutoresizingMaskIntoConstraints = false
  
    return textView
  }()

  private lazy var sendButton: UIButton = {
    let button = UIButton()
    button.translatesAutoresizingMaskIntoConstraints = false

    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "arrow.up")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 14)
    )
    config.baseForegroundColor = .white
    config.background.backgroundColor = .systemBlue
    config.cornerStyle = .capsule

    button.configuration = config
    button.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
    button.isHidden = true
    return button
  }()

  var onSend: ((String) -> Void)?
  var onHeightChange: ((CGFloat) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    backgroundColor = .clear

    let blurEffect = UIBlurEffect(style: .systemMaterial)
    let blurView = UIVisualEffectView(effect: blurEffect)

    blurView.translatesAutoresizingMaskIntoConstraints = false
    insertSubview(blurView, at: 0)

    addSubview(textView)
    addSubview(sendButton)

    heightConstraint = heightAnchor.constraint(equalToConstant: minHeight)

    NSLayoutConstraint.activate([
      blurView.topAnchor.constraint(equalTo: topAnchor),
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

      heightConstraint,

      textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
      textView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),

      sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
      sendButton.widthAnchor.constraint(equalToConstant: 28),
      sendButton.heightAnchor.constraint(equalToConstant: 28),

      textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -10),
    ])
  }

  @objc private func sendTapped() {
    guard let text = textView.text?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty
    else { return }

    // Capture text before clearing
    let messageText = text

    UIView.animate(withDuration: 0.2) {
      self.textView.text = ""
      self.resetHeight()
      self.textView.showPlaceholder(true)
      self.sendButton.isHidden = true

    } completion: { _ in
      // Only call onSend after animation completes to prevent any potential lag
      self.onSend?(messageText)
    }
  }

  private func updateHeight() {
    let layoutManager = textView.layoutManager
    let textContainer = textView.textContainer

    layoutManager.ensureLayout(for: textContainer)
    let contentHeight = layoutManager.usedRect(for: textContainer).height

    // Ignore small height changes
    if abs(prevTextHeight - contentHeight) < 8.0 {
      return
    }

    prevTextHeight = contentHeight

    let newHeight = min(maxHeight, max(minHeight, contentHeight + 16))

    guard abs(heightConstraint.constant - newHeight) > 1 else { return }

    // First update height immediately to prevent clipping
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    textView.frame = CGRect(
      x: textView.frame.minX,
      y: textView.frame.minY,
      width: textView.frame.width,
      height: newHeight
    )
    CATransaction.commit()

    heightConstraint.constant = newHeight
    onHeightChange?(newHeight)
  }

  private func resetHeight() {
    UIView.animate(withDuration: 0.2) {
      self.heightConstraint.constant = self.minHeight
      self.textView.frame = CGRect(
        x: self.textView.frame.minX,
        y: self.textView.frame.minY,
        width: self.textView.frame.width,
        height: self.minHeight
      )
      self.superview?.layoutIfNeeded()
    }
    onHeightChange?(minHeight)
  }
}

extension ComposeView2: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    updateHeight()

    let isEmpty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    self.textView.showPlaceholder(isEmpty)
    sendButton.isHidden = isEmpty
  }
}
