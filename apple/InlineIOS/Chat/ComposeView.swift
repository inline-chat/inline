import AVFoundation
import Combine
import CoreServices
import ImageIO
import InlineKit
import Logger
import MobileCoreServices
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - ComposeTextView Implementation

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
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
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

    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: topAnchor),
      textView.bottomAnchor.constraint(equalTo: bottomAnchor),
      textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -42),
    ])
  }
}

// MARK: - Main ComposeView Implementation

class ComposeView: UIView, NSTextLayoutManagerDelegate,
  UIImagePickerControllerDelegate & UINavigationControllerDelegate
{
  // MARK: Configuration Constants

  static let minHeight: CGFloat = 42.0
  private let maxHeight: CGFloat = 600
  private var composeHeightConstraint: NSLayoutConstraint!
  private var prevTextHeight: CGFloat = 0.0
  static let textViewVerticalPadding: CGFloat = 9.0
  static let textViewHorizantalPadding: CGFloat = 12.0
  static let textViewHorizantalMargin: CGFloat = 7.0
  static let textViewVerticalMargin: CGFloat = 7.0
  private let buttonBottomPadding: CGFloat = -4.0
  private let buttonTrailingPadding: CGFloat = -6.0
  private let buttonLeadingPadding: CGFloat = 10.0
  private let buttonSize: CGSize = .init(width: 36, height: 36)
  private var overlayView: UIView?
  private var isOverlayVisible = false
  private var phaseObserver: AnyCancellable?

  // MARK: UI Components

  lazy var textView: ComposeTextView = makeTextView()

  lazy var textViewContainer: TextViewContainer = {
    let container = TextViewContainer(textView: textView)
    container.translatesAutoresizingMaskIntoConstraints = false
    return container
  }()

  lazy var sendButtonContainer: UIView = {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.isUserInteractionEnabled = true
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(sendTapped))
    container.addGestureRecognizer(tapGesture)
    container.alpha = 0
    return container
  }()

  lazy var sendButton = makeSendButton()
  lazy var plusButton = makePlusButton()

  // MARK: State Management

  var selectedImage: UIImage?
  var showingPhotoPreview: Bool = false
  var imageCaption: String = ""
  let previewViewModel = PhotoPreviewViewModel()
  var attachmentItems: [UIImage: FileMediaItem] = [:]

  var onHeightChange: ((CGFloat) -> Void)?
  var peerId: Peer?
  var chatId: Int64?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
    setupScenePhaseObserver()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: Setup & Layout

  private func setupViews() {
    backgroundColor = .clear
    addSubview(textViewContainer)
    addSubview(sendButtonContainer)
    sendButtonContainer.addSubview(sendButton)
    addSubview(plusButton)

    composeHeightConstraint = heightAnchor.constraint(equalToConstant: Self.minHeight)

    NSLayoutConstraint.activate([
      composeHeightConstraint,

      textViewContainer.leadingAnchor.constraint(equalTo: plusButton.trailingAnchor, constant: 8),
      textViewContainer.topAnchor.constraint(equalTo: topAnchor),
      textViewContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
      textViewContainer.trailingAnchor.constraint(equalTo: trailingAnchor),

      sendButtonContainer.trailingAnchor.constraint(
        equalTo: textViewContainer.trailingAnchor,
        constant: 6
      ),
      sendButtonContainer.bottomAnchor.constraint(
        equalTo: textViewContainer.bottomAnchor,
        constant: 7
      ),
      sendButtonContainer.widthAnchor.constraint(equalToConstant: buttonSize.width + 20),
      sendButtonContainer.heightAnchor.constraint(equalToConstant: buttonSize.height + 20),

      sendButton.centerXAnchor.constraint(equalTo: sendButtonContainer.centerXAnchor),
      sendButton.centerYAnchor.constraint(equalTo: sendButtonContainer.centerYAnchor),
      sendButton.widthAnchor.constraint(equalToConstant: buttonSize.width - 2),
      sendButton.heightAnchor.constraint(equalToConstant: buttonSize.height - 2),

      plusButton.leadingAnchor.constraint(equalTo: leadingAnchor),
      plusButton.bottomAnchor.constraint(equalTo: textViewContainer.bottomAnchor, constant: -3),
      plusButton.widthAnchor.constraint(equalToConstant: Self.minHeight - 6),
      plusButton.heightAnchor.constraint(equalToConstant: Self.minHeight - 6),
    ])

    // Add drop interaction
    let dropInteraction = UIDropInteraction(delegate: self)
    addInteraction(dropInteraction)
  }

  private func makeTextView() -> ComposeTextView {
    let textView = ComposeTextView()
    textView.font = .systemFont(ofSize: 17)
    textView.isScrollEnabled = true
    textView.backgroundColor = .clear
    textView.textContainerInset = UIEdgeInsets(
      top: Self.textViewVerticalPadding,
      left: 0,
      bottom: Self.textViewVerticalPadding,
      right: 0
    )
    textView.delegate = self
    textView.textLayoutManager?.delegate = self
    textView.translatesAutoresizingMaskIntoConstraints = false

    if #available(iOS 16.0, *) {
      textView.usesStandardTextScaling = true
    }

    return textView
  }

  private func makeSendButton() -> UIButton {
    let button = UIButton()
    button.translatesAutoresizingMaskIntoConstraints = false
    button.frame = CGRect(origin: .zero, size: buttonSize)
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "arrow.up")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
    )
    config.baseForegroundColor = .white
    config.background.backgroundColor = ColorManager.shared.selectedColor
    config.cornerStyle = .capsule

    button.configuration = config
    button.isUserInteractionEnabled = false
    return button
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
    button.layer.cornerRadius = Self.minHeight / 2
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
      handler: { _ in
        self.presentCamera()
      }
    )

    button.menu = UIMenu(children: [libraryAction, cameraAction])
    button.showsMenuAsPrimaryAction = true

    return button
  }

  @objc private func sendTapped() {
    guard let peerId else { return }

    guard let text = textViewContainer.textView.text?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty
    else { return }
    guard let chatId else { return }

    let replyToMessageId = ChatState.shared.getState(peer: peerId).replyingMessageId
    let canSend = !text.isEmpty

    if canSend {
      let _ = Transactions.shared.mutate(
        transaction:
        .sendMessage(
          .init(
            text: text,
            peerId: peerId,
            chatId: chatId,
            replyToMsgId: replyToMessageId
          )
        )
      )

      UnreadManager.shared.readAll(peerId, chatId: chatId)
      clearDraft()
      ChatState.shared.clearReplyingMessageId(peer: peerId)
      sendMessageHaptic()
      textViewContainer.textView.text = ""
      resetHeight()
      textViewContainer.textView.showPlaceholder(true)
      buttonDisappear()
    }
  }

  @objc private func presentPicker() {
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
    let layoutManager = textViewContainer.textView.layoutManager
    let textContainer = textViewContainer.textView.textContainer

    // layoutManager.ensureLayout(for: textContainer)
    let contentHeight = layoutManager.usedRect(for: textContainer).height

    // Ignore small height changes
    if abs(prevTextHeight - contentHeight) < 8.0 {
      return
    }

    prevTextHeight = contentHeight

    let newHeight = textViewHeightByContentHeight(contentHeight)
    guard abs(composeHeightConstraint.constant - newHeight) > 1 else { return }

    composeHeightConstraint.constant = newHeight
    superview?.layoutIfNeeded()

    onHeightChange?(newHeight)
  }

  private func resetHeight() {
    UIView.animate(withDuration: 0.2) {
      self.composeHeightConstraint.constant = Self.minHeight
      self.superview?.layoutIfNeeded()
    }
    onHeightChange?(Self.minHeight)
  }

  func buttonDisappear() {
    UIView.animate(withDuration: 0.06, delay: 0, options: .curveEaseIn) {
      self.sendButtonContainer.alpha = 0
      self.sendButtonContainer.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
    }
  }

  func buttonAppear() {
    UIView.animate(withDuration: 0.06, delay: 0, options: .curveEaseOut) {
      self.sendButtonContainer.alpha = 1
      self.sendButtonContainer.transform = .identity
    }
  }

  func sendMessageHaptic() {
    let generator = UIImpactFeedbackGenerator(style: .medium)
    generator.prepare()
    generator.impactOccurred()
  }

  override func removeFromSuperview() {
    saveDraft()
    super.removeFromSuperview()
  }

  func setDraft(_ draft: String?) {
    if let draft, !draft.isEmpty {
      textViewContainer.textView.text = draft
      textViewContainer.textView.showPlaceholder(false)
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

    guard let currentVC else {
      return
    }

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

  // MARK: - Camera Handling

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

  private func sendImage(_ image: UIImage, caption: String) {
    guard let peerId else { return }
    print("Sending image", image)
    DispatchQueue.main.async {
      self.sendButton.configuration?.showsActivityIndicator = true

      Task {
        self.attachmentItems.removeAll()

        do {
          let photoInfo = try FileCache.shared.savePhoto(image: image)
          self.attachmentItems[image] = .photo(photoInfo)
        } catch {
          Log.shared.error("Failed to save photo", error: error)
        }
        print("Attachment items", self.attachmentItems)

        for (index, (_, attachment)) in self.attachmentItems.enumerated() {
          _ = index == 0
          let _ = Transactions.shared.mutate(
            transaction: .sendMessage(
              .init(
                text: caption,
                peerId: self.peerId!,
                chatId: self.chatId ?? 0,
                mediaItems: [attachment],
                replyToMsgId: ChatState.shared.getState(peer: peerId).replyingMessageId
              )
            )
          )
          print("Sent attachment", attachment)
        }

        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          sendMessageHaptic()
          dismissPreview()
          sendButton.configuration?.showsActivityIndicator = false
          attachmentItems.removeAll()
        }
      }
    }
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

  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    guard let image = info[.originalImage] as? UIImage else {
      picker.dismiss(animated: true)
      return
    }

    picker.dismiss(animated: true) { [weak self] in
      self?.handleDroppedImage(image)
    }
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
  }

  private func setupScenePhaseObserver() {
    // Save draft when app moves to background
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(saveCurrentDraft),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )

    // Save draft when force-quits the app from the app switcher
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(saveCurrentDraft),
      name: UIApplication.willTerminateNotification,
      object: nil
    )

    // Save draft when app becomes inactive
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(saveCurrentDraft),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
  }

  @objc private func saveCurrentDraft() {
    saveDraft()
  }

  private func saveDraft() {
    guard let peerId else { return }

    if let text = textViewContainer.textView.text, !text.isEmpty {
      Task {
        do {
          try await DataManager.shared.updateDialog(peerId: peerId, draft: text)
        } catch {
          print("Failed to save draft", error)
        }
      }
    }
  }

  private func clearDraft() {
    guard let peerId else { return }

    Task {
      do {
        try await DataManager.shared.updateDialog(peerId: peerId, draft: nil)
      } catch {
        print("Failed to clear draft", error)
      }
    }
  }
}

// MARK: - User Interaction Handling

extension ComposeView: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    // Height Management
    UIView.animate(withDuration: 0.2) { self.updateHeight() }

    // Placeholder Visibility
    let isEmpty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    textViewContainer.textView.showPlaceholder(isEmpty)

    // Typing Indicators - only for DMs
    if isEmpty {
      buttonDisappear()
      if let peerId, case .user = peerId {
        Task {
          await ComposeActions.shared.stoppedTyping(for: peerId)
        }
      }
    } else {
      if let peerId, case .user = peerId {
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
    guard let result = results.first else {
      picker.dismiss(animated: true)
      return
    }

    result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self, weak picker] object, error in
      guard let self, let picker else { return }

      if let error {
        print("Failed to load image:", error.localizedDescription)
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
