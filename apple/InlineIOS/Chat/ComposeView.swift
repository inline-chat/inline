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

class ComposeView: UIView, NSTextLayoutManagerDelegate, UIImagePickerControllerDelegate,
  UINavigationControllerDelegate
{
  // MARK: - Configuration Constants

  static let minHeight: CGFloat = 38.0
  private let maxHeight: CGFloat = 350
  private let buttonSize: CGSize = .init(width: 32, height: 32)
  static let textViewVerticalPadding: CGFloat = 0.0
  static let textViewHorizantalPadding: CGFloat = 12.0
  static let textViewHorizantalMargin: CGFloat = 7.0
  static let textViewVerticalMargin: CGFloat = 4.0

  // MARK: - Private Properties

  private var composeHeightConstraint: NSLayoutConstraint!
  private var prevTextHeight: CGFloat = 0.0
  private let buttonBottomPadding: CGFloat = -4.0
  private let buttonTrailingPadding: CGFloat = -6.0
  private let buttonLeadingPadding: CGFloat = 10.0
  private var overlayView: UIView?
  private var isOverlayVisible = false
  private var phaseObserver: AnyCancellable?

  // MARK: - State Management

  private var isButtonVisible = false
  var selectedImage: UIImage?
  var showingPhotoPreview: Bool = false
  var imageCaption: String = ""
  let previewViewModel = PhotoPreviewViewModel()
  var attachmentItems: [UIImage: FileMediaItem] = [:]

  var onHeightChange: ((CGFloat) -> Void)?
  var peerId: InlineKit.Peer?
  var chatId: Int64?

  // Mention functionality
  private var mentionManager: MentionManager?

  // Draft auto-save timer
  private var draftSaveTimer: Timer?
  private let draftSaveInterval: TimeInterval = 2.0 // Save every 2 seconds

  // Track original draft entities to preserve them when not being modified
  private var originalDraftEntities: MessageEntities?

  // MARK: - UI Components

  lazy var textView: ComposeTextView = {
    let view = ComposeTextView(composeView: self)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.delegate = self
    return view
  }()

  // lazy var sendButtonContainer: UIButton = {
  //   let container = UIButton()
  //   container.translatesAutoresizingMaskIntoConstraints = false
  //   container.isUserInteractionEnabled = true
  //   container.isEnabled = true
  //   container.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
  //   container.addTarget(self, action: #selector(handleTouchDown), for: .touchDown)
  //   container.addTarget(self, action: #selector(handleTouchUp), for: [.touchUpOutside, .touchCancel])
  //   container.alpha = 0
  //   return container
  // }()

  lazy var sendButton = makeSendButton()
  lazy var plusButton = makePlusButton()

  // MARK: - Initialization

  deinit {
    NotificationCenter.default.removeObserver(self)
    stopDraftSaveTimer()
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
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

  override func removeFromSuperview() {
    saveDraft()
    stopDraftSaveTimer()
    mentionManager?.cleanup()
    mentionManager = nil
    super.removeFromSuperview()
  }

  override func resignFirstResponder() -> Bool {
    dismissOverlay()
    return super.resignFirstResponder()
  }

  public func sendSticker(_ image: UIImage) {
    guard let peerId else {
      Log.shared.debug("❌ COMPOSE - No peerId available")
      return
    }

    do {
      Task.detached(priority: .userInitiated) {
        let photoInfo = try FileCache.savePhoto(image: image, optimize: true)

        await Transactions.shared.mutate(
          transaction: .sendMessage(
            .init(
              text: nil,
              peerId: peerId,
              chatId: self.chatId ?? 0,
              mediaItems: [.photo(photoInfo)],
              replyToMsgId: ChatState.shared.getState(peer: peerId).replyingMessageId,
              isSticker: true
            )
          )
        )
      }

      ChatState.shared.clearEditingMessageId(peer: peerId)
      ChatState.shared.clearReplyingMessageId(peer: peerId)

      clearDraft()
      textView.text = ""
      resetHeight()
      textView.showPlaceholder(true)
      buttonDisappear()
      // sendMessageHaptic()
    } catch {
      Log.shared.error("❌ COMPOSE - Failed to save sticker", error: error)
    }

    sendButton.configuration?.showsActivityIndicator = false
  }

  // MARK: - Setup & Layout

  private func setupMentionManager() {
    guard let peerId,
          let chatId,
          let window,
          let windowScene = window.windowScene,
          let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
          let rootView = keyWindow.rootViewController?.view
    else {
      return
    }

    mentionManager = MentionManager(database: AppDatabase.shared, chatId: chatId, peerId: peerId)
    mentionManager?.delegate = self
    mentionManager?.attachTo(textView: textView, parentView: rootView)
  }

  private func setupViews() {
    backgroundColor = .clear
    addSubview(textView)
    // addSubview(sendButtonContainer)
    // sendButtonContainer.addSubview(sendButton)
    addSubview(sendButton)
    addSubview(plusButton)

    // Make sure the container button is on top of the inner button
    // sendButtonContainer.bringSubviewToFront(sendButton)

    // Disable user interaction on the inner button since container will handle touches
    // sendButton.isUserInteractionEnabled = false

    composeHeightConstraint = heightAnchor.constraint(equalToConstant: Self.minHeight)

    let buttonBottomPadding: CGFloat = -3

    NSLayoutConstraint.activate([
      composeHeightConstraint,

      plusButton.leadingAnchor.constraint(equalTo: leadingAnchor),
      plusButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: buttonBottomPadding),
      plusButton.widthAnchor.constraint(equalToConstant: buttonSize.width),
      plusButton.heightAnchor.constraint(equalToConstant: buttonSize.height),

      textView.leadingAnchor.constraint(equalTo: plusButton.trailingAnchor, constant: 8),
      textView.topAnchor.constraint(equalTo: topAnchor),
      textView.bottomAnchor.constraint(equalTo: bottomAnchor),
      // textView.trailingAnchor.constraint(equalTo: sendButtonContainer.leadingAnchor, constant: 12),

      // sendButtonContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
      // sendButtonContainer.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: 7),
      // sendButtonContainer.widthAnchor.constraint(equalToConstant: buttonSize.width + 20),
      // sendButtonContainer.heightAnchor.constraint(equalToConstant: buttonSize.height + 20),

      // sendButton.trailingAnchor.constraint(equalTo: sendButtonContainer.trailingAnchor),
      // sendButton.centerYAnchor.constraint(equalTo: sendButtonContainer.centerYAnchor),
      // sendButton.widthAnchor.constraint(equalToConstant: buttonSize.width - 2),
      // sendButton.heightAnchor.constraint(equalToConstant: buttonSize.height - 2),

      textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -12),

      sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
      sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: buttonBottomPadding),
      sendButton.widthAnchor.constraint(equalToConstant: buttonSize.width),
      sendButton.heightAnchor.constraint(equalToConstant: buttonSize.height),
    ])

    let dropInteraction = UIDropInteraction(delegate: self)
    addInteraction(dropInteraction)
  }

  // MARK: - UI Component Creation

  private func makeSendButton() -> UIButton {
    let button = UIButton()
    button.translatesAutoresizingMaskIntoConstraints = false
    button.frame = CGRect(origin: .zero, size: buttonSize)

    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "arrow.up")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
    )
    config.baseForegroundColor = .white
    config.background.backgroundColor = ThemeManager.shared.selected.accent
    config.cornerStyle = .capsule

    button.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
    button.addTarget(self, action: #selector(handleTouchDown), for: .touchDown)
    button.addTarget(self, action: #selector(handleTouchUp), for: [.touchUpOutside, .touchCancel])

    button.configurationUpdateHandler = { [weak button] _ in
      guard let button else { return }

      let config = button.configuration

      if button.isHighlighted {
        UIView.animate(
          withDuration: 0.15,
          delay: 0,
          options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut],
          animations: {
            button.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
          }
        )
      } else {
        UIView.animate(
          withDuration: 0.12,
          delay: 0.05,
          options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseIn],
          animations: {
            button.transform = .identity
          }
        )
      }

      button.configuration = config
    }

    button.configuration = config
    button.isUserInteractionEnabled = true

    // Hide initially
    button.alpha = 0.0

    return button
  }

  @objc private func handleTouchDown() {
    // haptic
    // let generator = UIImpactFeedbackGenerator(style: .soft)
    // generator.impactOccurred()
    // lighter
    // let generator = UIImpactFeedbackGenerator(style: .light)
    // generator.prepare()
    // generator.impactOccurred(intensity: 0.8)
  }

  @objc private func handleTouchUp() {
    print("Touch up detected")
    // Handle touch end
  }

  private func makePlusButton() -> UIButton {
    let button = UIButton()
    button.translatesAutoresizingMaskIntoConstraints = false

    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "plus")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    )
    config.baseForegroundColor = .secondaryLabel
    config.background.backgroundColor = .secondarySystemBackground
    button.configuration = config
    button.layer.cornerRadius = 16
    button.clipsToBounds = true

    let libraryAction = UIAction(
      title: "Photos",
      image: UIImage(systemName: "photo"),
      handler: { [weak self] _ in
        self?.presentPicker()
      }
    )

    let cameraAction = UIAction(
      title: "Camera",
      image: UIImage(systemName: "camera"),
      handler: { [weak self] _ in
        self?.presentCamera()
      }
    )

    button.menu = UIMenu(children: [libraryAction, cameraAction])
    button.showsMenuAsPrimaryAction = true

    return button
  }

  // MARK: - Height Management

  func textViewHeightByContentHeight(_ contentHeight: CGFloat) -> CGFloat {
    let newHeight = min(maxHeight, max(Self.minHeight, contentHeight + Self.textViewVerticalPadding * 2))
    return newHeight
  }

  func updateHeight() {
    let size = textView.sizeThatFits(CGSize(
      width: textView.bounds.width,
      height: .greatestFiniteMagnitude
    ))

    let contentHeight = size.height
    let newHeight = textViewHeightByContentHeight(contentHeight)
    guard abs(composeHeightConstraint.constant - newHeight) > 1 else { return }

    composeHeightConstraint.constant = newHeight
    superview?.layoutIfNeeded()

    DispatchQueue.main.async {
      let bottomRange = NSRange(location: self.textView.text.count, length: 0)
      self.textView.scrollRangeToVisible(bottomRange)
    }

    onHeightChange?(newHeight)
  }

  private func resetHeight() {
    UIView.animate(withDuration: 0.2) {
      self.composeHeightConstraint.constant = Self.minHeight
      self.superview?.layoutIfNeeded()
    }
    onHeightChange?(Self.minHeight)
  }

  // MARK: - Button Animation

  func buttonDisappear() {
    print("buttonDisappear")
    isButtonVisible = false
    UIView.animate(withDuration: 0.12, delay: 0.1, options: [.curveEaseOut, .allowUserInteraction]) {
      // self.sendButtonContainer.alpha = 0
      // self.sendButtonContainer.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
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

  // MARK: - Message Actions

  @objc private func sendTapped() {
    guard let peerId else { return }
    let state = ChatState.shared.getState(peer: peerId)
    let isEditing = state.editingMessageId != nil

    guard let text = textView.text?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty
    else { return }
    guard let chatId else { return }

    // Extract mention entities from attributed text
    let attributedText = textView.attributedText ?? NSAttributedString()
    let mentionEntities = mentionManager?.extractMentionEntities(from: attributedText) ?? []
    let entities = if mentionEntities.isEmpty {
      nil as MessageEntities?
    } else {
      MessageEntities.with { $0.entities = mentionEntities }
    }

    if isEditing {
      // Handle message edit
      Transactions.shared.mutate(transaction: .editMessage(.init(
        messageId: state.editingMessageId ?? 0,
        text: text,
        chatId: chatId,
        peerId: peerId
      )))

      ChatState.shared.clearEditingMessageId(peer: peerId)
    } else {
      // Original send message logic
      let replyToMessageId = state.replyingMessageId
      Transactions.shared.mutate(transaction: .sendMessage(.init(
        text: text,
        peerId: peerId,
        chatId: chatId,
        mediaItems: [],
        replyToMsgId: replyToMessageId,
        isSticker: nil,
        entities: entities
      )))
      ChatState.shared.clearReplyingMessageId(peer: peerId)
    }

    clearDraft()
    stopDraftSaveTimer()
    textView.text = ""
    resetHeight()
    textView.showPlaceholder(true)
    buttonDisappear()
    // Moved
    // sendMessageHaptic()
  }

  private func updateSendButtonForEditing(_ isEditing: Bool) {
    let imageName = isEditing ? "checkmark" : "arrow.up"
    sendButton.configuration?.image = UIImage(systemName: imageName)?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
    )
  }

  // func sendMessageHaptic() {
  //   Task { @MainActor in
  //     let generator = UIImpactFeedbackGenerator(style: .medium)
  //     generator.prepare()
  //     generator.impactOccurred()
  //   }
  // }

  // MARK: - Draft Auto-Save Timer

  private func startDraftSaveTimer() {
    stopDraftSaveTimer() // Stop any existing timer
    draftSaveTimer = Timer.scheduledTimer(withTimeInterval: draftSaveInterval, repeats: true) { [weak self] _ in
      self?.saveDraftIfNeeded()
    }
    Log.shared.debug("🌴 Draft auto-save timer started")
  }

  private func stopDraftSaveTimer() {
    if draftSaveTimer != nil {
      Log.shared.debug("🌴 Draft auto-save timer stopped")
    }
    draftSaveTimer?.invalidate()
    draftSaveTimer = nil
  }

  private func saveDraftIfNeeded() {
    guard let peerId else { return }
    guard let text = textView.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      // If text is empty, clear the draft
      Drafts.shared.clear(peerId: peerId)
      originalDraftEntities = nil
      return
    }

    // Extract mention entities from attributed text for draft
    let attributedText = textView.attributedText ?? NSAttributedString()
    let mentionEntities = mentionManager?.extractMentionEntities(from: attributedText) ?? []

    // Determine final entities to save
    let entities: MessageEntities? = if !mentionEntities.isEmpty {
      // We have current mention entities, use them
      MessageEntities.with { $0.entities = mentionEntities }
    } else if let originalEntities = originalDraftEntities {
      // No current mentions but we had original entities, preserve them if they're still valid
      validateAndPreserveEntities(originalEntities, for: text)
    } else {
      // No mentions at all
      nil
    }

    Log.shared.debug("🌴 Auto-saving draft: \(text.prefix(50))...")
    Drafts.shared.update(peerId: peerId, text: text, entities: entities)
  }

  private func validateAndPreserveEntities(_ originalEntities: MessageEntities, for text: String) -> MessageEntities? {
    // Validate that the original entities are still within bounds of the current text
    let textLength = text.utf16.count
    let validEntities = originalEntities.entities.filter { entity in
      let endPosition = Int(entity.offset) + Int(entity.length)
      return entity.offset >= 0 && endPosition <= textLength
    }

    if validEntities.isEmpty {
      return nil
    } else {
      return MessageEntities.with { $0.entities = validEntities }
    }
  }

  // MARK: - Draft Management

  func loadDraft(from draftMessage: InlineProtocol.DraftMessage?) {
    guard let draftMessage else { return }

    print("🌴 draftMessage in loadDraft im compose", draftMessage)
    let draft = MessageDraft(
      text: draftMessage.text,
      entities: draftMessage.hasEntities ? draftMessage.entities : nil
    )

    applyDraft(draft.text, entities: draft.entities)
  }

  func applyDraft(_ draft: String?, entities: MessageEntities? = nil) {
    if let draft, !draft.isEmpty {
      textView.text = draft

      // Store original entities for preservation during auto-save
      originalDraftEntities = entities

      if let entities {
        for entity in entities.entities {
          if entity.type == .mention, case let .mention(mention) = entity.entity {
            let range = NSRange(location: Int(entity.offset), length: Int(entity.length))

            if range.location >= 0, range.location + range.length <= draft.utf16.count {
              let attributedText = NSMutableAttributedString(attributedString: textView.attributedText)

              attributedText.addAttributes([
                .foregroundColor: ThemeManager.shared.selected.accent,
                NSAttributedString.Key("mention_user_id"): mention.userID,
              ], range: range)

              textView.attributedText = attributedText
            }
          }
        }
      }

      textView.showPlaceholder(false)
      buttonAppear()
      updateHeight()

      // Start timer since we now have text content
      startDraftSaveTimer()
    }
  }

  /// Set the initial draft from ChatView (call this after setting peerId and chatId)
  public func setInitialDraft(from draftMessage: InlineProtocol.DraftMessage?) {
    guard let draftMessage else { return }

    let draft = MessageDraft(
      text: draftMessage.text,
      entities: draftMessage.hasEntities ? draftMessage.entities : nil
    )

    applyDraft(draft.text, entities: draft.entities)
  }

  private func saveDraft() {
    // Use the timer-based save method for consistency
    saveDraftIfNeeded()
  }

  func clearDraft() {
    guard let peerId else { return }
    Drafts.shared.clear(peerId: peerId)
    originalDraftEntities = nil
  }

  @objc private func saveCurrentDraft() {
    saveDraft()
  }

  // MARK: - Observers Setup

  private func setupScenePhaseObserver() {
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

  private func setupChatStateObservers() {
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

  @objc private func handleEditingStateChange() {
    guard let peerId, let chatId else { return }
    let isEditing = ChatState.shared.getState(peer: peerId).editingMessageId != nil
    updateSendButtonForEditing(isEditing)

    if isEditing {
      // Stop draft timer when editing a message
      stopDraftSaveTimer()

      if let messageId = ChatState.shared.getState(peer: peerId).editingMessageId,
         let message = try? FullMessage.get(messageId: messageId, chatId: chatId)
      {
        textView.text = message.message.text
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

  // MARK: - Overlay Management

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

  // MARK: - Image Handling

  private func presentPicker() {
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

  private func presentCamera() {
    let status = AVCaptureDevice.authorizationStatus(for: .video)

    switch status {
      case .notDetermined:
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
          if granted {
            DispatchQueue.main.async {
              self?.showCameraPicker()
            }
          }
        }
      case .authorized:
        showCameraPicker()
      default:
        Log.shared.error("Failed to presentCamera")
    }
  }

  private func showCameraPicker() {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = self
    picker.allowsEditing = false

    if let windowScene = window?.windowScene,
       let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
       let rootVC = keyWindow.rootViewController
    {
      rootVC.present(picker, animated: true)
    }
  }

  private func handleDroppedImage(_ image: UIImage) {
    selectedImage = image
    previewViewModel.isPresented = true

    let previewView = PhotoPreviewView(
      image: image,
      caption: Binding(
        get: { [weak self] in self?.previewViewModel.caption ?? "" },
        set: { [weak self] newValue in self?.previewViewModel.caption = newValue }
      ),
      isPresented: Binding(
        get: { [weak self] in self?.previewViewModel.isPresented ?? false },
        set: { [weak self] newValue in
          self?.previewViewModel.isPresented = newValue
          if !newValue {
            self?.dismissPreview()
          }
        }
      ),
      onSend: { [weak self] image, caption in
        self?.sendImage(image, caption: caption)
      }
    )

    let previewVC = UIHostingController(rootView: previewView)
    previewVC.modalPresentationStyle = .fullScreen
    previewVC.modalTransitionStyle = .crossDissolve

    if let windowScene = window?.windowScene,
       let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
       let rootVC = keyWindow.rootViewController
    {
      rootVC.present(previewVC, animated: true)
    }
  }

  private func dismissPreview() {
    var responder: UIResponder? = self
    var currentVC: UIViewController?

    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController {
        currentVC = viewController
        break
      }
      responder = nextResponder
    }

    guard let currentVC else { return }

    var topmostVC = currentVC
    while let presentedVC = topmostVC.presentedViewController {
      topmostVC = presentedVC
    }

    let picker = topmostVC.presentingViewController as? PHPickerViewController

    topmostVC.dismiss(animated: true) { [weak self] in
      picker?.dismiss(animated: true)
      self?.selectedImage = nil
      self?.previewViewModel.caption = ""
      self?.previewViewModel.isPresented = false
    }
  }

  private func sendImage(_ image: UIImage, caption: String) {
    guard let peerId else { return }

    sendButton.configuration?.showsActivityIndicator = true
    attachmentItems.removeAll()

    do {
      let photoInfo = try FileCache.savePhoto(image: image)
      attachmentItems[image] = .photo(photoInfo)
    } catch {
      Log.shared.error("Failed to save photo", error: error)
    }

    for (_, attachment) in attachmentItems {
      Transactions.shared.mutate(
        transaction: .sendMessage(
          .init(
            text: caption,
            peerId: peerId,
            chatId: chatId ?? 0,
            mediaItems: [attachment],
            replyToMsgId: ChatState.shared.getState(peer: peerId).replyingMessageId
          )
        )
      )
    }

    dismissPreview()
    sendButton.configuration?.showsActivityIndicator = false
    attachmentItems.removeAll()
    // sendMessageHaptic()
  }

  func handlePastedImage() {
    guard let image = UIPasteboard.general.image else { return }

    selectedImage = image
    previewViewModel.isPresented = true

    let previewView = PhotoPreviewView(
      image: image,
      caption: Binding(
        get: { [weak self] in self?.previewViewModel.caption ?? "" },
        set: { [weak self] newValue in self?.previewViewModel.caption = newValue }
      ),
      isPresented: Binding(
        get: { [weak self] in self?.previewViewModel.isPresented ?? false },
        set: { [weak self] newValue in
          self?.previewViewModel.isPresented = newValue
          if !newValue {
            self?.dismissPreview()
          }
        }
      ),
      onSend: { [weak self] image, caption in
        self?.sendImage(image, caption: caption)
      }
    )

    let previewVC = UIHostingController(rootView: previewView)
    previewVC.modalPresentationStyle = .fullScreen
    previewVC.modalTransitionStyle = .crossDissolve

    var responder: UIResponder? = self
    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController {
        viewController.present(previewVC, animated: true)
        break
      }
      responder = nextResponder
    }
  }

  // MARK: - Keyboard Handling for Mentions

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    guard let key = presses.first?.key else {
      super.pressesBegan(presses, with: event)
      return
    }

    var keyString = ""
    switch key.keyCode {
      case .keyboardUpArrow:
        keyString = "ArrowUp"
      case .keyboardDownArrow:
        keyString = "ArrowDown"
      case .keyboardReturnOrEnter:
        keyString = "Enter"
      case .keyboardTab:
        keyString = "Tab"
      case .keyboardEscape:
        keyString = "Escape"
      default:
        super.pressesBegan(presses, with: event)
        return
    }

    // Let mention manager handle the key press
    if mentionManager?.handleKeyPress(keyString) == true {
      // Key was handled by mention manager
      return
    }

    super.pressesBegan(presses, with: event)
  }
}

// MARK: - MentionManagerDelegate

extension ComposeView: MentionManagerDelegate {
  func mentionManager(_ manager: MentionManager, didSelectMention text: String, userId: Int64, for range: NSRange) {
    // Update height if needed after mention replacement
    updateHeight()

    // Clear original entities since we've modified mentions
    originalDraftEntities = nil
  }

  func mentionManagerDidDismiss(_ manager: MentionManager) {
    // Handle mention menu dismissal if needed
  }
}

// MARK: - UITextViewDelegate

extension ComposeView: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    // Prevent mention style leakage to new text
    textView.updateTypingAttributesIfNeeded()

    // Height Management
    UIView.animate(withDuration: 0.1) { self.updateHeight() }

    // Placeholder Visibility & Attachment Checks
    let isEmpty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    (textView as? ComposeTextView)?.showPlaceholder(isEmpty)
    // (textView as? ComposeTextView)?.checkForNewAttachments()

    // Handle mention detection
    mentionManager?.handleTextChange(in: textView)

    if isEmpty {
      clearDraft()
      stopDraftSaveTimer()
      buttonDisappear()
      if let peerId {
        Task {
          await ComposeActions.shared.stoppedTyping(for: peerId)
        }
      }
    } else {
      startDraftSaveTimer()
      if let peerId {
        Task {
          await ComposeActions.shared.startedTyping(for: peerId)
        }
      }
      buttonAppear()
    }
  }

  func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
    if text.contains("￼") {
      DispatchQueue.main.async(qos: .userInitiated) { [weak self] in
        self?.textView.textDidChange()
      }
    }

    // Check if the change might affect existing mentions
    if let originalEntities = originalDraftEntities, !originalEntities.entities.isEmpty {
      // Check if the change overlaps with any existing mention ranges
      for entity in originalEntities.entities {
        let entityRange = NSRange(location: Int(entity.offset), length: Int(entity.length))
        if NSIntersectionRange(range, entityRange).length > 0 {
          // The change affects a mention, clear original entities
          originalDraftEntities = nil
          break
        }
      }
    }

    return true
  }

  func textViewDidChangeSelection(_ textView: UITextView) {
    // Reset typing attributes when cursor moves to prevent mention style leakage
    textView.updateTypingAttributesIfNeeded()
  }
}

// MARK: - PHPickerViewControllerDelegate

extension ComposeView: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    guard let result = results.first else {
      picker.dismiss(animated: true)
      return
    }

    result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self, weak picker] object, error in
      guard let self, let picker else { return }

      if let error {
        Log.shared.debug("Failed to load image:", file: error.localizedDescription)
        DispatchQueue.main.async {
          picker.dismiss(animated: true)
        }
        return
      }

      guard let image = object as? UIImage else {
        DispatchQueue.main.async {
          picker.dismiss(animated: true)
        }
        return
      }

      DispatchQueue.main.async {
        self.selectedImage = image
        self.previewViewModel.isPresented = true

        let previewView = PhotoPreviewView(
          image: image,
          caption: Binding(
            get: { [weak self] in self?.previewViewModel.caption ?? "" },
            set: { [weak self] newValue in self?.previewViewModel.caption = newValue }
          ),
          isPresented: Binding(
            get: { [weak self] in self?.previewViewModel.isPresented ?? false },
            set: { [weak self] newValue in
              self?.previewViewModel.isPresented = newValue
              if !newValue {
                self?.dismissPreview()
              }
            }
          ),
          onSend: { [weak self] image, caption in
            self?.sendImage(image, caption: caption)
          }
        )

        let previewVC = UIHostingController(rootView: previewView)
        previewVC.modalPresentationStyle = .fullScreen
        previewVC.modalTransitionStyle = .crossDissolve

        picker.present(previewVC, animated: true)
      }
    }
  }
}

// MARK: - UIImagePickerControllerDelegate

extension ComposeView {
  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    guard let image = info[.originalImage] as? UIImage else {
      picker.dismiss(animated: true)
      return
    }

    // Save the captured photo to the photo library
    if picker.sourceType == .camera {
      UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }

    picker.dismiss(animated: true) { [weak self] in
      self?.handleDroppedImage(image)
    }
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
  }
}

// MARK: - UIDropInteractionDelegate

extension ComposeView: UIDropInteractionDelegate {
  func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
    session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier])
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
    UIDropProposal(operation: .copy)
  }

  func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
    for provider in session.items {
      provider.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] (
        image: NSItemProviderReading?,
        _: Error?
      ) in
        guard let image = image as? UIImage else { return }

        DispatchQueue.main.async {
          self?.handleDroppedImage(image)
        }
      }
    }
  }
}
