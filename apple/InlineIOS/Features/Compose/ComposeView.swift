import AVFoundation
import Combine
import CoreServices
import ImageIO
import InlineKit
import InlineProtocol
import InlineUI
import Logger
import MobileCoreServices
import PhotosUI
import SwiftUI
import TextProcessing
import UIKit
import UniformTypeIdentifiers

class ComposeView: UIView, NSTextLayoutManagerDelegate {
  // MARK: - Configuration Constants

  private let log = Log.scoped("ComposeView")

  let maxHeight: CGFloat = 350
  let buttonSize: CGSize = .init(width: 32, height: 32)
  let linkColor: UIColor = ThemeManager.shared.selected.accent

  static let minHeight: CGFloat = 38.0
  static let textViewVerticalPadding: CGFloat = 0.0
  static let textViewHorizantalPadding: CGFloat = 12.0
  static let textViewHorizantalMargin: CGFloat = 7.0
  static let textViewVerticalMargin: CGFloat = 4.0

  // MARK: - Properties

  var composeHeightConstraint: NSLayoutConstraint!
  var prevTextHeight: CGFloat = 0.0
  var overlayView: UIView?
  var isOverlayVisible = false
  var phaseObserver: AnyCancellable?

  let buttonBottomPadding: CGFloat = -4.0
  let buttonTrailingPadding: CGFloat = -6.0
  let buttonLeadingPadding: CGFloat = 10.0

  // MARK: - State Management

  var isButtonVisible = false
  var selectedImage: UIImage?
  var showingPhotoPreview: Bool = false
  var imageCaption: String = ""

  var attachmentItems: [String: FileMediaItem] = [:]

  var canSend: Bool {
    let hasText = !(textView.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    let hasAttachments = !attachmentItems.isEmpty
    return hasText || hasAttachments
  }

  var onHeightChange: ((CGFloat) -> Void)?
  var peerId: InlineKit.Peer?
  var chatId: Int64?
  var mentionManager: MentionManager?
  var draftSaveTimer: Timer?
  var originalDraftEntities: MessageEntities?

  let previewViewModel = SwiftUIPhotoPreviewViewModel()
  let multiPhotoPreviewViewModel = SwiftUIPhotoPreviewViewModel()
  let draftSaveInterval: TimeInterval = 2.0 // Save every 2 seconds
  var isPickerPresented = false

  // MARK: - UI Components

  lazy var textView = makeTextView()
  lazy var sendButton = makeSendButton()
  lazy var plusButton = makePlusButton()

  // MARK: - Initialization

  deinit {
    stopDraftSaveTimer()
    removeObservers()
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
    setupScenePhaseObserver()
    setupChatStateObservers()
    setupStickerObserver()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc func handleStickerDetected(_ notification: Notification) {
    if UIPasteboard.general.image != nil {
      handlePastedImage()
    } else {
      if let image = notification.userInfo?["image"] as? UIImage {
        // Ensure we're on the main thread
        DispatchQueue.main.async(qos: .userInitiated) { [weak self] in
          self?.sendSticker(image)
        }
      }
    }
  }

  // MARK: - View Lifecycle

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      setupMentionManager()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    // Update height after layout if text view now has proper bounds and there's text
    if textView.bounds.width > 0, !(textView.text?.isEmpty ?? true) {
      updateHeight()
    }
  }

  override func removeFromSuperview() {
    saveDraft()
    stopDraftSaveTimer()
    resetMentionManager()
    super.removeFromSuperview()
  }

  func resetMentionManager() {
    mentionManager?.cleanup()
    mentionManager = nil
  }

  override func resignFirstResponder() -> Bool {
    dismissOverlay()
    return super.resignFirstResponder()
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

  public func sendSticker(_ image: UIImage) {
    guard let peerId else {
      log.debug("No peerId available")
      return
    }

    Task.detached(priority: .userInitiated) {
      let photoInfo = try FileCache.savePhoto(image: image, optimize: true)
      let mediaItem = FileMediaItem.photo(photoInfo)

      await Transactions.shared.mutate(
        transaction: .sendMessage(
          .init(
            text: nil,
            peerId: peerId,
            chatId: self.chatId ?? 0,
            mediaItems: [mediaItem],
            replyToMsgId: ChatState.shared.getState(peer: peerId).replyingMessageId,
            isSticker: true
          )
        )
      )
    }

    ChatState.shared.clearEditingMessageId(peer: peerId)
    ChatState.shared.clearReplyingMessageId(peer: peerId)

    resetComposeState()
  }

  func setupViews() {
    clearBackground()

    addSubview(textView)
    addSubview(sendButton)
    addSubview(plusButton)

    setupInitialHeight()
    setupConstraints()
    addDropInteraction()
  }

  func clearBackground() {
    backgroundColor = .clear
  }

  func setupInitialHeight() {
    composeHeightConstraint = heightAnchor.constraint(equalToConstant: Self.minHeight)
  }

  func addDropInteraction() {
    let dropInteraction = UIDropInteraction(delegate: self)
    addInteraction(dropInteraction)
  }

  func setupConstraints() {
    NSLayoutConstraint.activate([
      composeHeightConstraint,

      plusButton.leadingAnchor.constraint(equalTo: leadingAnchor),
      plusButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: buttonBottomPadding),
      plusButton.widthAnchor.constraint(equalToConstant: buttonSize.width),
      plusButton.heightAnchor.constraint(equalToConstant: buttonSize.height),

      textView.leadingAnchor.constraint(equalTo: plusButton.trailingAnchor, constant: 8),
      textView.topAnchor.constraint(equalTo: topAnchor),
      textView.bottomAnchor.constraint(equalTo: bottomAnchor),

      textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -12),

      sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
      sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: buttonBottomPadding),
      sendButton.widthAnchor.constraint(equalToConstant: buttonSize.width),
      sendButton.heightAnchor.constraint(equalToConstant: buttonSize.height),
    ])
  }

  func buttonDisappear() {
    print("buttonDisappear")
    isButtonVisible = false
    UIView.animate(withDuration: 0.12, delay: 0.1, options: [.curveEaseOut, .allowUserInteraction]) {
      self.sendButton.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
      self.sendButton.alpha = 0
    }
  }

  func buttonAppear() {
    print("buttonAppear")
    guard !isButtonVisible else { return }
    isButtonVisible = true
    sendButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
    sendButton.alpha = 0.0
    layoutIfNeeded()
    UIView.animate(
      withDuration: 0.21,
      delay: 0,
      usingSpringWithDamping: 0.8,
      initialSpringVelocity: 0.5,
      options: .curveEaseOut
    ) {
      // self.sendButtonContainer.alpha = 1
      // self.sendButtonContainer.transform = .identity
      self.sendButton.transform = .identity
      self.sendButton.alpha = 1
    } completion: { _ in
    }
  }

  @objc func sendTapped() {
    sendMessage()
  }

  func sendMessage() {
    guard let peerId else { return }
    let state = ChatState.shared.getState(peer: peerId)
    let isEditing = state.editingMessageId != nil
    guard let chatId else { return }

    let rawText = textView.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let hasText = !rawText.isEmpty
    let hasAttachments = !attachmentItems.isEmpty

    // Can't send if no text and no attachments
    guard hasText || hasAttachments else { return }

    // Extract all entities using TextProcessing module
    let attributedText = textView.attributedText ?? NSAttributedString()
    let (_, extractedEntities) = ProcessEntities.fromAttributedString(attributedText)

    let entities = if extractedEntities.entities.isEmpty {
      nil as MessageEntities?
    } else {
      extractedEntities
    }

    // Make text nil if empty and we have attachments
    let text = if rawText.isEmpty, hasAttachments {
      nil as String?
    } else {
      rawText
    }

    if isEditing {
      Transactions.shared.mutate(transaction: .editMessage(.init(
        messageId: state.editingMessageId ?? 0,
        text: text ?? "",
        chatId: chatId,
        peerId: peerId,
        entities: entities
      )))

      ChatState.shared.clearEditingMessageId(peer: peerId)
    } else {
      let replyToMessageId = state.replyingMessageId

      if attachmentItems.isEmpty {
        Transactions.shared.mutate(transaction: .sendMessage(.init(
          text: text,
          peerId: peerId,
          chatId: chatId,
          mediaItems: [],
          replyToMsgId: replyToMessageId,
          isSticker: nil,
          entities: entities
        )))
      } else {
        for (index, (_, attachment)) in attachmentItems.enumerated() {
          log.debug("Sending attachment: \(attachment)")
          let isFirst = index == 0

          // Verify attachment has valid local path before sending
          guard attachment.getLocalPath() != nil else {
            log.error("Attachment has no local path, skipping: \(attachment)")
            continue
          }

          Transactions.shared.mutate(transaction: .sendMessage(.init(
            text: isFirst ? text : nil,
            peerId: peerId,
            chatId: chatId,
            mediaItems: [attachment],
            replyToMsgId: isFirst ? replyToMessageId : nil,
            isSticker: nil,
            entities: isFirst ? entities : nil
          )))
        }
      }

      ChatState.shared.clearReplyingMessageId(peer: peerId)
    }

    // Clear everything
    resetComposeState()
  }

  func updateSendButtonForEditing(_ isEditing: Bool) {
    let imageName = isEditing ? "checkmark" : "arrow.up"
    sendButton.configuration?.image = UIImage(systemName: imageName)?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
    )
  }

  func setupScenePhaseObserver() {
    NotificationCenter.default.removeObserver(self)

    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.saveCurrentDraft()
    }

    NotificationCenter.default.addObserver(
      forName: UIApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.saveCurrentDraft()
    }

    NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.saveCurrentDraft()
    }
  }

  func setupChatStateObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleEditingStateChange),
      name: .init("ChatStateSetEditingCalled"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleEditingStateChange),
      name: .init("ChatStateClearEditingCalled"),
      object: nil
    )
  }

  func setupStickerObserver() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleStickerDetected(_:)),
      name: NSNotification.Name("StickerDetected"),
      object: nil
    )
  }

  @objc func handleEditingStateChange() {
    guard let peerId, let chatId else { return }
    let isEditing = ChatState.shared.getState(peer: peerId).editingMessageId != nil
    updateSendButtonForEditing(isEditing)

    if isEditing {
      // Stop draft timer when editing a message
      stopDraftSaveTimer()

      if let messageId = ChatState.shared.getState(peer: peerId).editingMessageId,
         let message = try? FullMessage.get(messageId: messageId, chatId: chatId)
      {
        // Set attributed text with entities to preserve mentions and formatting
        if let text = message.message.text {
          let configuration = ProcessEntities.Configuration(
            font: .systemFont(ofSize: 17),
            textColor: .label,
            linkColor: linkColor,
            convertMentionsToLink: false // Keep as attributes for editing
          )

          let attributedText = ProcessEntities.toAttributedString(
            text: text,
            entities: message.message.entities,
            configuration: configuration
          )

          textView.attributedText = attributedText
        } else {
          textView.text = ""
        }

        textView.showPlaceholder(false)
        buttonAppear()
        DispatchQueue.main.async { [weak self] in
          self?.updateHeight()
        }
      }
    } else {
      // Resume draft timer when exiting edit mode if there's text
      if let text = textView.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        startDraftSaveTimer()
      }
    }

    updateHeight()
  }

  func removeObservers() {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Reset Methods

  /// Resets text view typing attributes and related state
  func resetTextViewState() {
    textView.resetTypingAttributesToDefault()

    DispatchQueue.main.async { [weak self] in
      self?.textView.updateTypingAttributesIfNeeded()
    }
  }

  private func resetComposeState() {
    clearDraft()
    clearAttachments()
    stopDraftSaveTimer()
    textView.text = ""

    resetTextViewState()

    resetHeight()
    textView.showPlaceholder(true)
    buttonDisappear()

    sendButton.configuration?.showsActivityIndicator = false
  }

  // MARK: - Attachment Management

  func removeAttachment(_ id: String) {
    // TODO: Delete from cache as well

    // Update state
    attachmentItems.removeValue(forKey: id)
    updateSendButtonVisibility()

    log.debug("Removed attachment with id: \(id)")
  }

  func removeImage(_ id: String) {
    removeAttachment(id)
  }

  func removeFile(_ id: String) {
    removeAttachment(id)
  }

  func clearAttachments() {
    attachmentItems.removeAll()
    updateSendButtonVisibility()
    log.debug("Cleared all attachments")
  }

  func updateSendButtonVisibility() {
    if canSend {
      buttonAppear()
    } else {
      buttonDisappear()
    }
  }
}
