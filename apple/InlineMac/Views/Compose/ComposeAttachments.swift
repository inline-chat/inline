import AppKit
import InlineKit

class ComposeAttachments: NSView {
  private weak var compose: ComposeAppKit?
  private var attachments: [String: ImageAttachmentView] = [:]
  private var videoAttachments: [String: VideoAttachmentView] = [:]
  private var docAttachments: [String: DocumentView] = [:]

  private let stackView: NSStackView
  private let filesStackView: NSStackView

  init(frame: NSRect, compose: ComposeAppKit) {
    self.compose = compose

    stackView = NSStackView(frame: .zero)
    stackView.orientation = .horizontal
    stackView.spacing = 8
    stackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    stackView.translatesAutoresizingMaskIntoConstraints = false

    filesStackView = NSStackView(frame: .zero)
    filesStackView.orientation = .vertical
    filesStackView.alignment = .leading
    filesStackView.spacing = 0
    filesStackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    filesStackView.translatesAutoresizingMaskIntoConstraints = false

    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var heightConstraint: NSLayoutConstraint!
  private var verticalPadding: CGFloat = Theme.composeAttachmentsVPadding

  // Modify updateHeight to be public and return the height
  func getHeight() -> CGFloat {
    if attachments.isEmpty, docAttachments.isEmpty, videoAttachments.isEmpty {
      return 0
    }

    let paddings = 2 * verticalPadding
    let imagesHeight = (attachments.isEmpty && videoAttachments.isEmpty) ? 0 : Theme.composeAttachmentImageHeight
    let documentsHeight = docAttachments.isEmpty ? 0 : Theme.documentViewHeight * CGFloat(docAttachments.count)
    return paddings + imagesHeight + documentsHeight
  }

  public func updateHeight(animated: Bool = false) {
    if animated {
      heightConstraint.animator().constant = getHeight()
    } else {
      heightConstraint.constant = getHeight()
    }
  }

  private func setupView() {
    clipsToBounds = true

    heightConstraint = heightAnchor.constraint(equalToConstant: getHeight())

    addSubview(stackView)
    addSubview(filesStackView)

    NSLayoutConstraint.activate([
      heightConstraint,

      // no top for stack.
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      // stackView.bottomAnchor.constraint(equalTo: bottomAnchor),

      // files stack
      filesStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      filesStackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      filesStackView.bottomAnchor.constraint(equalTo: bottomAnchor),
      filesStackView.topAnchor.constraint(equalTo: stackView.bottomAnchor),
    ])
  }

  public func removeImageView(id: String) {
    if let attachment = attachments[id] {
      attachments.removeValue(forKey: id)

      if attachments.isEmpty {
        // animate last one
        attachment.fadeOut { [weak self] in
          self?.stackView.removeArrangedSubview(attachment)
          attachment.removeFromSuperview()
        }
        return
      }

      stackView.removeArrangedSubview(attachment)
      attachment.removeFromSuperview()
    }
  }

  public func addImageView(_ image: NSImage, id: String) {
    let attachmentView = ImageAttachmentView(image: image) { [weak self] in
      self?.compose?.removeImage(id)
    }
    attachmentView.translatesAutoresizingMaskIntoConstraints = false
    attachments[id] = attachmentView

    stackView.addArrangedSubview(attachmentView)

    attachmentView.fadeIn()
  }

  public func addDocumentView(_ documentInfo: DocumentInfo, id: String) {
    // Check if we already have this document
    if let existingView = docAttachments[id] {
      existingView.update(with: documentInfo)
      return
    }

    // Create a new document view
    let documentView = DocumentView(
      documentInfo: documentInfo,
      removeAction: { [weak self] in
        self?.compose?.removeFile(id)
      }
    )

    documentView.translatesAutoresizingMaskIntoConstraints = false
    docAttachments[id] = documentView

    filesStackView.addArrangedSubview(documentView)

    // Animate the appearance
    documentView.fadeIn()

    // Update height
    updateHeight()
  }

  public func removeDocumentView(id: String) {
    if let documentView = docAttachments[id] {
      docAttachments.removeValue(forKey: id)

      if docAttachments.isEmpty {
        // Animate removal of last document
        documentView.fadeOut { [weak self] in
          self?.filesStackView.removeArrangedSubview(documentView)
          documentView.removeFromSuperview()
        }
      } else {
        // Remove without animation if there are other documents
        filesStackView.removeArrangedSubview(documentView)
        documentView.removeFromSuperview()
      }

      // Update height
      updateHeight()
    }
  }

  // Add this method to clear all document views
  public func clearDocumentViews(animated: Bool = false) {
    for (_, documentView) in docAttachments {
      filesStackView.removeArrangedSubview(documentView)
      documentView.removeFromSuperview()
    }

    docAttachments.removeAll()
  }

  public func addVideoView(_ videoInfo: VideoInfo, id: String) {
    if videoAttachments[id] != nil { return }

    let thumbnail: NSImage? = {
      guard let localPath = videoInfo.thumbnail?.sizes.first?.localPath else { return nil }
      let url = FileHelpers.getLocalCacheDirectory(for: .photos).appendingPathComponent(localPath)
      return NSImage(contentsOf: url)
    }()

    let videoURL: URL? = {
      guard let localPath = videoInfo.video.localPath else { return nil }
      return FileHelpers.getLocalCacheDirectory(for: .videos).appendingPathComponent(localPath)
    }()

    let view = VideoAttachmentView(thumbnail: thumbnail, videoURL: videoURL) { [weak self] in
      self?.compose?.removeVideo(id)
    }

    videoAttachments[id] = view
    stackView.addArrangedSubview(view)
    view.fadeIn()
    updateHeight()
  }

  public func removeVideoView(id: String) {
    guard let view = videoAttachments[id] else { return }
    videoAttachments.removeValue(forKey: id)
    stackView.removeArrangedSubview(view)
    view.removeFromSuperview()
    updateHeight()
  }

  public func clearViews(animated: Bool = false) {
    // Clear images
    for (_, value) in attachments {
      stackView.removeArrangedSubview(value)
      value.removeFromSuperview()
    }
    attachments.removeAll()

    // Clear videos
    for (_, value) in videoAttachments {
      stackView.removeArrangedSubview(value)
      value.removeFromSuperview()
    }
    videoAttachments.removeAll()

    // Clear documents
    clearDocumentViews(animated: animated)
  }
}

extension NSView {
  func fadeOut(completionHandler: (() -> Void)?) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      animator().alphaValue = 0
    } completionHandler: {
      completionHandler?()
    }
  }

  func fadeIn() {
    wantsLayer = true
    layer?.opacity = 0
    DispatchQueue.main.async { [weak self] in
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.allowsImplicitAnimation = true
        self?.layer?.opacity = 1
      }
    }
  }
}
