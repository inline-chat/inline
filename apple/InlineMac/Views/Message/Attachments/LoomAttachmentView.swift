import AppKit
import InlineKit

class LoomAttachmentView: NSView, AttachmentView {
  // MARK: - Constants

  private enum Constants {
    static let cornerRadius: CGFloat = 10
    static let padding: CGFloat = 8
    static let spacing: CGFloat = 10
    static let accentWidth: CGFloat = 3
    static let imageSide: CGFloat = 68
    static let playIconSize: CGFloat = 18
    static let loomTagFontSize: CGFloat = 10
  }

  // MARK: - Properties

  let fullAttachment: FullAttachment
  let message: Message

  var attachment: Attachment {
    fullAttachment.attachment
  }

  private var previewURL: URL?

  // MARK: - UI

  private lazy var accentView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    return view
  }()

  private lazy var backgroundView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.cornerRadius = Constants.cornerRadius
    view.layer?.masksToBounds = true
    return view
  }()

  private lazy var contentStack: NSStackView = {
    let stack = NSStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .horizontal
    stack.spacing = Constants.spacing
    stack.alignment = .centerY
    stack.detachesHiddenViews = true
    return stack
  }()

  private lazy var imageContainer: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.cornerRadius = 6
    view.layer?.masksToBounds = true
    view.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
    view.setContentCompressionResistancePriority(.required, for: .horizontal)
    return view
  }()

  private lazy var textStack: NSStackView = {
    let stack = NSStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.spacing = 4
    stack.alignment = .leading
    stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
    stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return stack
  }()

  private lazy var loomTagLabel: NSTextField = {
    let label = NSTextField(labelWithString: "Loom")
    label.font = .systemFont(ofSize: Constants.loomTagFontSize, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.maximumNumberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private lazy var titleLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: Theme.messageTextFontSize, weight: .semibold)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    return label
  }()

  private lazy var descriptionLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: Theme.messageTextFontSize - 1)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 2
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private lazy var placeholderImageView: NSImageView = {
    let view = NSImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.image = nil
    view.contentTintColor = .clear
    view.imageScaling = .scaleProportionallyUpOrDown
    view.wantsLayer = true
    view.layer?.cornerRadius = 6
    view.layer?.masksToBounds = true
    view.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.08).cgColor
    return view
  }()

  private lazy var imageView: NSImageView = {
    let view = NSImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.imageScaling = .scaleProportionallyUpOrDown
    view.wantsLayer = true
    view.layer?.cornerRadius = 6
    view.layer?.masksToBounds = true
    view.isHidden = true
    return view
  }()

  private lazy var playIconView: NSImageView = {
    let view = NSImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.symbolConfiguration = .init(pointSize: Constants.playIconSize, weight: .medium)
    view.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
    view.contentTintColor = .secondaryLabelColor
    view.imageScaling = .scaleProportionallyUpOrDown
    return view
  }()

  // MARK: - Init

  init(fullAttachment: FullAttachment, message: Message) {
    self.fullAttachment = fullAttachment
    self.message = message

    super.init(frame: .zero)

    guard fullAttachment.urlPreview != nil else { return }

    setup()
    configure()
    addClickGesture()
    updateColors()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setup() {
    wantsLayer = true
    layer?.cornerRadius = Constants.cornerRadius
    layer?.masksToBounds = true
    translatesAutoresizingMaskIntoConstraints = false

    addSubview(backgroundView)
    addSubview(accentView)
    addSubview(contentStack)

    // Layout
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Theme.loomPreviewHeight),

      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      accentView.leadingAnchor.constraint(equalTo: leadingAnchor),
      accentView.topAnchor.constraint(equalTo: topAnchor),
      accentView.bottomAnchor.constraint(equalTo: bottomAnchor),
      accentView.widthAnchor.constraint(equalToConstant: Constants.accentWidth),

      contentStack.leadingAnchor.constraint(equalTo: accentView.trailingAnchor, constant: Constants.padding),
      contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Constants.padding),
      contentStack.topAnchor.constraint(equalTo: topAnchor, constant: Constants.padding),
      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Constants.padding),
    ])

    contentStack.addArrangedSubview(imageContainer)
    contentStack.addArrangedSubview(textStack)

    NSLayoutConstraint.activate([
      imageContainer.widthAnchor.constraint(equalToConstant: Constants.imageSide),
      imageContainer.heightAnchor.constraint(equalToConstant: Constants.imageSide),
    ])

    imageContainer.addSubview(placeholderImageView)
    imageContainer.addSubview(imageView)
    NSLayoutConstraint.activate([
      placeholderImageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
      placeholderImageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
      placeholderImageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
      placeholderImageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
      imageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
    ])

    textStack.addArrangedSubview(loomTagLabel)
    textStack.addArrangedSubview(titleLabel)
    textStack.addArrangedSubview(descriptionLabel)
  }

  private func configure() {
    guard let preview = fullAttachment.urlPreview else { return }

    previewURL = URL(string: preview.url)
    toolTip = preview.title ?? preview.url

    titleLabel.stringValue = preview.title ?? "Loom video"
    descriptionLabel.stringValue = preview.description ?? "Open in Loom"
    setAccessibilityLabel("Loom: \(titleLabel.stringValue)")
    setAccessibilityRole(.group)

    if let photoInfo = fullAttachment.photoInfo,
       let bestSize = photoInfo.bestPhotoSize()
    {
      let photoURL: URL? =
        (bestSize.localPath.flatMap { FileCache.getUrl(for: .photos, localPath: $0) }) ??
        (bestSize.cdnUrl.flatMap { URL(string: $0) })

      guard let photoURL else {
        placeholderImageView.isHidden = false
        imageView.isHidden = true
        return
      }

      placeholderImageView.isHidden = false
      imageView.isHidden = true

      let cacheKey = "loom-photo-\(photoInfo.id)"
      ImageCacheManager.shared.image(for: photoURL, loadSync: true, cacheKey: cacheKey) { [weak self] image in
        guard let self else { return }
        if let image {
          imageView.image = image
          imageView.isHidden = false
          placeholderImageView.isHidden = true
        } else {
          imageView.image = nil
          imageView.isHidden = true
          placeholderImageView.isHidden = false
        }
      }
    } else {
      placeholderImageView.isHidden = false
      imageView.isHidden = true
    }
  }

  private func addClickGesture() {
    let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
    addGestureRecognizer(clickGesture)
  }

  @objc private func handleClick() {
    guard let previewURL else { return }
    NSWorkspace.shared.open(previewURL)
  }

  // MARK: - Colors

  private var accentColor: NSColor {
    message.outgoing ? .white.withAlphaComponent(0.8) : .controlAccentColor
  }

  private var backgroundColor: NSColor {
    message.outgoing ? .white.withAlphaComponent(0.08) : .labelColor.withAlphaComponent(0.02)
  }

  private var primaryTextColor: NSColor {
    message.outgoing ? .white : .labelColor
  }

  private var secondaryTextColor: NSColor {
    message.outgoing ? .white.withAlphaComponent(0.8) : .secondaryLabelColor
  }

  private var tagTextColor: NSColor {
    message.outgoing ? .white.withAlphaComponent(0.75) : .tertiaryLabelColor
  }

  private func updateColors() {
    layer?.backgroundColor = backgroundColor.cgColor
    backgroundView.layer?.backgroundColor = backgroundColor.cgColor
    accentView.layer?.backgroundColor = accentColor.cgColor
    titleLabel.textColor = primaryTextColor
    descriptionLabel.textColor = secondaryTextColor
    loomTagLabel.textColor = tagTextColor
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateColors()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }
}
