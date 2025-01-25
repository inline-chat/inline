import InlineKit
import PhotosUI
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
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ComposeView.textViewHorizantalPadding + 5),
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
  static let minHeight: CGFloat = 42.0
  private let maxHeight: CGFloat = 600
  private var heightConstraint: NSLayoutConstraint!
  private var prevTextHeight: CGFloat = 0.0
  static let textViewVerticalPadding: CGFloat = 10.0
  static let textViewHorizantalPadding: CGFloat = 34.0
  static let textViewHorizantalMargin: CGFloat = 7.0
  static let textViewVerticalMargin: CGFloat = 7.0
  private let buttonBottomPadding: CGFloat = -4.0
  private let buttonTrailingPadding: CGFloat = -6.0
  private let buttonLeadingPadding: CGFloat = 10.0
  private let buttonSize: CGSize = .init(width: 36, height: 36)
  private var overlayView: UIView?
  private var isOverlayVisible = false

  lazy var textView: ComposeTextView = {
    let textView = ComposeTextView()
    textView.font = .systemFont(ofSize: 17)

    textView.isScrollEnabled = true
    textView.backgroundColor = .systemBackground
    textView.layer.cornerRadius = 22
    textView.textContainerInset = UIEdgeInsets(
      top: Self.textViewVerticalPadding,
      left: Self.textViewHorizantalPadding + 2,
      bottom: Self.textViewVerticalPadding,
      right: Self.textViewHorizantalPadding + 5
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
      UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
    )
    config.baseForegroundColor = .white
    config.background.backgroundColor = ColorManager.shared.selectedColor
    config.cornerStyle = .capsule

    button.configuration = config
    button.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
    button.alpha = 0
    button.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)

    return button
  }()

  private var currentImagePickerPresenter: UIViewController?

  private lazy var plusButton: UIButton = {
    let button = UIButton()
    button.translatesAutoresizingMaskIntoConstraints = false

    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "plus")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    )
    config.baseForegroundColor = .systemGray2
    button.layer.cornerRadius = 18
    button.configuration = config
    button.addTarget(self, action: #selector(plusTapped), for: .touchUpInside)
    return button
  }()

  var onHeightChange: ((CGFloat) -> Void)?
  var peerId: Peer?
  var chatId: Int64?

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
    addSubview(plusButton)

    heightConstraint = heightAnchor.constraint(equalToConstant: Self.minHeight)

    NSLayoutConstraint.activate([
      heightConstraint,

      textView.leadingAnchor.constraint(equalTo: leadingAnchor),
      textView.topAnchor.constraint(equalTo: topAnchor),
      textView.bottomAnchor.constraint(equalTo: bottomAnchor),
      textView.trailingAnchor.constraint(equalTo: trailingAnchor),

      sendButton.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: buttonTrailingPadding),
      sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: buttonBottomPadding),
      //      sendButton.centerYAnchor.constraint(equalTo: textView.centerYAnchor),

      sendButton.widthAnchor.constraint(equalToConstant: buttonSize.width - 2),
      sendButton.heightAnchor.constraint(equalToConstant: buttonSize.height - 2),

      plusButton.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 6),
      plusButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
      plusButton.widthAnchor.constraint(equalToConstant: buttonSize.width),
      plusButton.heightAnchor.constraint(equalToConstant: buttonSize.height),
    ])
  }

  @objc private func sendTapped() {
    guard let peerId else { return }

    guard let text = textView.text?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty
    else { return }

    let messageText = text

    let replyToMessageId = ChatState.shared.getState(peer: peerId).replyingMessageId
    let canSend = !text.isEmpty

    if canSend {
      let _ = Transactions.shared.mutate(
        transaction:
        .sendMessage(
          .init(text: text, peerId: peerId, chatId: chatId ?? 0, replyToMessageId: replyToMessageId)
        )
      )

      ChatState.shared.clearReplyingMessageId(peer: peerId)
      sendMessageHaptic()
      textView.text = ""
      resetHeight()
      textView.showPlaceholder(true)
      buttonDisappear()
    }
  }

  @objc private func plusTapped() {
    guard let windowScene = window?.windowScene else { return }

    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .images
    configuration.selectionLimit = 1

    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self

    let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow })
    let rootVC = keyWindow?.rootViewController
    rootVC?.present(picker, animated: true)
  }

  @objc private func handleTapOutside(_ gesture: UITapGestureRecognizer) {
    let location = gesture.location(in: self)
    if let overlayView,
       !overlayView.frame.contains(location), !plusButton.frame.contains(location)
    {
      dismissOverlay()
    }
  }

  private func dismissOverlay() {
    guard isOverlayVisible, let overlay = overlayView else { return }

    UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseIn) {
      overlay.alpha = 0
      overlay.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        .concatenating(CGAffineTransform(translationX: 0, y: 10))
      self.plusButton.backgroundColor = .clear
    } completion: { _ in
      overlay.removeFromSuperview()
      self.overlayView = nil
      self.isOverlayVisible = false
      self.gestureRecognizers?.removeAll()
    }
  }

  override func resignFirstResponder() -> Bool {
    dismissOverlay()
    return super.resignFirstResponder()
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
    UIView.animate(withDuration: 0.06, delay: 0, options: .curveEaseIn) {
      self.sendButton.alpha = 0
      self.sendButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
    }
  }

  func buttonAppear() {
    UIView.animate(withDuration: 0.06, delay: 0, options: .curveEaseOut) {
      self.sendButton.alpha = 1
      self.sendButton.transform = .identity
    }
  }

  func sendMessageHaptic() {
    let generator = UIImpactFeedbackGenerator(style: .medium)
    generator.prepare()
    generator.impactOccurred()
  }

  override func removeFromSuperview() {
    if let text = textView.text {
      guard let peerId else { return }
      Task {
        do {
          try await DataManager.shared.updateDialog(peerId: peerId, draft: text.isEmpty ? nil : text)
        } catch {
          print("Failed to save draft", error)
        }
      }
    }
    super.removeFromSuperview()
  }

  func setDraft(_ draft: String?) {
    if let draft, !draft.isEmpty {
      textView.text = draft
      textView.showPlaceholder(false)
      buttonAppear()
      updateHeight()
    }
  }

  func loadDraft() {
    guard let peerId else { return }
    Task {
      do {
        if let draft = try await DataManager.shared.getDraft(peerId: peerId) {
          setDraft(draft)
        }
      } catch {
        print("Failed to load draft", error)
      }
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      loadDraft()
    }
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
      if let peerId {
        Task {
          await ComposeActions.shared.stoppedTyping(for: peerId)
        }
      }
    } else {
      if let peerId {
        Task {
          await ComposeActions.shared.startedTyping(for: peerId)
        }
      }
      buttonAppear()
    }
  }
}

extension ComposeView: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)

    guard let result = results.first else { return }

    result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
      guard let self else { return }

      if let error {
        print("Failed to load image:", error.localizedDescription)
        return
      }

      guard let image = object as? UIImage,
            let peerId
      else { return }

      DispatchQueue.main.async {
        self.sendButton.configuration?.showsActivityIndicator = true
        print("I HAVE AN IMAGE")
        self.sendButton.configuration?.showsActivityIndicator = false
        self.sendMessageHaptic()
      }
    }
  }
}
