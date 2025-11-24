import AVFoundation
import Combine
import CoreServices
import ImageIO
import InlineKit
import InlineProtocol
import Logger
import MobileCoreServices
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

class LiquidGlassComposeView: UIView {
  // MARK: - Configuration Constants

  static let minHeight: CGFloat = 44.0
  private let maxHeight: CGFloat = 350
  private let buttonSize: CGSize = .init(width: 36, height: 36)
  static let textViewVerticalPadding: CGFloat = 8.0
  static let textViewHorizontalPadding: CGFloat = 16.0
  static let capsuleCornerRadius: CGFloat = 22.0

  // MARK: - Private Properties

  private var composeHeightConstraint: NSLayoutConstraint!
  private var prevTextHeight: CGFloat = 0.0
  private let buttonSpacing: CGFloat = 12.0
  private let buttonContainerPadding: CGFloat = 8.0
  private var overlayView: UIView?
  private var isOverlayVisible = false
  private var phaseObserver: AnyCancellable?

  // MARK: - State Management

  private var isButtonVisible = false
  var selectedImage: UIImage?
  var showingPhotoPreview: Bool = false
  var imageCaption: String = ""
  let previewViewModel = SwiftUIPhotoPreviewViewModel()
  var attachmentItems: [UIImage: FileMediaItem] = [:]

  var onHeightChange: ((CGFloat) -> Void)?
  var peerId: InlineKit.Peer?
  var chatId: Int64?

  // Mention functionality
  private var mentionManager: MentionManager?

  // Draft auto-save timer
  private var draftSaveTimer: Timer?
  private let draftSaveInterval: TimeInterval = 2.0

  // Track original draft entities
  private var originalDraftEntities: MessageEntities?

  // MARK: - UI Components

  // Main container with glass effect
  private lazy var liquidGlassContainer: UIView = {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.layer.cornerRadius = Self.capsuleCornerRadius
    container.layer.cornerCurve = .continuous
    container.clipsToBounds = true
    return container
  }()

  // Simple glass blur effect using standard UIKit
  private lazy var glassBlurView: UIVisualEffectView = {
    let effect = UIBlurEffect(style: .systemMaterial)
    let view = UIVisualEffectView(effect: effect)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.layer.cornerRadius = Self.capsuleCornerRadius
    view.layer.cornerCurve = .continuous
    view.clipsToBounds = true
    return view
  }()

  // Text view container
  private lazy var textViewContainer: UIView = {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.backgroundColor = .clear
    return container
  }()

  lazy var textView: UITextView = {
    let view = UITextView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.delegate = self
    view.backgroundColor = .clear
    view.layer.cornerRadius = Self.capsuleCornerRadius - 4
    view.layer.cornerCurve = .continuous
    view.font = .systemFont(ofSize: 17)
    view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    return view
  }()

  // External button container (outside the glass capsule)
  private lazy var buttonContainer: UIView = {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.backgroundColor = .clear
    return container
  }()

  // Send button with glass effect
  lazy var sendButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false

    // Configure button appearance
    let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
    button.setImage(UIImage(systemName: "arrow.up", withConfiguration: config), for: .normal)
    button.tintColor = .white
    button.backgroundColor = ThemeManager.shared.selected.accent
    button.layer.cornerRadius = buttonSize.width / 2
    button.layer.cornerCurve = .continuous

    // Add subtle shadow
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOffset = CGSize(width: 0, height: 2)
    button.layer.shadowRadius = 8
    button.layer.shadowOpacity = 0.15

    button.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
    button.addTarget(self, action: #selector(handleTouchDown), for: .touchDown)
    button.addTarget(self, action: #selector(handleTouchUp), for: [.touchUpOutside, .touchCancel])
    button.alpha = 0
    button.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)

    return button
  }()

  // Plus button with glass effect
  lazy var plusButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false

    // Configure button appearance
    let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
    button.setImage(UIImage(systemName: "plus", withConfiguration: config), for: .normal)
    button.tintColor = ThemeManager.shared.selected.accent
    button.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.1)
    button.layer.cornerRadius = buttonSize.width / 2
    button.layer.cornerCurve = .continuous

    // Add subtle border
    button.layer.borderWidth = 1
    button.layer.borderColor = UIColor.separator.withAlphaComponent(0.3).cgColor

    button.addTarget(self, action: #selector(plusTapped), for: .touchUpInside)

    return button
  }()

  // MARK: - Initialization

  deinit {
    NotificationCenter.default.removeObserver(self)
    stopDraftSaveTimer()
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
    setupConstraints()
    setupScenePhaseObserver()
    setupChatStateObservers()

    // Add observer for sticker notifications
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleStickerDetected(_:)),
      name: NSNotification.Name("StickerDetected"),
      object: nil
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func handleStickerDetected(_ notification: Notification) {
    if UIPasteboard.general.image != nil {
      handlePastedImage()
    } else {
      if let image = notification.userInfo?["image"] as? UIImage {
        DispatchQueue.main.async(qos: .userInitiated) { [weak self] in
          self?.sendSticker(image)
        }
      }
    }
  }

  // MARK: - View Setup

  private func setupViews() {
    backgroundColor = .clear
    translatesAutoresizingMaskIntoConstraints = false

    // Add main components
    addSubview(liquidGlassContainer)
    addSubview(buttonContainer)

    // Setup liquid glass container
    liquidGlassContainer.addSubview(glassBlurView)
    liquidGlassContainer.addSubview(textViewContainer)

    // Add text view to container
    textViewContainer.addSubview(textView)

    // Add buttons to external container
    buttonContainer.addSubview(plusButton)
    buttonContainer.addSubview(sendButton)
  }

  private func setupConstraints() {
    composeHeightConstraint = heightAnchor.constraint(equalToConstant: Self.minHeight)

    NSLayoutConstraint.activate([
      // Main height constraint
      composeHeightConstraint,

      // Liquid glass container
      liquidGlassContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
      liquidGlassContainer.topAnchor.constraint(equalTo: topAnchor),
      liquidGlassContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
      liquidGlassContainer.trailingAnchor.constraint(equalTo: buttonContainer.leadingAnchor, constant: -buttonSpacing),

      // Button container
      buttonContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
      buttonContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
      buttonContainer.widthAnchor.constraint(equalToConstant: buttonSize.width * 2 + buttonSpacing),
      buttonContainer.heightAnchor.constraint(equalToConstant: buttonSize.height),

      // Glass blur view
      glassBlurView.topAnchor.constraint(equalTo: liquidGlassContainer.topAnchor),
      glassBlurView.leadingAnchor.constraint(equalTo: liquidGlassContainer.leadingAnchor),
      glassBlurView.trailingAnchor.constraint(equalTo: liquidGlassContainer.trailingAnchor),
      glassBlurView.bottomAnchor.constraint(equalTo: liquidGlassContainer.bottomAnchor),

      // Text view container
      textViewContainer.topAnchor.constraint(equalTo: liquidGlassContainer.topAnchor, constant: 4),
      textViewContainer.leadingAnchor.constraint(equalTo: liquidGlassContainer.leadingAnchor, constant: 4),
      textViewContainer.trailingAnchor.constraint(equalTo: liquidGlassContainer.trailingAnchor, constant: -4),
      textViewContainer.bottomAnchor.constraint(equalTo: liquidGlassContainer.bottomAnchor, constant: -4),

      // Text view
      textView.topAnchor.constraint(equalTo: textViewContainer.topAnchor, constant: Self.textViewVerticalPadding),
      textView.leadingAnchor.constraint(
        equalTo: textViewContainer.leadingAnchor,
        constant: Self.textViewHorizontalPadding
      ),
      textView.trailingAnchor.constraint(
        equalTo: textViewContainer.trailingAnchor,
        constant: -Self.textViewHorizontalPadding
      ),
      textView.bottomAnchor.constraint(
        equalTo: textViewContainer.bottomAnchor,
        constant: -Self.textViewVerticalPadding
      ),

      // Plus button
      plusButton.leadingAnchor.constraint(equalTo: buttonContainer.leadingAnchor),
      plusButton.centerYAnchor.constraint(equalTo: buttonContainer.centerYAnchor),
      plusButton.widthAnchor.constraint(equalToConstant: buttonSize.width),
      plusButton.heightAnchor.constraint(equalToConstant: buttonSize.height),

      // Send button
      sendButton.trailingAnchor.constraint(equalTo: buttonContainer.trailingAnchor),
      sendButton.centerYAnchor.constraint(equalTo: buttonContainer.centerYAnchor),
      sendButton.widthAnchor.constraint(equalToConstant: buttonSize.width),
      sendButton.heightAnchor.constraint(equalToConstant: buttonSize.height),
    ])
  }

  // MARK: - Button Actions

  @objc private func sendTapped() {
    guard !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachmentItems.isEmpty else {
      return
    }

    // Add haptic feedback
    let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    impactFeedback.impactOccurred()

    // Animate button press
    UIView.animate(withDuration: 0.1, animations: {
      self.sendButton.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
    }) { _ in
      UIView.animate(withDuration: 0.1) {
        self.sendButton.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
      }
    }

    // Send message logic would go here
    print("Send message: \(textView.text ?? "")")

    // Clear text and hide send button
    textView.text = ""
    hideSendButton()
    updateHeight()
  }

  @objc private func plusTapped() {
    // Add haptic feedback
    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    impactFeedback.impactOccurred()

    // Show attachment options
    print("Plus button tapped - show attachment options")
  }

  @objc private func handleTouchDown() {
    UIView.animate(withDuration: 0.1) {
      self.sendButton.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
    }
  }

  @objc private func handleTouchUp() {
    UIView.animate(withDuration: 0.1) {
      self.sendButton.transform = self.isButtonVisible ? .identity : CGAffineTransform(scaleX: 0.8, y: 0.8)
    }
  }

  // MARK: - Button Visibility

  private func showSendButton() {
    guard !isButtonVisible else { return }
    isButtonVisible = true

    UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
      self.sendButton.alpha = 1.0
      self.sendButton.transform = .identity
    }
  }

  private func hideSendButton() {
    guard isButtonVisible else { return }
    isButtonVisible = false

    UIView.animate(withDuration: 0.2) {
      self.sendButton.alpha = 0.0
      self.sendButton.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
    }
  }

  // MARK: - Height Management

  private func updateHeight() {
    let textHeight = textView.sizeThatFits(CGSize(width: textView.frame.width, height: CGFloat.greatestFiniteMagnitude))
      .height
    let clampedTextHeight = min(
      max(textHeight, Self.minHeight - Self.textViewVerticalPadding * 2),
      maxHeight - Self.textViewVerticalPadding * 2
    )
    let newHeight = clampedTextHeight + Self.textViewVerticalPadding * 2 + 8 // Extra padding for container

    guard abs(newHeight - composeHeightConstraint.constant) > 1 else { return }

    composeHeightConstraint.constant = newHeight
    onHeightChange?(newHeight)

    UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
      self.superview?.layoutIfNeeded()
    }
  }

  // MARK: - Placeholder Methods (to be implemented)

  private func setupScenePhaseObserver() {
    // Implementation for scene phase observation
  }

  private func setupChatStateObservers() {
    // Implementation for chat state observation
  }

  private func stopDraftSaveTimer() {
    draftSaveTimer?.invalidate()
    draftSaveTimer = nil
  }

  private func handlePastedImage() {
    // Implementation for handling pasted images
  }

  private func sendSticker(_ image: UIImage) {
    // Implementation for sending stickers
  }
}

// MARK: - UITextViewDelegate

extension LiquidGlassComposeView: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    let isEmpty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    if isEmpty {
      hideSendButton()
    } else {
      showSendButton()
    }

    updateHeight()
  }

  func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
    // Handle return key for sending
    if text == "\n", UIDevice.current.userInterfaceIdiom != .pad {
      sendTapped()
      return false
    }
    return true
  }
}
