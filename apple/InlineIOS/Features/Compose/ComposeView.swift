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
import QuickLook
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
  private let telegramSendButtonShowDuration: TimeInterval = 0.2
  private let telegramSendButtonHideDuration: TimeInterval = 0.14
  private let telegramSendButtonBlurDuration: TimeInterval = 0.18
  private let telegramSendButtonBlurRadius: CGFloat = 4.0

  static let minHeight: CGFloat = 46.0
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

  enum MediaPickerMode {
    case photos
    case videos
  }

  struct PendingVideoAttachment {
    let id: String
    var thumbnailImage: UIImage?
  }

  var attachmentItems: [String: FileMediaItem] = [:]
  var pendingVideoAttachments: [PendingVideoAttachment] = []
  var canceledPendingVideoAttachmentIds: Set<String> = []
  private var isAwaitingPendingVideoSend = false
  private var queuedPendingVideoSendMode: MessageSendMode?
  private var attachmentUploadProgress: [String: UploadProgressSnapshot] = [:]
  private var attachmentUploadSubscriptions: [String: AnyCancellable] = [:]
  private var attachmentUploadBindingTasks: [String: Task<Void, Never>] = [:]
  private var attachmentUploadStartTasks: [String: Task<Void, Never>] = [:]
  private var quickLookPreviewURL: URL?
  private var documentInteractionController: UIDocumentInteractionController?

  private var hasActiveAttachmentUploads: Bool {
    for attachmentId in attachmentItems.keys {
      guard let progress = attachmentUploadProgress[attachmentId] else {
        return true
      }

      if progress.stage == .processing || progress.stage == .uploading {
        return true
      }
    }

    return false
  }

  var canSend: Bool {
    let normalizedText = (textView.text ?? "").replacingOccurrences(of: "\u{FFFC}", with: "")
    let hasText = !normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasAttachments = !attachmentItems.isEmpty
    let hasForward = peerId.map { ChatState.shared.getState(peer: $0).forwardContext != nil } ?? false
    let hasPendingVideos = !pendingVideoAttachments.isEmpty
    return ComposeSendEligibility.canSend(
      hasText: hasText,
      hasAttachments: hasAttachments,
      hasForward: hasForward,
      hasPendingVideos: hasPendingVideos,
      hasActiveAttachmentUploads: hasActiveAttachmentUploads
    )
  }

  var onHeightChange: ((CGFloat) -> Void)?
  var peerId: InlineKit.Peer? {
    didSet {
      updateEmbedState(animated: false)
    }
  }
  var chatId: Int64? {
    didSet {
      updateEmbedState(animated: false)
    }
  }
  var mentionManager: MentionManager?
  var slashCommandManager: SlashCommandManager?
  var draftSaveTimer: Timer?
  var originalDraftEntities: MessageEntities?

  let previewViewModel = SwiftUIPhotoPreviewViewModel()
  let multiPhotoPreviewViewModel = SwiftUIPhotoPreviewViewModel()
  let draftSaveInterval: TimeInterval = 2.0 // Save every 2 seconds
  var isPickerPresented = false
  var activePickerMode: MediaPickerMode = .photos
  var currentPreviewUsesAttachmentPicker = false
  weak var attachmentPickerViewController: UIViewController?

  // MARK: - UI Components

  lazy var textView = makeTextView()
  lazy var sendButton = makeSendButton()
  lazy var plusButton = makePlusButton()
  lazy var composeAndButtonContainer = makeComposeAndButtonContainer()
  lazy var attachmentScrollView = makeAttachmentScrollView()
  lazy var attachmentStackView = makeAttachmentStackView()
  private lazy var embedContainerView = makeEmbedContainerView()
  var embedContainerHeightConstraint: NSLayoutConstraint?
  var attachmentContainerHeightConstraint: NSLayoutConstraint?
  private var embedView: ComposeEmbedView?
  private var currentEmbedMessageId: Int64?
  private var currentEmbedMode: ComposeEmbedViewContent.Mode?
  private var currentEmbedMessageChatId: Int64?

  // MARK: - Initialization

  deinit {
    stopDraftSaveTimer()
    clearAttachmentUploadTracking(cancelUploads: true)
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
      setupSlashCommandManager()
      layoutIfNeeded()
      let hasEmbed = (embedContainerHeightConstraint?.constant ?? 0) > 0
      if hasEmbed || !attachmentItems.isEmpty || !pendingVideoAttachments.isEmpty || !(textView.text?.isEmpty ?? true) {
        updateHeight()
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let hasEmbed = (embedContainerHeightConstraint?.constant ?? 0) > 0

    // Update height after layout if text view now has proper bounds and there's text, attachments, or an embed
    if textView.bounds.width > 0, hasEmbed || !attachmentItems.isEmpty || !pendingVideoAttachments.isEmpty || !(textView.text?.isEmpty ?? true) {
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
    slashCommandManager?.cleanup()
    slashCommandManager = nil
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

  func sendSticker(_ image: UIImage) {
    guard let peerId else {
      log.debug("No peerId available")
      return
    }

    Task.detached(priority: .userInitiated) { @MainActor in
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

  func sendMediaItemImmediately(_ mediaItem: FileMediaItem) {
    guard let peerId else {
      log.debug("No peerId available for immediate media send")
      return
    }

    Transactions.shared.mutate(
      transaction: .sendMessage(
        .init(
          text: nil,
          peerId: peerId,
          chatId: chatId ?? 0,
          mediaItems: [mediaItem],
          replyToMsgId: ChatState.shared.getState(peer: peerId).replyingMessageId,
          isSticker: nil,
          entities: nil
        )
      )
    )

    ChatState.shared.clearReplyingMessageId(peer: peerId)
  }

  func setupViews() {
    clearBackground()

    addSubview(plusButton)
    addSubview(composeAndButtonContainer)

    // Add embed container, textView, and sendButton to the container
    composeAndButtonContainer.addSubview(embedContainerView)
    composeAndButtonContainer.addSubview(attachmentScrollView)
    attachmentScrollView.addSubview(attachmentStackView)
    composeAndButtonContainer.addSubview(textView)
    composeAndButtonContainer.addSubview(sendButton)

    setupInitialHeight()
    setupConstraints()
    addDropInteraction()
    refreshAttachmentPreviews()
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
    let embedHeightConstraint = embedContainerView.heightAnchor
      .constraint(equalToConstant: 0)
    let attachmentHeightConstraint = attachmentScrollView.heightAnchor
      .constraint(equalToConstant: 0)
    embedContainerHeightConstraint = embedHeightConstraint
    attachmentContainerHeightConstraint = attachmentHeightConstraint

    NSLayoutConstraint.activate([
      composeHeightConstraint,

      plusButton.leadingAnchor.constraint(equalTo: leadingAnchor),
      plusButton.bottomAnchor.constraint(
        equalTo: bottomAnchor,
        constant: buttonBottomPadding
      ),
      plusButton.widthAnchor.constraint(equalToConstant: buttonSize.width + 10),
      plusButton.heightAnchor.constraint(equalToConstant: buttonSize.height + 10),

      // Container constraints
      composeAndButtonContainer.leadingAnchor.constraint(equalTo: plusButton.trailingAnchor, constant: 8),
      composeAndButtonContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
      composeAndButtonContainer.topAnchor.constraint(equalTo: topAnchor),
      composeAndButtonContainer.bottomAnchor.constraint(
        equalTo: bottomAnchor,
        constant: buttonBottomPadding
      ),

      // Embed constraints within container
      embedContainerView.leadingAnchor.constraint(equalTo: composeAndButtonContainer.leadingAnchor, constant: 8),
      embedContainerView.trailingAnchor.constraint(equalTo: composeAndButtonContainer.trailingAnchor, constant: -8),
      embedContainerView.topAnchor.constraint(equalTo: composeAndButtonContainer.topAnchor),
      embedHeightConstraint,

      // Attachment strip within container
      attachmentScrollView.leadingAnchor.constraint(equalTo: composeAndButtonContainer.leadingAnchor, constant: 8),
      attachmentScrollView.trailingAnchor.constraint(equalTo: composeAndButtonContainer.trailingAnchor, constant: -8),
      attachmentScrollView.topAnchor.constraint(equalTo: embedContainerView.bottomAnchor),
      attachmentHeightConstraint,

      attachmentStackView.leadingAnchor.constraint(equalTo: attachmentScrollView.contentLayoutGuide.leadingAnchor),
      attachmentStackView.trailingAnchor.constraint(equalTo: attachmentScrollView.contentLayoutGuide.trailingAnchor),
      attachmentStackView.topAnchor.constraint(equalTo: attachmentScrollView.contentLayoutGuide.topAnchor),
      attachmentStackView.bottomAnchor.constraint(equalTo: attachmentScrollView.contentLayoutGuide.bottomAnchor),
      attachmentStackView.heightAnchor.constraint(equalTo: attachmentScrollView.frameLayoutGuide.heightAnchor),

      // TextView constraints within container
      textView.leadingAnchor.constraint(equalTo: composeAndButtonContainer.leadingAnchor, constant: 8),
      textView.topAnchor.constraint(equalTo: attachmentScrollView.bottomAnchor, constant: 3),
      textView.bottomAnchor.constraint(equalTo: composeAndButtonContainer.bottomAnchor),
      textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -12),

      // SendButton constraints within container
      sendButton.trailingAnchor.constraint(equalTo: composeAndButtonContainer.trailingAnchor, constant: -5),
      sendButton.bottomAnchor.constraint(
        equalTo: composeAndButtonContainer.bottomAnchor,
        constant: -5
      ),
      sendButton.widthAnchor.constraint(equalToConstant: buttonSize.width),
      sendButton.heightAnchor.constraint(equalToConstant: buttonSize.height),
    ])
  }

  func buttonDisappear(animated: Bool = true) {
    guard isButtonVisible || !ComposeSendButtonState.isEffectivelyHidden(alpha: Double(sendButton.alpha)) else {
      sendButton.isEnabled = false
      sendButton.isUserInteractionEnabled = false
      sendButton.setNeedsUpdateConfiguration()
      return
    }
    isButtonVisible = false

    guard animated else {
      sendButton.layer.removeAllAnimations()
      sendButton.layer.removeAnimation(forKey: "telegram.sendButton.blur")
      sendButton.layer.filters = nil
      sendButton.alpha = 0
      sendButton.transform = .identity
      sendButton.isEnabled = false
      sendButton.isUserInteractionEnabled = false
      sendButton.setNeedsUpdateConfiguration()
      return
    }

    animateTelegramSendButtonBlur(to: telegramSendButtonBlurRadius)

    UIView.animate(
      withDuration: telegramSendButtonHideDuration,
      delay: 0,
      options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.sendButton.alpha = 0
    } completion: { finished in
      guard ComposeSendButtonState.shouldFinalizeHide(
        finished: finished,
        isButtonVisible: self.isButtonVisible
      ) else { return }
      self.sendButton.isEnabled = false
      self.sendButton.isUserInteractionEnabled = false
      self.sendButton.transform = .identity
      self.sendButton.setNeedsUpdateConfiguration()
    }
  }

  func buttonAppear() {
    let isFullyVisible = ComposeSendButtonState.isFullyVisible(
      isButtonVisible: isButtonVisible,
      isEnabled: sendButton.isEnabled,
      isUserInteractionEnabled: sendButton.isUserInteractionEnabled,
      alpha: Double(sendButton.alpha)
    )
    guard !isFullyVisible else { return }

    isButtonVisible = true
    sendButton.isEnabled = true
    sendButton.isUserInteractionEnabled = true
    sendButton.setNeedsUpdateConfiguration()

    animateTelegramSendButtonBlur(to: 0.0)

    sendButton.transform = .identity

    if ComposeSendButtonState.isEffectivelyHidden(alpha: Double(sendButton.alpha)) {
      sendButton.alpha = 0.0
    }

    UIView.animate(
      withDuration: telegramSendButtonShowDuration,
      delay: 0,
      options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.sendButton.alpha = 1
      self.sendButton.transform = .identity
    }
  }

  private func showSendButtonImmediately() {
    isButtonVisible = true
    sendButton.layer.removeAllAnimations()
    sendButton.layer.removeAnimation(forKey: "telegram.sendButton.blur")
    sendButton.layer.filters = nil
    sendButton.alpha = 1.0
    sendButton.transform = .identity
    sendButton.isEnabled = true
    sendButton.isUserInteractionEnabled = true
    sendButton.configuration?.showsActivityIndicator = false
    sendButton.setNeedsUpdateConfiguration()
  }

  private func queueSendUntilPendingVideosAreReady(sendMode: MessageSendMode?) {
    guard !isAwaitingPendingVideoSend else { return }
    isAwaitingPendingVideoSend = true
    queuedPendingVideoSendMode = sendMode
    showSendButtonImmediately()
    sendButton.configuration?.showsActivityIndicator = false
    sendButton.setNeedsUpdateConfiguration()
  }

  func cancelQueuedPendingVideoSend() {
    guard isAwaitingPendingVideoSend else { return }
    isAwaitingPendingVideoSend = false
    queuedPendingVideoSendMode = nil
    sendButton.configuration?.showsActivityIndicator = false
    updateSendButtonVisibility()
  }

  private func sendQueuedPendingVideoMessageIfReady() {
    guard isAwaitingPendingVideoSend, pendingVideoAttachments.isEmpty else { return }
    let queuedSendMode = queuedPendingVideoSendMode
    isAwaitingPendingVideoSend = false
    queuedPendingVideoSendMode = nil
    sendButton.configuration?.showsActivityIndicator = false
    sendMessage(sendMode: queuedSendMode)
  }

  private func currentTelegramSendButtonBlurRadius() -> CGFloat {
    if let presentationRadius = sendButton.layer.presentation()?.value(forKeyPath: "filters.gaussianBlur.inputRadius") as? NSNumber {
      return CGFloat(presentationRadius.floatValue)
    }
    if let layerRadius = sendButton.layer.value(forKeyPath: "filters.gaussianBlur.inputRadius") as? NSNumber {
      return CGFloat(layerRadius.floatValue)
    }
    return 0.0
  }

  private func makeTelegramGaussianBlurFilter(radius: CGFloat) -> NSObject? {
    guard let filterClass = NSClassFromString(String("retliFAC".reversed())) as? NSObject.Type else {
      return nil
    }

    let selector = NSSelectorFromString(String(":epyThtiWretlif".reversed()))
    guard let filter = filterClass.perform(selector, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject else {
      return nil
    }

    filter.setValue(radius, forKey: "inputRadius")
    return filter
  }

  private func animateTelegramSendButtonBlur(to toRadius: CGFloat) {
    sendButton.layer.removeAnimation(forKey: "telegram.sendButton.blur")
    let fromRadius = currentTelegramSendButtonBlurRadius()

    if abs(fromRadius - toRadius) < 0.01 {
      if toRadius <= 0.0 {
        sendButton.layer.filters = nil
      }
      return
    }

    guard let blurFilter = makeTelegramGaussianBlurFilter(radius: toRadius) else {
      return
    }

    sendButton.layer.filters = [blurFilter]

    let animation = CABasicAnimation(keyPath: "filters.gaussianBlur.inputRadius")
    animation.fromValue = fromRadius as NSNumber
    animation.toValue = toRadius as NSNumber
    animation.duration = telegramSendButtonBlurDuration
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    animation.isRemovedOnCompletion = true

    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      guard let self else { return }
      if toRadius <= 0.0 {
        self.sendButton.layer.filters = nil
      }
    }
    sendButton.layer.add(animation, forKey: "telegram.sendButton.blur")
    CATransaction.commit()
  }

  @objc func sendTapped() {
    guard canSend else { return }

    let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    feedbackGenerator.prepare()
    feedbackGenerator.impactOccurred(intensity: 1.0)

    sendMessage()
  }

  func sendMessage(sendMode: MessageSendMode? = nil) {
    guard let peerId else { return }
    let state = ChatState.shared.getState(peer: peerId)
    let isEditing = state.editingMessageId != nil
    let forwardContext = state.forwardContext
    guard let chatId else { return }
    let hasPendingVideos = !pendingVideoAttachments.isEmpty
    let hasActiveUploads = hasActiveAttachmentUploads

    if ComposePendingMediaSendBehavior.shouldQueueSendUntilPendingVideosAreReady(
      hasPendingVideos: hasPendingVideos
    ) {
      queueSendUntilPendingVideosAreReady(sendMode: sendMode)
      return
    }

    let rawText = (textView.text ?? "")
      .replacingOccurrences(of: "\u{FFFC}", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let hasText = !rawText.isEmpty
    let attachmentItemsSnapshot = attachmentItems
    let hasAttachmentItems = !attachmentItemsSnapshot.isEmpty
    let hasForward = forwardContext != nil
    guard ComposeSendEligibility.canSend(
      hasText: hasText,
      hasAttachments: hasAttachmentItems,
      hasForward: hasForward,
      hasPendingVideos: hasPendingVideos,
      hasActiveAttachmentUploads: hasActiveUploads
    ) else { return }

    let shouldSendTextOnly = ComposeSendEligibility.shouldSendTextOnly(
      hasText: hasText,
      hasPendingVideos: hasPendingVideos,
      hasActiveAttachmentUploads: hasActiveUploads
    )
    let attachmentItemsToSend = shouldSendTextOnly ? [String: FileMediaItem]() : attachmentItemsSnapshot
    let hasAttachments = !attachmentItemsToSend.isEmpty

    // Can't send if no text, no attachments, and not forwarding
    guard hasText || hasAttachments || forwardContext != nil else { return }

    // Extract all entities using TextProcessing module
    let attributedText = textView.attributedText ?? NSAttributedString()
    let (textFromAttributedString, extractedEntities) = ProcessEntities.fromAttributedString(attributedText)

    let hasEntities = !extractedEntities.entities.isEmpty
    let entities: MessageEntities? = hasEntities ? extractedEntities : nil
    let editEntities: MessageEntities? = hasEntities ? extractedEntities : MessageEntities()

    // Make text nil if empty and we have attachments
    let text = if rawText.isEmpty, hasAttachments {
      nil as String?
    } else {
      rawText
    }

    func sendTextAndAttachments(replyToMessageId: Int64?, queueOnly: Bool) async {
      if attachmentItemsToSend.isEmpty {
        if queueOnly {
          _ = await Api.realtime.sendQueued(.sendMessage(
            text: textFromAttributedString ?? text ?? "",
            peerId: peerId,
            chatId: chatId,
            replyToMsgId: replyToMessageId,
            isSticker: nil,
            entities: entities,
            sendMode: sendMode
          ))
        } else {
          do {
            try await Api.realtime.send(.sendMessage(
              text: textFromAttributedString ?? text ?? "",
              peerId: peerId,
              chatId: chatId,
              replyToMsgId: replyToMessageId,
              isSticker: nil,
              entities: entities,
              sendMode: sendMode
            ))
          } catch {
            log.error("Send message failed", error: error)
          }
        }
      } else {
        for (index, (_, attachment)) in attachmentItemsToSend.enumerated() {
          log.debug("Sending attachment: \(attachment)")
          let isFirst = index == 0

          // Verify attachment has valid local path before sending
          guard attachment.getLocalPath() != nil else {
            log.error("Attachment has no local path, skipping: \(attachment)")
            continue
          }

          Transactions.shared.mutate(transaction: .sendMessage(.init(
            text: isFirst ? textFromAttributedString ?? text ?? "" : nil,
            peerId: peerId,
            chatId: chatId,
            mediaItems: [attachment],
            replyToMsgId: isFirst ? replyToMessageId : nil,
            isSticker: nil,
            entities: isFirst ? entities : nil,
            sendMode: sendMode
          )))
        }
      }
    }

    if isEditing {
      Task(priority: .userInitiated) { @MainActor in
        try await Api.realtime.send(.editMessage(
          messageId: state.editingMessageId ?? 0,
          text: textFromAttributedString ?? text ?? "",
          chatId: chatId,
          peerId: peerId,
          entities: editEntities
        ))
      }

      ChatState.shared.clearEditingMessageId(peer: peerId)
    } else if let forwardContext {
      guard !forwardContext.messageIds.isEmpty else {
        log.error("Forward failed: empty message ids")
        return
      }
      Task(priority: .userInitiated) { @MainActor in
        if hasText || hasAttachments {
          await sendTextAndAttachments(replyToMessageId: nil, queueOnly: true)
        }
        do {
          let result = try await Api.realtime.send(.forwardMessages(
            fromPeerId: forwardContext.fromPeerId,
            toPeerId: peerId,
            messageIds: forwardContext.messageIds
          ))

          if case let .forwardMessages(response) = result, response.updates.isEmpty {
            _ = await Api.realtime.sendQueued(.getChatHistory(peer: peerId))
          }
        } catch {
          log.error("Forward failed", error: error)
        }
      }

      ChatState.shared.clearForwarding(peer: peerId)
    } else {
      let replyToMessageId = state.replyingMessageId
      Task(priority: .userInitiated) { @MainActor in
        await sendTextAndAttachments(replyToMessageId: replyToMessageId, queueOnly: false)
      }

      ChatState.shared.clearReplyingMessageId(peer: peerId)
    }

    if shouldSendTextOnly {
      clearComposeTextAfterSend()
    } else {
      // Clear everything
      resetComposeState()
    }
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
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleReplyStateChange),
      name: .init("ChatStateSetReplyCalled"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleReplyStateChange),
      name: .init("ChatStateClearReplyCalled"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleForwardStateChange),
      name: .init("ChatStateSetForwardCalled"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleForwardStateChange),
      name: .init("ChatStateClearForwardCalled"),
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
            convertMentionsToLink: false, // Keep as attributes for editing
            renderPhoneNumbers: false
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
    updateEmbedState(animated: true)
  }

  @objc private func handleReplyStateChange() {
    updateEmbedState(animated: true)
  }

  @objc private func handleForwardStateChange() {
    updateEmbedState(animated: true)
    updateSendButtonVisibility()
  }

  func dismissEmbed(mode: ComposeEmbedViewContent.Mode) {
    if let peerId {
      switch mode {
      case .reply:
        ChatState.shared.clearReplyingMessageId(peer: peerId)
      case .edit:
        ChatState.shared.clearEditingMessageId(peer: peerId)
        clearEditingComposeState()
      case .forward:
        ChatState.shared.clearForwarding(peer: peerId)
      }
    } else {
      if mode == .edit {
        clearEditingComposeState()
      }
    }

    updateEmbedState(animated: true)
  }

  private func updateEmbedState(animated: Bool) {
    guard let peerId else {
      hideEmbedView(animated: animated)
      return
    }
    guard let chatId else {
      hideEmbedView(animated: animated)
      return
    }

    let state = ChatState.shared.getState(peer: peerId)
    if let editingMessageId = state.editingMessageId {
      showEmbedView(
        peerId: peerId,
        messageId: editingMessageId,
        messageChatId: chatId,
        mode: .edit,
        animated: animated
      )
      becomeFirstResponder()
      textView.becomeFirstResponder()
      return
    }

    if let forwardContext = state.forwardContext,
       let previewMessageId = forwardContext.messageIds.first
    {
      showEmbedView(
        peerId: peerId,
        messageId: previewMessageId,
        messageChatId: forwardContext.sourceChatId,
        mode: .forward,
        animated: animated
      )
      becomeFirstResponder()
      textView.becomeFirstResponder()
      updateSendButtonVisibility()
      return
    }

    if let replyingMessageId = state.replyingMessageId {
      showEmbedView(
        peerId: peerId,
        messageId: replyingMessageId,
        messageChatId: chatId,
        mode: .reply,
        animated: animated
      )
      becomeFirstResponder()
      textView.becomeFirstResponder()
      return
    }

    hideEmbedView(animated: animated)
  }

  private func clearEditingComposeState() {
    textView.text = ""
    textView.showPlaceholder(true)
    buttonDisappear()
    clearDraft()
    resetTextViewState()
    updateHeight()
  }

  private func showEmbedView(
    peerId: InlineKit.Peer,
    messageId: Int64,
    messageChatId: Int64,
    mode: ComposeEmbedViewContent.Mode,
    animated: Bool
  ) {
    let needsNewView = embedView == nil ||
      currentEmbedMessageId != messageId ||
      currentEmbedMode != mode ||
      currentEmbedMessageChatId != messageChatId
    if needsNewView {
      embedView?.removeFromSuperview()
      let newEmbedView = ComposeEmbedView(
        peerId: peerId,
        messageChatId: messageChatId,
        messageId: messageId,
        mode: mode
      )
      newEmbedView.translatesAutoresizingMaskIntoConstraints = false
      UIView.performWithoutAnimation {
        embedContainerView.addSubview(newEmbedView)
        NSLayoutConstraint.activate([
          newEmbedView.leadingAnchor.constraint(equalTo: embedContainerView.leadingAnchor),
          newEmbedView.trailingAnchor.constraint(equalTo: embedContainerView.trailingAnchor),
          newEmbedView.bottomAnchor.constraint(equalTo: embedContainerView.bottomAnchor),
          newEmbedView.heightAnchor.constraint(equalToConstant: ComposeEmbedView.height),
        ])
        embedContainerView.layoutIfNeeded()
      }
      embedView = newEmbedView
      currentEmbedMessageId = messageId
      currentEmbedMode = mode
      currentEmbedMessageChatId = messageChatId
    }

    if embedContainerView.isHidden {
      UIView.performWithoutAnimation {
        embedContainerView.isHidden = false
        embedContainerView.layoutIfNeeded()
      }
    }

    let targetHeight = ComposeEmbedView.height
    let shouldUpdateHeight = embedContainerHeightConstraint?.constant != targetHeight
    embedContainerHeightConstraint?.constant = targetHeight

    if shouldUpdateHeight {
      updateHeight(animated: animated)
    }
  }

  private func hideEmbedView(animated: Bool) {
    guard embedView != nil else { return }

    let shouldUpdateHeight = embedContainerHeightConstraint?.constant != 0
    embedContainerHeightConstraint?.constant = 0

    let finish: () -> Void = { [weak self] in
      guard let self else { return }
      self.embedView?.removeFromSuperview()
      self.embedView = nil
      self.currentEmbedMessageId = nil
      self.currentEmbedMode = nil
      self.currentEmbedMessageChatId = nil
      self.embedContainerView.isHidden = true
    }

    if shouldUpdateHeight {
      updateHeight(animated: animated, completion: finish)
    } else {
      finish()
    }
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
    let hadAttachments = !attachmentItems.isEmpty || !pendingVideoAttachments.isEmpty
    let shouldAnimateHeightReset = ComposeResetBehavior.shouldAnimateHeightResetAfterSend(
      hadAttachments: hadAttachments
    )
    let shouldHideSendButtonImmediately = ComposeResetBehavior.shouldHideSendButtonImmediatelyAfterSend(
      hadAttachments: hadAttachments
    )

    if shouldHideSendButtonImmediately {
      buttonDisappear(animated: false)
    }

    clearDraft()
    clearAttachments(shouldUpdateSendButtonVisibility: !shouldHideSendButtonImmediately)
    stopDraftSaveTimer()
    textView.text = ""

    resetTextViewState()

    // Ensure font is reset after clearing text
    textView.font = .systemFont(ofSize: 17)
    textView.typingAttributes[.font] = UIFont.systemFont(ofSize: 17)

    resetHeight(animated: shouldAnimateHeightReset)
    textView.showPlaceholder(true)
    if !shouldHideSendButtonImmediately {
      buttonDisappear()
    }

    sendButton.configuration?.showsActivityIndicator = false
  }

  private func clearComposeTextAfterSend() {
    clearDraft()
    stopDraftSaveTimer()
    textView.text = ""
    resetTextViewState()
    textView.font = .systemFont(ofSize: 17)
    textView.typingAttributes[.font] = UIFont.systemFont(ofSize: 17)
    textView.showPlaceholder(true)
    updateSendButtonVisibility()
    updateHeight()
    sendButton.configuration?.showsActivityIndicator = false
  }

  // MARK: - Attachment Management

  func removeAttachment(_ id: String) {
    // TODO: Delete from cache as well

    // Update state
    attachmentItems.removeValue(forKey: id)
    handleAttachmentItemsChanged(animated: true)

    log.debug("Removed attachment with id: \(id)")
  }

  func removeImage(_ id: String) {
    removeAttachment(id)
  }

  func removeFile(_ id: String) {
    removeAttachment(id)
  }

  func clearAttachments(shouldUpdateSendButtonVisibility: Bool = true) {
    attachmentItems.removeAll()
    pendingVideoAttachments.removeAll()
    canceledPendingVideoAttachmentIds.removeAll()
    handleAttachmentItemsChanged(animated: false, shouldUpdateSendButtonVisibility: shouldUpdateSendButtonVisibility)
    log.debug("Cleared all attachments")
  }

  @discardableResult
  func addAttachmentItem(_ mediaItem: FileMediaItem, animated: Bool = false) -> String {
    let uniqueId = mediaItem.getItemUniqueId()
    attachmentItems[uniqueId] = mediaItem
    handleAttachmentItemsChanged(animated: animated)
    return uniqueId
  }

  func handleAttachmentItemsChanged(animated: Bool = true, shouldUpdateSendButtonVisibility: Bool = true) {
    syncAttachmentUploadTracking()
    UIView.performWithoutAnimation {
      refreshAttachmentPreviews()
      attachmentStackView.layoutIfNeeded()
    }
    if shouldUpdateSendButtonVisibility {
      let shouldShowSendButtonImmediately = ComposeSendButtonState.shouldShowImmediatelyForReadyAttachments(
        hasAttachments: !attachmentItems.isEmpty,
        hasPendingVideos: !pendingVideoAttachments.isEmpty,
        canSend: canSend
      )

      if shouldShowSendButtonImmediately {
        showSendButtonImmediately()
      } else {
        updateSendButtonVisibility()
      }
    }

    updateHeight(animated: animated)
    sendQueuedPendingVideoMessageIfReady()
  }

  private func syncAttachmentUploadTracking() {
    let currentAttachmentIds = Set(attachmentItems.keys)

    for trackedId in Set(attachmentUploadProgress.keys) where !currentAttachmentIds.contains(trackedId) {
      stopTrackingAttachmentUpload(trackedId, cancelUpload: true)
    }

    for taskId in Set(attachmentUploadBindingTasks.keys) where !currentAttachmentIds.contains(taskId) {
      stopTrackingAttachmentUpload(taskId, cancelUpload: true)
    }

    for taskId in Set(attachmentUploadStartTasks.keys) where !currentAttachmentIds.contains(taskId) {
      stopTrackingAttachmentUpload(taskId, cancelUpload: true)
    }

    for subscriptionId in Set(attachmentUploadSubscriptions.keys) where !currentAttachmentIds.contains(subscriptionId) {
      stopTrackingAttachmentUpload(subscriptionId, cancelUpload: true)
    }

    for (attachmentId, mediaItem) in attachmentItems {
      guard attachmentUploadProgress[attachmentId] == nil, attachmentUploadStartTasks[attachmentId] == nil else {
        continue
      }

      startTrackingAttachmentUpload(attachmentId: attachmentId, mediaItem: mediaItem)
    }
  }

  private func startTrackingAttachmentUpload(attachmentId: String, mediaItem: FileMediaItem) {
    setAttachmentUploadProgress(.processing(id: attachmentId), for: attachmentId)
    bindAttachmentUploadProgress(attachmentId: attachmentId, mediaItem: mediaItem)

    attachmentUploadStartTasks[attachmentId] = Task { [weak self] in
      guard let self else { return }

      do {
        try await self.startAttachmentUpload(mediaItem)
      } catch {
        await MainActor.run { [weak self] in
          guard let self else { return }
          guard self.attachmentItems[attachmentId] != nil else { return }
          self.setAttachmentUploadProgress(.failed(id: attachmentId, error: error), for: attachmentId)
        }
      }

      await MainActor.run { [weak self] in
        self?.attachmentUploadStartTasks.removeValue(forKey: attachmentId)
      }
    }
  }

  private func bindAttachmentUploadProgress(attachmentId: String, mediaItem: FileMediaItem) {
    attachmentUploadBindingTasks[attachmentId] = Task { @MainActor [weak self] in
      guard let self else { return }

      let publisher = await uploadProgressPublisher(for: mediaItem)
      guard !Task.isCancelled else {
        self.attachmentUploadBindingTasks.removeValue(forKey: attachmentId)
        return
      }

      guard let publisher else {
        self.attachmentUploadBindingTasks.removeValue(forKey: attachmentId)
        return
      }

      self.attachmentUploadBindingTasks.removeValue(forKey: attachmentId)
      self.attachmentUploadSubscriptions[attachmentId] = publisher
        .receive(on: DispatchQueue.main)
        .sink { [weak self] snapshot in
          guard let self else { return }
          guard self.attachmentItems[attachmentId] != nil else { return }
          self.setAttachmentUploadProgress(snapshot, for: attachmentId)
        }
    }
  }

  private func uploadProgressPublisher(for mediaItem: FileMediaItem) async -> AnyPublisher<UploadProgressSnapshot, Never>? {
    switch mediaItem {
    case let .photo(photoInfo):
      guard let localId = photoInfo.photo.id else { return nil }
      return await FileUploader.shared.photoProgressPublisher(photoLocalId: localId)
    case let .video(videoInfo):
      guard let localId = videoInfo.video.id else { return nil }
      return await FileUploader.shared.videoProgressPublisher(videoLocalId: localId)
    case let .document(documentInfo):
      guard let localId = documentInfo.document.id else { return nil }
      return await FileUploader.shared.documentProgressPublisher(documentLocalId: localId)
    case .voice:
      return nil
    }
  }

  private func startAttachmentUpload(_ mediaItem: FileMediaItem) async throws {
    switch mediaItem {
    case let .photo(photoInfo):
      _ = try await FileUploader.shared.uploadPhoto(photoInfo: photoInfo)
    case let .video(videoInfo):
      _ = try await FileUploader.shared.uploadVideo(videoInfo: videoInfo)
    case let .document(documentInfo):
      _ = try await FileUploader.shared.uploadDocument(documentInfo: documentInfo)
    case .voice:
      break
    }
  }

  private func setAttachmentUploadProgress(_ progress: UploadProgressSnapshot, for attachmentId: String) {
    attachmentUploadProgress[attachmentId] = progress

    if let preview = attachmentStackView.arrangedSubviews
      .compactMap({ $0 as? ComposeAttachmentPreviewItemView })
      .first(where: { $0.attachmentIdentifier == attachmentId })
    {
      preview.setUploadProgress(progress)
    }

    updateSendButtonVisibility()
  }

  private func stopTrackingAttachmentUpload(_ attachmentId: String, cancelUpload: Bool) {
    attachmentUploadBindingTasks[attachmentId]?.cancel()
    attachmentUploadBindingTasks.removeValue(forKey: attachmentId)

    attachmentUploadStartTasks[attachmentId]?.cancel()
    attachmentUploadStartTasks.removeValue(forKey: attachmentId)

    attachmentUploadSubscriptions[attachmentId]?.cancel()
    attachmentUploadSubscriptions.removeValue(forKey: attachmentId)

    if cancelUpload,
       let progress = attachmentUploadProgress[attachmentId],
       (progress.stage == .processing || progress.stage == .uploading)
    {
      Task {
        await FileUploader.shared.cancel(uploadId: attachmentId)
      }
    }

    attachmentUploadProgress.removeValue(forKey: attachmentId)
  }

  private func clearAttachmentUploadTracking(cancelUploads: Bool) {
    let trackedAttachmentIds = Set(attachmentUploadProgress.keys)
      .union(attachmentUploadBindingTasks.keys)
      .union(attachmentUploadStartTasks.keys)
      .union(attachmentUploadSubscriptions.keys)

    for attachmentId in trackedAttachmentIds {
      stopTrackingAttachmentUpload(attachmentId, cancelUpload: cancelUploads)
    }
  }

  func refreshAttachmentPreviews() {
    attachmentStackView.arrangedSubviews.forEach { view in
      attachmentStackView.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    let hasAttachments = !attachmentItems.isEmpty || !pendingVideoAttachments.isEmpty
    attachmentContainerHeightConstraint?.constant = hasAttachments ? ComposeAttachmentPreviewItemView.stripHeight : 0
    attachmentScrollView.isHidden = !hasAttachments

    guard hasAttachments else { return }

    for pending in pendingVideoAttachments {
      let preview = ComposeAttachmentPreviewItemView(
        pendingVideoId: pending.id,
        thumbnailImage: pending.thumbnailImage
      ) { [weak self] pendingId in
        self?.removePendingVideoAttachment(pendingId, userInitiated: true)
      }
      attachmentStackView.addArrangedSubview(preview)
    }

    for (id, mediaItem) in attachmentItems {
      let preview = ComposeAttachmentPreviewItemView(
        attachmentId: id,
        mediaItem: mediaItem,
        onPreview: { [weak self] attachmentId, sourceView in
          self?.openAttachmentPreview(attachmentId: attachmentId, sourceView: sourceView)
        }
      ) { [weak self] attachmentId in
        self?.removeAttachment(attachmentId)
      }
      preview.setUploadProgress(attachmentUploadProgress[id])
      attachmentStackView.addArrangedSubview(preview)
    }
  }

  @discardableResult
  func addPendingVideoAttachment() -> String {
    let pendingId = "pending_video_\(UUID().uuidString)"
    canceledPendingVideoAttachmentIds.remove(pendingId)
    pendingVideoAttachments.append(PendingVideoAttachment(id: pendingId, thumbnailImage: nil))
    handleAttachmentItemsChanged(animated: false)
    return pendingId
  }

  func updatePendingVideoAttachmentThumbnail(_ pendingId: String, image: UIImage?) {
    guard let index = pendingVideoAttachments.firstIndex(where: { $0.id == pendingId }) else { return }
    pendingVideoAttachments[index].thumbnailImage = image
    refreshAttachmentPreviews()
  }

  func removePendingVideoAttachment(_ pendingId: String, animated: Bool = false, userInitiated: Bool = false) {
    if userInitiated {
      canceledPendingVideoAttachmentIds.insert(pendingId)
    }
    pendingVideoAttachments.removeAll { $0.id == pendingId }
    handleAttachmentItemsChanged(animated: animated)
  }

  func isPendingVideoAttachmentCanceled(_ pendingId: String) -> Bool {
    canceledPendingVideoAttachmentIds.contains(pendingId)
  }

  private func openAttachmentPreview(attachmentId: String, sourceView: UIView) {
    guard let mediaItem = attachmentItems[attachmentId] else { return }
    guard let presenter = attachmentFlowPresenter() else { return }
    guard presenter.presentedViewController == nil else { return }

    guard let fileURL = mediaItem.localFileURL(),
          FileManager.default.fileExists(atPath: fileURL.path)
    else {
      showAttachmentPreviewUnavailableAlert()
      return
    }

    switch mediaItem {
    case .photo:
      let viewer = ImageViewerController(
        imageURL: fileURL,
        sourceView: sourceView,
        sourceCornerRadius: 16
      )
      presenter.present(viewer, animated: false)
    case .video:
      let viewer = ImageViewerController(
        videoURL: fileURL,
        sourceView: sourceView,
        sourceCornerRadius: 16
      )
      presenter.present(viewer, animated: false)
    case .document:
      presentDocumentPreview(fileURL: fileURL, sourceView: sourceView, presenter: presenter)
    case .voice:
      showAttachmentPreviewUnavailableAlert()
    }
  }

  private func presentDocumentPreview(fileURL: URL, sourceView: UIView, presenter: UIViewController) {
    if QLPreviewController.canPreview(fileURL as NSURL) {
      quickLookPreviewURL = fileURL
      let previewController = QLPreviewController()
      previewController.dataSource = self
      previewController.delegate = self
      presenter.present(previewController, animated: true)
      return
    }

    let interactionController = UIDocumentInteractionController(url: fileURL)
    interactionController.delegate = self
    documentInteractionController = interactionController

    if !interactionController.presentPreview(animated: true) {
      _ = interactionController.presentOptionsMenu(from: sourceView.bounds, in: sourceView, animated: true)
    }
  }

  private func showAttachmentPreviewUnavailableAlert() {
    guard let presenter = attachmentFlowPresenter() else { return }

    let alert = UIAlertController(
      title: "Preview Unavailable",
      message: "This attachment can't be previewed right now.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    presenter.present(alert, animated: true)
  }

  func updateSendButtonVisibility() {
    if isAwaitingPendingVideoSend {
      showSendButtonImmediately()
      sendButton.configuration?.showsActivityIndicator = false
      sendButton.setNeedsUpdateConfiguration()
      return
    }

    let shouldEnableSend = canSend

    if shouldEnableSend {
      buttonAppear()
    } else {
      buttonDisappear()
    }
  }
}

extension ComposeView: SlashCommandManagerDelegate {
  func slashCommandManager(_ manager: SlashCommandManager, didInsertCommand text: String, for range: NSRange) {
    sendMessage()
  }

  func slashCommandManagerDidDismiss(_ manager: SlashCommandManager) {}
}

extension ComposeView: QLPreviewControllerDataSource, QLPreviewControllerDelegate {
  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    quickLookPreviewURL == nil ? 0 : 1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
    if let quickLookPreviewURL {
      return quickLookPreviewURL as NSURL
    }

    return NSURL(fileURLWithPath: "/")
  }

  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    quickLookPreviewURL = nil
  }
}

extension ComposeView: UIDocumentInteractionControllerDelegate {
  func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
    attachmentFlowPresenter() ?? UIViewController()
  }

  func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) {
    if documentInteractionController === controller {
      documentInteractionController = nil
    }
  }
}

private final class ComposeAttachmentPreviewItemView: UIView {
  static let stripHeight: CGFloat = 92

  private enum Metrics {
    static let tileSize: CGFloat = 84
    static let cornerRadius: CGFloat = 16
    static let removeButtonSize: CGFloat = 22
    static let removeBadgeSize: CGFloat = 22
    static let progressRingSize: CGFloat = 28
  }

  private let attachmentId: String
  private let onPreview: ((String, UIView) -> Void)?
  private let onRemove: (String) -> Void
  var attachmentIdentifier: String { attachmentId }

  private let tileContentView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.layer.cornerRadius = Metrics.cornerRadius
    view.layer.cornerCurve = .continuous
    view.layer.masksToBounds = true
    return view
  }()

  private let tinyThumbnailBackgroundView: InlineTinyThumbnailBackgroundView = {
    let view = InlineTinyThumbnailBackgroundView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let thumbnailView: PlatformPhotoView = {
    let view = PlatformPhotoView()
    view.photoContentMode = .aspectFill
    view.showsLoadingPlaceholder = false
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let localThumbnailImageView: UIImageView = {
    let imageView = UIImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.isHidden = true
    return imageView
  }()

  private let fallbackView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = .tertiarySystemFill
    return view
  }()

  private let centerIconView: UIImageView = {
    let iconView = UIImageView()
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .scaleAspectFit
    iconView.tintColor = .secondaryLabel
    return iconView
  }()

  private let extensionBadge: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 9, weight: .semibold)
    label.textColor = .white
    label.textAlignment = .center
    label.backgroundColor = UIColor.black.withAlphaComponent(0.45)
    label.layer.cornerRadius = 5
    label.layer.masksToBounds = true
    label.isHidden = true
    return label
  }()

  private let overlayIconView: UIImageView = {
    let iconView = UIImageView()
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .scaleAspectFit
    iconView.tintColor = .white
    iconView.layer.shadowColor = UIColor.black.cgColor
    iconView.layer.shadowOffset = .zero
    iconView.layer.shadowRadius = 2
    iconView.layer.shadowOpacity = 0.6
    iconView.isHidden = true
    return iconView
  }()

  private let progressOverlayView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
    view.isUserInteractionEnabled = false
    view.isHidden = true
    return view
  }()

  private let uploadProgressView: CircularProgressHostingView = {
    let view = CircularProgressHostingView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isHidden = true
    return view
  }()

  private let loadingIndicator: UIActivityIndicatorView = {
    let view = UIActivityIndicatorView(style: .medium)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.color = .secondaryLabel
    view.hidesWhenStopped = true
    return view
  }()

  private lazy var removeButton: UIButton = {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.backgroundColor = .clear
    button.addTarget(self, action: #selector(removeTapped), for: .touchUpInside)
    button.accessibilityLabel = "Remove attachment"
    return button
  }()

  private let removeBadgeView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isUserInteractionEnabled = false
    view.backgroundColor = .white
    view.layer.cornerRadius = Metrics.removeBadgeSize / 2
    view.layer.cornerCurve = .continuous
    view.layer.shadowColor = UIColor.black.cgColor
    view.layer.shadowOpacity = 0.18
    view.layer.shadowRadius = 3
    view.layer.shadowOffset = CGSize(width: 0, height: 1)
    return view
  }()

  private let removeIconView: UIImageView = {
    let view = UIImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isUserInteractionEnabled = false
    view.image = UIImage(systemName: "xmark")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
    )
    view.tintColor = .black
    return view
  }()

  init(
    attachmentId: String,
    mediaItem: FileMediaItem,
    onPreview: ((String, UIView) -> Void)?,
    onRemove: @escaping (String) -> Void
  ) {
    self.attachmentId = attachmentId
    self.onPreview = onPreview
    self.onRemove = onRemove
    super.init(frame: .zero)
    setupViews()
    configure(mediaItem: mediaItem)
  }

  init(
    pendingVideoId: String,
    thumbnailImage: UIImage?,
    onRemove: @escaping (String) -> Void
  ) {
    attachmentId = pendingVideoId
    onPreview = nil
    self.onRemove = onRemove
    super.init(frame: .zero)
    accessibilityIdentifier = pendingVideoId
    setupViews()
    configurePendingVideo(thumbnailImage: thumbnailImage)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func removeTapped() {
    onRemove(attachmentId)
  }

  @objc private func previewTapped() {
    onPreview?(attachmentId, tileContentView)
  }

  private func setupViews() {
    translatesAutoresizingMaskIntoConstraints = false
    clipsToBounds = false

    addSubview(tileContentView)
    tileContentView.addSubview(fallbackView)
    tileContentView.addSubview(tinyThumbnailBackgroundView)
    tileContentView.addSubview(thumbnailView)
    tileContentView.addSubview(localThumbnailImageView)
    tileContentView.addSubview(centerIconView)
    tileContentView.addSubview(extensionBadge)
    tileContentView.addSubview(overlayIconView)
    tileContentView.addSubview(progressOverlayView)
    progressOverlayView.addSubview(uploadProgressView)
    tileContentView.addSubview(loadingIndicator)
    addSubview(removeButton)
    removeButton.addSubview(removeBadgeView)
    removeBadgeView.addSubview(removeIconView)

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(previewTapped))
    tileContentView.addGestureRecognizer(tapGesture)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: Metrics.tileSize),
      heightAnchor.constraint(equalToConstant: Metrics.tileSize),

      tileContentView.leadingAnchor.constraint(equalTo: leadingAnchor),
      tileContentView.trailingAnchor.constraint(equalTo: trailingAnchor),
      tileContentView.topAnchor.constraint(equalTo: topAnchor),
      tileContentView.bottomAnchor.constraint(equalTo: bottomAnchor),

      fallbackView.leadingAnchor.constraint(equalTo: tileContentView.leadingAnchor),
      fallbackView.trailingAnchor.constraint(equalTo: tileContentView.trailingAnchor),
      fallbackView.topAnchor.constraint(equalTo: tileContentView.topAnchor),
      fallbackView.bottomAnchor.constraint(equalTo: tileContentView.bottomAnchor),

      tinyThumbnailBackgroundView.leadingAnchor.constraint(equalTo: tileContentView.leadingAnchor),
      tinyThumbnailBackgroundView.trailingAnchor.constraint(equalTo: tileContentView.trailingAnchor),
      tinyThumbnailBackgroundView.topAnchor.constraint(equalTo: tileContentView.topAnchor),
      tinyThumbnailBackgroundView.bottomAnchor.constraint(equalTo: tileContentView.bottomAnchor),

      thumbnailView.leadingAnchor.constraint(equalTo: tileContentView.leadingAnchor),
      thumbnailView.trailingAnchor.constraint(equalTo: tileContentView.trailingAnchor),
      thumbnailView.topAnchor.constraint(equalTo: tileContentView.topAnchor),
      thumbnailView.bottomAnchor.constraint(equalTo: tileContentView.bottomAnchor),

      localThumbnailImageView.leadingAnchor.constraint(equalTo: tileContentView.leadingAnchor),
      localThumbnailImageView.trailingAnchor.constraint(equalTo: tileContentView.trailingAnchor),
      localThumbnailImageView.topAnchor.constraint(equalTo: tileContentView.topAnchor),
      localThumbnailImageView.bottomAnchor.constraint(equalTo: tileContentView.bottomAnchor),

      centerIconView.centerXAnchor.constraint(equalTo: tileContentView.centerXAnchor),
      centerIconView.centerYAnchor.constraint(equalTo: tileContentView.centerYAnchor),

      extensionBadge.centerXAnchor.constraint(equalTo: tileContentView.centerXAnchor),
      extensionBadge.bottomAnchor.constraint(equalTo: tileContentView.bottomAnchor, constant: -4),
      extensionBadge.leadingAnchor.constraint(greaterThanOrEqualTo: tileContentView.leadingAnchor, constant: 4),
      extensionBadge.trailingAnchor.constraint(lessThanOrEqualTo: tileContentView.trailingAnchor, constant: -4),

      overlayIconView.centerXAnchor.constraint(equalTo: tileContentView.centerXAnchor),
      overlayIconView.centerYAnchor.constraint(equalTo: tileContentView.centerYAnchor),

      progressOverlayView.leadingAnchor.constraint(equalTo: tileContentView.leadingAnchor),
      progressOverlayView.trailingAnchor.constraint(equalTo: tileContentView.trailingAnchor),
      progressOverlayView.topAnchor.constraint(equalTo: tileContentView.topAnchor),
      progressOverlayView.bottomAnchor.constraint(equalTo: tileContentView.bottomAnchor),

      uploadProgressView.centerXAnchor.constraint(equalTo: progressOverlayView.centerXAnchor),
      uploadProgressView.centerYAnchor.constraint(equalTo: progressOverlayView.centerYAnchor),
      uploadProgressView.widthAnchor.constraint(equalToConstant: Metrics.progressRingSize),
      uploadProgressView.heightAnchor.constraint(equalToConstant: Metrics.progressRingSize),

      loadingIndicator.centerXAnchor.constraint(equalTo: tileContentView.centerXAnchor),
      loadingIndicator.centerYAnchor.constraint(equalTo: tileContentView.centerYAnchor),

      removeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      removeButton.widthAnchor.constraint(equalToConstant: Metrics.removeButtonSize),
      removeButton.heightAnchor.constraint(equalToConstant: Metrics.removeButtonSize),

      removeBadgeView.centerXAnchor.constraint(equalTo: removeButton.centerXAnchor),
      removeBadgeView.centerYAnchor.constraint(equalTo: removeButton.centerYAnchor),
      removeBadgeView.widthAnchor.constraint(equalToConstant: Metrics.removeBadgeSize),
      removeBadgeView.heightAnchor.constraint(equalToConstant: Metrics.removeBadgeSize),

      removeIconView.centerXAnchor.constraint(equalTo: removeBadgeView.centerXAnchor),
      removeIconView.centerYAnchor.constraint(equalTo: removeBadgeView.centerYAnchor),
    ])
  }

  private func configure(mediaItem: FileMediaItem) {
    loadingIndicator.stopAnimating()
    setUploadProgress(nil)
    localThumbnailImageView.image = nil
    localThumbnailImageView.isHidden = true
    centerIconView.isHidden = true
    overlayIconView.isHidden = true
    extensionBadge.isHidden = true
    thumbnailView.isHidden = false
    tinyThumbnailBackgroundView.isHidden = true

    switch mediaItem {
    case let .photo(photoInfo):
      applyPhotoPreview(photoInfo)

    case let .video(videoInfo):
      if let thumbnail = videoInfo.thumbnail {
        applyPhotoPreview(thumbnail)
      } else {
        applyFallback(iconName: "video.fill", badgeText: nil)
      }

    case let .document(documentInfo):
      if let thumbnail = documentInfo.thumbnail {
        applyPhotoPreview(thumbnail)
      } else {
        applyFallback(
          iconName: DocumentIconResolver.symbolName(
            mimeType: documentInfo.document.mimeType,
            fileName: documentInfo.document.fileName,
            style: .filled
          ),
          badgeText: fileExtension(from: documentInfo.document.fileName)
        )
      }

    case .voice:
      applyFallback(iconName: "waveform", badgeText: nil)
    }
  }

  private func configurePendingVideo(thumbnailImage: UIImage?) {
    setUploadProgress(nil)
    loadingIndicator.stopAnimating()
    overlayIconView.isHidden = true
    extensionBadge.isHidden = true
    if let thumbnailImage {
      applyPendingThumbnail(thumbnailImage)
      return
    }
    applyFallback(iconName: "video.fill", badgeText: nil)
  }

  func setUploadProgress(_ _: UploadProgressSnapshot?) {
    loadingIndicator.stopAnimating()
    progressOverlayView.isHidden = true
    uploadProgressView.isHidden = true
    uploadProgressView.setProgress(0)
  }

  private func applyPhotoPreview(_ photoInfo: PhotoInfo?) {
    localThumbnailImageView.image = nil
    localThumbnailImageView.isHidden = true
    tinyThumbnailBackgroundView.setPhoto(photoInfo)
    thumbnailView.setPhoto(photoInfo)
    centerIconView.isHidden = true
  }

  private func applyPendingThumbnail(_ image: UIImage) {
    thumbnailView.setPhoto(nil)
    thumbnailView.isHidden = true
    tinyThumbnailBackgroundView.setPhoto(nil)

    localThumbnailImageView.image = image
    localThumbnailImageView.isHidden = false
    centerIconView.isHidden = true
  }

  private func applyFallback(iconName: String, badgeText: String?) {
    thumbnailView.setPhoto(nil)
    thumbnailView.isHidden = true
    tinyThumbnailBackgroundView.setPhoto(nil)
    localThumbnailImageView.image = nil
    localThumbnailImageView.isHidden = true

    centerIconView.image = UIImage(systemName: iconName)?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    )
    centerIconView.isHidden = false

    if let badgeText, !badgeText.isEmpty {
      extensionBadge.text = " \(badgeText.uppercased()) "
      extensionBadge.isHidden = false
    } else {
      extensionBadge.text = nil
      extensionBadge.isHidden = true
    }
  }

  private func fileExtension(from fileName: String?) -> String? {
    guard let fileName else { return nil }
    let ext = URL(fileURLWithPath: fileName).pathExtension
    return ext.isEmpty ? nil : ext
  }
}
