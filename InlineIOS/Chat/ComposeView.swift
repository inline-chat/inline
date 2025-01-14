import InlineKit
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

  private func setupPlaceholder() {
    let label = UILabel()
    label.text = "Write a message"
    label.font = .systemFont(ofSize: 17)
    label.textColor = .placeholderText
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ComposeView.textViewHorizantalPadding + 3),
      label.topAnchor.constraint(equalTo: topAnchor, constant: ComposeView.textViewVerticalPadding),
    ])

    placeholderLabel = label
  }

  func showPlaceholder(_ show: Bool) {
    UIView.animate(withDuration: 0.2) {
      self.placeholderLabel?.alpha = show ? 1 : 0
      self.placeholderLabel?.transform = show ? .identity : CGAffineTransform(translationX: 50, y: 0)
    }
  }
}

class ComposeView: UIView {
  static let minHeight: CGFloat = 46.0
  private let maxHeight: CGFloat = 300
  private var heightConstraint: NSLayoutConstraint!
  private var prevTextHeight: CGFloat = 0.0
  static let textViewVerticalPadding: CGFloat = 12.0
  static let textViewHorizantalPadding: CGFloat = 12.0
  private let buttonBottomPadding: CGFloat = -10.0
  private let buttonTrailingPadding: CGFloat = -10.0
  private let buttonSize: CGSize = .init(width: 28, height: 28)

  private lazy var textView: ComposeTextView = {
    let textView = ComposeTextView()
    textView.font = .systemFont(ofSize: 17)

    textView.isScrollEnabled = true
    textView.backgroundColor = .clear
    textView.textContainerInset = UIEdgeInsets(
      top: Self.textViewVerticalPadding, left: Self.textViewHorizantalPadding, bottom: Self.textViewVerticalPadding,
      right: Self.textViewHorizantalPadding
    )
    textView.delegate = self
    textView.translatesAutoresizingMaskIntoConstraints = false

    return textView
  }()

  private lazy var sendButton: UIButton = {
    let button = UIButton()
    button.translatesAutoresizingMaskIntoConstraints = false

    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "arrow.up")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    )
    config.baseForegroundColor = .white
    config.background.backgroundColor = .systemBlue
    config.cornerStyle = .capsule

    button.configuration = config
    button.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
    button.alpha = 0
    button.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
    return button
  }()

  var onSend: ((String) -> Bool)?
  var onHeightChange: ((CGFloat) -> Void)?
  var peerId: Peer?

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

    addSubview(textView)
    addSubview(sendButton)

    heightConstraint = heightAnchor.constraint(equalToConstant: Self.minHeight)

    NSLayoutConstraint.activate([
      heightConstraint,

      textView.leadingAnchor.constraint(equalTo: leadingAnchor),
      textView.topAnchor.constraint(equalTo: topAnchor),
      textView.bottomAnchor.constraint(equalTo: bottomAnchor),
      textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor),

      sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: buttonTrailingPadding),
      sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: buttonBottomPadding),
      sendButton.widthAnchor.constraint(equalToConstant: buttonSize.width),
      sendButton.heightAnchor.constraint(equalToConstant: buttonSize.height),

    ])
  }

  @objc private func sendTapped() {
    guard let text = textView.text?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty
    else { return }

    let messageText = text

    // Only clear states if send message was successful
    if let onSend = onSend, onSend(messageText) {
      sendMessageHaptic()
      textView.text = ""
      resetHeight()
      textView.showPlaceholder(true)
      buttonDisappear()
    }
  }

  func textViewHeightByContentHeight(_ contentHeight: CGFloat) -> CGFloat {
    let newHeight = min(maxHeight, max(Self.minHeight, contentHeight + Self.textViewVerticalPadding * 2))
    return newHeight
  }

  private func updateHeight() {
    let layoutManager = textView.layoutManager
    let textContainer = textView.textContainer

    // layoutManager.ensureLayout(for: textContainer)
    let contentHeight = layoutManager.usedRect(for: textContainer).height

    // Ignore small height changes
    if abs(prevTextHeight - contentHeight) < 8.0 {
      return
    }

    prevTextHeight = contentHeight

    let newHeight = textViewHeightByContentHeight(contentHeight)
    guard abs(heightConstraint.constant - newHeight) > 1 else { return }

    heightConstraint.constant = newHeight
    superview?.layoutIfNeeded()

    onHeightChange?(newHeight)
  }

  private func resetHeight() {
    UIView.animate(withDuration: 0.2) {
      self.heightConstraint.constant = Self.minHeight
      self.superview?.layoutIfNeeded()
    }
    onHeightChange?(Self.minHeight)
  }

  func buttonDisappear() {
    UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseIn) {
      self.sendButton.alpha = 0
      self.sendButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
    }
  }

  func buttonAppear() {
    UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
      self.sendButton.alpha = 1
      self.sendButton.transform = .identity
    }
  }

  func sendMessageHaptic() {
    let generator = UIImpactFeedbackGenerator(style: .medium)
    generator.prepare()
    generator.impactOccurred()
  }
}

extension ComposeView: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    UIView.animate(withDuration: 0.2) {
      self.updateHeight()
    }

    let isEmpty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    self.textView.showPlaceholder(isEmpty)

    if isEmpty {
      buttonDisappear()
      if let peerId = peerId {
        Task {
          await ComposeActions.shared.stoppedTyping(for: peerId)
        }
      }
    } else {
      if let peerId = peerId {
        Task {
          await ComposeActions.shared.startedTyping(for: peerId)
        }
      }
      buttonAppear()
    }
  }
}
