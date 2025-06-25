import InlineKit
import UIKit

// MARK: - ComposeContainer Protocol

protocol ComposeContainerDelegate: AnyObject {
  func composeContainer(_ container: ComposeContainer, didChangeHeight height: CGFloat)
  func composeContainer(_ container: ComposeContainer, didRequestSend text: String)
  func composeContainer(_ container: ComposeContainer, didRequestImagePicker: Void)
  func composeContainer(_ container: ComposeContainer, didRequestCamera: Void)
  func composeContainer(_ container: ComposeContainer, didReceiveImage image: UIImage)
}

// MARK: - ComposeContainer Base Class

class ComposeContainer: UIView {
  // MARK: - Configuration

  struct Configuration {
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let buttonSize: CGSize
    let textViewPadding: UIEdgeInsets
    let buttonSpacing: CGFloat
    let sendButtonStyle: ComposeButtonStyle
    let sendButtonAnimator: ComposeButtonAnimator
    let attachmentButtonStyle: ComposeButtonStyle
    let attachmentButtonAnimator: ComposeButtonAnimator

    static let `default` = Configuration(
      minHeight: 38.0,
      maxHeight: 350.0,
      buttonSize: CGSize(width: 32, height: 32),
      textViewPadding: UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12),
      buttonSpacing: 8.0,
      sendButtonStyle: DefaultSendButtonStyle(),
      sendButtonAnimator: SpringButtonAnimator(),
      attachmentButtonStyle: DefaultAttachmentButtonStyle(),
      attachmentButtonAnimator: SpringButtonAnimator()
    )

    static let minimal = Configuration(
      minHeight: 38.0,
      maxHeight: 350.0,
      buttonSize: CGSize(width: 32, height: 32),
      textViewPadding: UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12),
      buttonSpacing: 8.0,
      sendButtonStyle: MinimalSendButtonStyle(),
      sendButtonAnimator: FadeButtonAnimator(),
      attachmentButtonStyle: BorderedAttachmentButtonStyle(),
      attachmentButtonAnimator: FadeButtonAnimator()
    )

    static let rounded = Configuration(
      minHeight: 38.0,
      maxHeight: 350.0,
      buttonSize: CGSize(width: 32, height: 32),
      textViewPadding: UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12),
      buttonSpacing: 8.0,
      sendButtonStyle: RoundedSendButtonStyle(),
      sendButtonAnimator: SpringButtonAnimator(damping: 0.6, velocity: 0.8),
      attachmentButtonStyle: CircularAttachmentButtonStyle(),
      attachmentButtonAnimator: SlideButtonAnimator(direction: .left)
    )
  }

  // MARK: - Properties

  let configuration: Configuration
  weak var delegate: ComposeContainerDelegate?

  public var heightConstraint: NSLayoutConstraint!
  public var isButtonVisible = false

  var peerId: Peer?
  var chatId: Int64?

  // MARK: - UI Components

  lazy var textView: StandaloneComposeTextView = {
    let view = StandaloneComposeTextView(frame: .zero, textContainer: nil)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.delegate = self
    view.composeDelegate = self
    return view
  }()

  lazy var sendButton: UIButton = ComposeButtonFactory.createSendButton(
    style: configuration.sendButtonStyle,
    animator: configuration.sendButtonAnimator,
    target: self,
    action: #selector(sendTapped)
  )

  lazy var attachmentButton: UIButton = {
    let libraryAction = UIAction(
      title: "Photos",
      image: UIImage(systemName: "photo"),
      handler: { [weak self] _ in
        guard let self else { return }
        delegate?.composeContainer(self, didRequestImagePicker: ())
      }
    )

    let cameraAction = UIAction(
      title: "Camera",
      image: UIImage(systemName: "camera"),
      handler: { [weak self] _ in
        guard let self else { return }
        delegate?.composeContainer(self, didRequestCamera: ())
      }
    )

    let menu = UIMenu(children: [libraryAction, cameraAction])

    return ComposeButtonFactory.createAttachmentButton(
      style: configuration.attachmentButtonStyle,
      animator: configuration.attachmentButtonAnimator,
      menu: menu
    )
  }()

  // MARK: - Initialization

  init(configuration: Configuration = .default) {
    self.configuration = configuration
    super.init(frame: .zero)
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  public func setupViews() {
    backgroundColor = .clear

    addSubview(textView)
    addSubview(sendButton)
    addSubview(attachmentButton)

    heightConstraint = heightAnchor.constraint(equalToConstant: configuration.minHeight)
    heightConstraint.isActive = true

    setupLayout()
    setupInitialState()
  }

  // Override in subclasses for different layouts
  func setupLayout() {
    // Default horizontal layout - override in subclasses
    NSLayoutConstraint.activate([
      attachmentButton.leadingAnchor.constraint(equalTo: leadingAnchor),
      attachmentButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: -3),
      attachmentButton.widthAnchor.constraint(equalToConstant: configuration.buttonSize.width),
      attachmentButton.heightAnchor.constraint(equalToConstant: configuration.buttonSize.height),

      textView.leadingAnchor.constraint(
        equalTo: attachmentButton.trailingAnchor,
        constant: configuration.buttonSpacing
      ),
      textView.topAnchor.constraint(equalTo: topAnchor),
      textView.bottomAnchor.constraint(equalTo: bottomAnchor),
      textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -configuration.buttonSpacing),

      sendButton.trailingAnchor.constraint(equalTo: trailingAnchor),
      sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: -3),
      sendButton.widthAnchor.constraint(equalToConstant: configuration.buttonSize.width),
      sendButton.heightAnchor.constraint(equalToConstant: configuration.buttonSize.height),
    ])
  }

  public func setupInitialState() {
    sendButton.alpha = 0.0
    sendButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
  }

  // MARK: - Height Management

  func updateHeight() {
    let size = textView.sizeThatFits(CGSize(
      width: textView.bounds.width,
      height: .greatestFiniteMagnitude
    ))

    let contentHeight = size.height
    let newHeight = min(configuration.maxHeight, max(configuration.minHeight, contentHeight))

    guard abs(heightConstraint.constant - newHeight) > 1 else { return }

    heightConstraint.constant = newHeight
    superview?.layoutIfNeeded()

    DispatchQueue.main.async {
      let bottomRange = NSRange(location: self.textView.text.count, length: 0)
      self.textView.scrollRangeToVisible(bottomRange)
    }

    delegate?.composeContainer(self, didChangeHeight: newHeight)
  }

  public func resetHeight() {
    UIView.animate(withDuration: 0.2) {
      self.heightConstraint.constant = self.configuration.minHeight
      self.superview?.layoutIfNeeded()
    }
    delegate?.composeContainer(self, didChangeHeight: configuration.minHeight)
  }

  // MARK: - Button Animation

  func showSendButton() {
    guard !isButtonVisible else { return }
    isButtonVisible = true
    sendButton.animateAppearance()
  }

  func hideSendButton() {
    isButtonVisible = false
    sendButton.animateDisappearance()
  }

  // MARK: - Actions

  @objc public func sendTapped() {
    guard let text = textView.text?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else { return }

    delegate?.composeContainer(self, didRequestSend: text)

    textView.text = ""
    textView.showPlaceholder(true)
    resetHeight()
    hideSendButton()
  }

  // MARK: - Public Interface

  func setText(_ text: String) {
    textView.text = text
    textView.showPlaceholder(text.isEmpty)
    if !text.isEmpty {
      showSendButton()
    }
    updateHeight()
  }

  func clear() {
    textView.text = ""
    textView.showPlaceholder(true)
    resetHeight()
    hideSendButton()
  }
}

// MARK: - UITextViewDelegate

extension ComposeContainer: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    UIView.animate(withDuration: 0.1) { self.updateHeight() }

    let isEmpty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    (textView as? StandaloneComposeTextView)?.showPlaceholder(isEmpty)

    if isEmpty {
      hideSendButton()
    } else {
      showSendButton()
    }
  }
}

// MARK: - StandaloneComposeTextViewDelegate

extension ComposeContainer: StandaloneComposeTextViewDelegate {
  func composeTextViewDidChange(_ textView: StandaloneComposeTextView) {
    UIView.animate(withDuration: 0.1) { self.updateHeight() }

    let isEmpty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    textView.showPlaceholder(isEmpty)

    if isEmpty {
      hideSendButton()
    } else {
      showSendButton()
    }
  }

  func composeTextView(_ textView: StandaloneComposeTextView, didReceiveImage image: UIImage) {
    delegate?.composeContainer(self, didReceiveImage: image)
  }
}
