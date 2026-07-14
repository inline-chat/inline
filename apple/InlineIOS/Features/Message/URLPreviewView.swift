import InlineKit
import InlineUI
import UIKit

class URLPreviewView: UIView, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
  enum Mode {
    case compact
    case large
  }

  struct NeverShowPreviewAction {
    let host: String
    let action: () -> Void
  }

  private enum Metrics {
    static let compactImageSize = CGSize(width: 32, height: 32)
    static let authorAvatarSize: CGFloat = 26
    static let largeCornerRadius: CGFloat = 14
    static let largeContentPadding: CGFloat = 12
    static let largeContentVerticalPadding: CGFloat = 10
    static let largeSectionSpacing: CGFloat = 6
    static let largeTextTrailingPadding: CGFloat = 14
    static let imageCornerRadius: CGFloat = 6
    static let playOverlaySize: CGFloat = 34
    static let playIconSize: CGFloat = 14
    static let providerPlaceholderSize: CGFloat = 24
    static let pressedScale: CGFloat = 0.97
  }

  private let rectangleView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.layer.mask = CAShapeLayer()
    return view
  }()

  private let titleLabel = UILabel()
  private let descriptionLabel = UILabel()
  private let authorLabel = UILabel()
  private let authorSubtitleLabel = UILabel()
  private let imageContainer: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.layer.cornerRadius = Metrics.imageCornerRadius
    view.layer.masksToBounds = true
    view.isHidden = true
    view.isUserInteractionEnabled = false
    return view
  }()

  private let imageView: PlatformPhotoView = {
    let view = PlatformPhotoView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.photoContentMode = .aspectFill
    view.showsTinyThumbnailBackground = true
    view.showsLoadingPlaceholder = true
    view.isUserInteractionEnabled = false
    return view
  }()

  private let authorAvatarView: PlatformPhotoView = {
    let view = PlatformPhotoView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.photoContentMode = .aspectFill
    view.showsTinyThumbnailBackground = true
    view.showsLoadingPlaceholder = true
    view.layer.cornerRadius = Metrics.authorAvatarSize / 2
    view.layer.masksToBounds = true
    view.isUserInteractionEnabled = false
    return view
  }()

  private let playOverlayView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = UIColor.black.withAlphaComponent(0.46)
    view.layer.cornerRadius = Metrics.playOverlaySize / 2
    view.layer.masksToBounds = true
    view.isHidden = true
    view.isUserInteractionEnabled = false
    return view
  }()

  private let playIconView: UIImageView = {
    let view = UIImageView(image: UIImage(systemName: "play.fill"))
    view.translatesAutoresizingMaskIntoConstraints = false
    view.contentMode = .scaleAspectFit
    view.tintColor = .white
    view.isHidden = true
    view.isUserInteractionEnabled = false
    return view
  }()

  private let providerPlaceholderView: UIImageView = {
    let view = UIImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.contentMode = .scaleAspectFit
    view.isHidden = true
    view.isUserInteractionEnabled = false
    return view
  }()

  private weak var parentViewController: UIViewController?
  private var previewUrl: URL?
  private var canRemove = false
  private var onRemove: (() -> Void)?
  private var neverShowPreviewActionProvider: (() -> NeverShowPreviewAction?)?
  private var activeConstraints: [NSLayoutConstraint] = []
  private var pressed = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupImageContainer()
    setupTapGesture()
    setupContextMenu()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupImageContainer()
    setupTapGesture()
    setupContextMenu()
  }

  private func setupImageContainer() {
    imageContainer.addSubview(imageView)
    imageContainer.addSubview(providerPlaceholderView)
    imageContainer.addSubview(playOverlayView)
    playOverlayView.addSubview(playIconView)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),

      providerPlaceholderView.centerXAnchor.constraint(equalTo: imageContainer.centerXAnchor),
      providerPlaceholderView.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor),
      providerPlaceholderView.widthAnchor.constraint(equalToConstant: Metrics.providerPlaceholderSize),
      providerPlaceholderView.heightAnchor.constraint(equalToConstant: Metrics.providerPlaceholderSize),

      playOverlayView.centerXAnchor.constraint(equalTo: imageContainer.centerXAnchor),
      playOverlayView.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor),
      playOverlayView.widthAnchor.constraint(equalToConstant: Metrics.playOverlaySize),
      playOverlayView.heightAnchor.constraint(equalToConstant: Metrics.playOverlaySize),

      playIconView.centerXAnchor.constraint(equalTo: playOverlayView.centerXAnchor),
      playIconView.centerYAnchor.constraint(equalTo: playOverlayView.centerYAnchor),
      playIconView.widthAnchor.constraint(equalToConstant: Metrics.playIconSize),
      playIconView.heightAnchor.constraint(equalToConstant: Metrics.playIconSize),
    ])
  }

  private func setupTapGesture() {
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    tap.delegate = self
    addGestureRecognizer(tap)
    isUserInteractionEnabled = true
  }

  private func setupContextMenu() {
    addInteraction(UIContextMenuInteraction(delegate: self))
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      for gesture in gestureRecognizers ?? [] where gesture is UILongPressGestureRecognizer {
        gesture.delegate = self
      }
    }
  }

  @objc private func handleTap() {
    guard let url = previewUrl else { return }
    InAppBrowser.shared.open(url, from: currentPresenter())
  }

  private func currentPresenter() -> UIViewController? {
    findViewController() ?? parentViewController
  }

  private func findViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController {
        return viewController
      }
      responder = nextResponder
    }
    return nil
  }

  func configure(
    with preview: UrlPreview,
    photoInfo: PhotoInfo?,
    authorPhotoInfo: PhotoInfo? = nil,
    parentViewController: UIViewController?,
    outgoing: Bool,
    mode: Mode = .compact,
    reloadMessageOnFinish message: Message? = nil,
    canRemove: Bool = false,
    onRemove: (() -> Void)? = nil,
    neverShowPreviewActionProvider: (() -> NeverShowPreviewAction?)? = nil
  ) {
    self.parentViewController = parentViewController
    previewUrl = preview.openURL
    self.canRemove = canRemove
    self.onRemove = onRemove
    self.neverShowPreviewActionProvider = neverShowPreviewActionProvider

    resetLayout()

    let trailingPadding: CGFloat = 8
    let verticalPadding: CGFloat = 6
    let rectangleWidth: CGFloat = 4
    let contentSpacing: CGFloat = 12
    let cornerRadius: CGFloat = mode == .large ? Metrics.largeCornerRadius : 8

    let theme = ThemeManager.shared.selected
    let bgColor = outgoing ? .white.withAlphaComponent(0.1) : theme.secondaryTextColor?
      .withAlphaComponent(0.2) ?? .systemGray5.withAlphaComponent(0.2)
    let primaryTextColor = outgoing ? UIColor.white : (theme.primaryTextColor ?? .label)
    let secondaryTextColor = outgoing ? UIColor.white
      .withAlphaComponent(0.7) : (theme.primaryTextColor?.withAlphaComponent(0.7) ?? .secondaryLabel)
    let tertiaryTextColor = outgoing ? UIColor.white
      .withAlphaComponent(0.55) : (theme.primaryTextColor?.withAlphaComponent(0.55) ?? .tertiaryLabel)

    let isVideo = preview.isVideoPreview
    let display = preview.displayContent(maxDescriptionLength: mode == .large ? 420 : 110)
    let largeDisplay = mode == .large ? preview.largeDisplayContent(maxDescriptionLength: 420) : nil
    let titleText: String? = if let largeDisplay {
      largeDisplay.title
    } else {
      display.title
    }
    let descriptionText: String? = if let largeDisplay {
      largeDisplay.style == .x ? largeDisplay.body : largeDisplay.subtitle
    } else {
      display.subtitle
    }
    let authorName = largeDisplay?.authorName ?? preview.largePreviewAuthorName
    let authorSubtitle = largeDisplay?.authorSubtitle
    let isXStyle = largeDisplay?.style == .x
    let usesMultilineTitle = mode == .large && !isXStyle
    playIconView.tintColor = .white

    titleLabel.text = titleText
    titleLabel.font = UIFont.systemFont(ofSize: mode == .large ? 15 : 13, weight: .medium)
    titleLabel.textColor = primaryTextColor
    titleLabel.numberOfLines = usesMultilineTitle ? 2 : 1
    titleLabel.lineBreakMode = usesMultilineTitle ? .byWordWrapping : .byTruncatingTail
    titleLabel.isHidden = titleText?.isEmpty != false
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.isUserInteractionEnabled = false
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

    let shouldShowDescription = descriptionText != nil
    descriptionLabel.text = descriptionText
    descriptionLabel.font = UIFont.systemFont(ofSize: isXStyle ? 14 : 12)
    descriptionLabel.textColor = isXStyle ? primaryTextColor : secondaryTextColor
    descriptionLabel.numberOfLines = isXStyle ? 0 : 1
    descriptionLabel.lineBreakMode = isXStyle ? .byWordWrapping : .byTruncatingTail
    descriptionLabel.isHidden = !shouldShowDescription
    descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
    descriptionLabel.isUserInteractionEnabled = false
    descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    authorLabel.text = authorName
    authorLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    authorLabel.textColor = primaryTextColor
    authorLabel.numberOfLines = 1
    authorLabel.lineBreakMode = .byTruncatingTail
    authorLabel.translatesAutoresizingMaskIntoConstraints = false
    authorLabel.isUserInteractionEnabled = false
    authorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    authorSubtitleLabel.text = authorSubtitle
    authorSubtitleLabel.font = UIFont.systemFont(ofSize: 11)
    authorSubtitleLabel.textColor = tertiaryTextColor
    authorSubtitleLabel.numberOfLines = 1
    authorSubtitleLabel.lineBreakMode = .byTruncatingTail
    authorSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    authorSubtitleLabel.isUserInteractionEnabled = false
    authorSubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    configureImage(
      photoInfo: photoInfo,
      isVideo: isVideo,
      providerPlaceholderImage: !isVideo && photoInfo == nil && preview.isNotionPreview ? UIImage(named: "notion-logo") : nil,
      backgroundColor: bgColor,
      reloadMessage: message
    )
    imageContainer.layer.cornerRadius = mode == .large ? 0 : Metrics.imageCornerRadius

    let bodyStack = UIStackView()
    bodyStack.axis = .vertical
    bodyStack.spacing = mode == .large ? 0 : 4
    bodyStack.alignment = .fill
    bodyStack.translatesAutoresizingMaskIntoConstraints = false
    bodyStack.isUserInteractionEnabled = false

    let textStack = UIStackView()
    textStack.axis = .vertical
    textStack.spacing = 3
    textStack.alignment = .fill
    textStack.translatesAutoresizingMaskIntoConstraints = false
    textStack.isUserInteractionEnabled = false
    textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    if mode == .large {
      textStack.isLayoutMarginsRelativeArrangement = true
      textStack.insetsLayoutMarginsFromSafeArea = false
      textStack.layoutMargins = UIEdgeInsets(
        top: 0,
        left: 0,
        bottom: 0,
        right: Metrics.largeTextTrailingPadding
      )
    }

    if !titleLabel.isHidden {
      textStack.addArrangedSubview(titleLabel)
    }
    if shouldShowDescription {
      textStack.addArrangedSubview(descriptionLabel)
    }

    if mode == .compact {
      rectangleView.backgroundColor = outgoing ? UIColor.white : theme.accent
      addSubview(rectangleView)

      let rowStack = UIStackView()
      rowStack.axis = .horizontal
      rowStack.spacing = 8
      rowStack.alignment = .center
      rowStack.translatesAutoresizingMaskIntoConstraints = false
      rowStack.isUserInteractionEnabled = false

      if !imageContainer.isHidden {
        rowStack.addArrangedSubview(imageContainer)
        activeConstraints.append(contentsOf: [
          imageContainer.widthAnchor.constraint(equalToConstant: Metrics.compactImageSize.width),
          imageContainer.heightAnchor.constraint(equalToConstant: Metrics.compactImageSize.height),
        ])
      }

      rowStack.addArrangedSubview(textStack)
      bodyStack.addArrangedSubview(rowStack)
    } else {
      if !imageContainer.isHidden {
        bodyStack.addArrangedSubview(imageContainer)
        activeConstraints.append(contentsOf: [
          imageContainer.widthAnchor.constraint(equalTo: bodyStack.widthAnchor),
          imageContainer.heightAnchor.constraint(equalTo: imageContainer.widthAnchor, multiplier: 9.0 / 16.0),
        ])
      }

      let largeContentStack = UIStackView()
      largeContentStack.axis = .vertical
      largeContentStack.spacing = Metrics.largeSectionSpacing
      largeContentStack.alignment = .fill
      largeContentStack.translatesAutoresizingMaskIntoConstraints = false
      largeContentStack.isUserInteractionEnabled = false
      largeContentStack.isLayoutMarginsRelativeArrangement = true
      largeContentStack.layoutMargins = UIEdgeInsets(
        top: Metrics.largeContentVerticalPadding,
        left: Metrics.largeContentPadding,
        bottom: Metrics.largeContentVerticalPadding,
        right: Metrics.largeContentPadding
      )

      if let authorRow = makeAuthorRow(
        preview: preview,
        authorName: authorName,
        authorSubtitle: authorSubtitle,
        authorPhotoInfo: authorPhotoInfo,
        reloadMessage: message
      ) {
        if !textStack.arrangedSubviews.isEmpty {
          largeContentStack.addArrangedSubview(textStack)
        }
        largeContentStack.addArrangedSubview(authorRow)
      } else if !textStack.arrangedSubviews.isEmpty {
        largeContentStack.addArrangedSubview(textStack)
      }
      bodyStack.addArrangedSubview(largeContentStack)
      activeConstraints.append(largeContentStack.widthAnchor.constraint(equalTo: bodyStack.widthAnchor))
    }

    addSubview(bodyStack)

    if mode == .compact {
      activeConstraints.append(contentsOf: [
        rectangleView.leadingAnchor.constraint(equalTo: leadingAnchor),
        rectangleView.widthAnchor.constraint(equalToConstant: rectangleWidth),
        rectangleView.topAnchor.constraint(equalTo: topAnchor),
        rectangleView.bottomAnchor.constraint(equalTo: bottomAnchor),

        bodyStack.leadingAnchor.constraint(equalTo: rectangleView.trailingAnchor, constant: contentSpacing),
        bodyStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingPadding),
        bodyStack.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
        bodyStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
      ])
    } else {
      activeConstraints.append(contentsOf: [
        bodyStack.leadingAnchor.constraint(equalTo: leadingAnchor),
        bodyStack.trailingAnchor.constraint(equalTo: trailingAnchor),
        bodyStack.topAnchor.constraint(equalTo: topAnchor),
        bodyStack.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }

    NSLayoutConstraint.activate(activeConstraints)

    backgroundColor = bgColor
    layer.cornerRadius = cornerRadius
    layer.masksToBounds = true
  }

  private func resetLayout() {
    NSLayoutConstraint.deactivate(activeConstraints)
    activeConstraints.removeAll()
    subviews.forEach { $0.removeFromSuperview() }
    pressed = false
    alpha = 1
    transform = .identity
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Add rounded corners to the accent line
    let path = UIBezierPath(
      roundedRect: rectangleView.bounds,
      byRoundingCorners: [.topLeft, .bottomLeft],
      cornerRadii: CGSize(width: 8, height: 8)
    )
    if let mask = rectangleView.layer.mask as? CAShapeLayer {
      mask.path = path.cgPath
    }
  }

  static func preferredMode(for preview: UrlPreview, photoInfo: PhotoInfo?) -> Mode {
    preview.prefersLargeMediaPreview(hasPhoto: photoInfo != nil) ? .large : .compact
  }

  private func makeAuthorRow(
    preview: UrlPreview,
    authorName: String?,
    authorSubtitle: String?,
    authorPhotoInfo: PhotoInfo?,
    reloadMessage: Message?
  ) -> UIStackView? {
    guard preview.shouldShowLargePreviewAuthor(hasAuthorPhoto: authorPhotoInfo != nil) else {
      authorAvatarView.setPhoto(nil)
      return nil
    }

    let row = UIStackView()
    row.axis = .horizontal
    row.spacing = 6
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    row.isUserInteractionEnabled = false
    row.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    if let authorPhotoInfo {
      authorAvatarView.isHidden = false
      authorAvatarView.setPhoto(authorPhotoInfo, reloadMessageOnFinish: reloadMessage)
      row.addArrangedSubview(authorAvatarView)
      activeConstraints.append(contentsOf: [
        authorAvatarView.widthAnchor.constraint(equalToConstant: Metrics.authorAvatarSize),
        authorAvatarView.heightAnchor.constraint(equalToConstant: Metrics.authorAvatarSize),
      ])
    } else {
      authorAvatarView.isHidden = true
      authorAvatarView.setPhoto(nil)
    }

    if let authorName {
      authorLabel.text = authorName
      authorLabel.isHidden = false
    } else {
      authorLabel.isHidden = true
    }

    if let authorSubtitle {
      authorSubtitleLabel.text = authorSubtitle
      authorSubtitleLabel.isHidden = false
    } else {
      authorSubtitleLabel.isHidden = true
    }

    if !authorLabel.isHidden || !authorSubtitleLabel.isHidden {
      let textStack = UIStackView()
      textStack.axis = .vertical
      textStack.spacing = 0
      textStack.alignment = .fill
      textStack.translatesAutoresizingMaskIntoConstraints = false
      textStack.isUserInteractionEnabled = false
      textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      textStack.addArrangedSubview(authorLabel)
      textStack.addArrangedSubview(authorSubtitleLabel)
      row.addArrangedSubview(textStack)
      activeConstraints.append(textStack.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor))
    }

    return row
  }

  private func configureImage(
    photoInfo: PhotoInfo?,
    isVideo: Bool,
    providerPlaceholderImage: UIImage?,
    backgroundColor: UIColor,
    reloadMessage: Message?
  ) {
    let showsProviderPlaceholder = providerPlaceholderImage != nil
    imageContainer.backgroundColor = showsProviderPlaceholder ? .clear : backgroundColor.withAlphaComponent(0.2)
    imageContainer.isHidden = !isVideo && photoInfo == nil && !showsProviderPlaceholder
    playOverlayView.isHidden = !isVideo
    playIconView.isHidden = !isVideo
    providerPlaceholderView.image = providerPlaceholderImage
    providerPlaceholderView.isHidden = !showsProviderPlaceholder

    guard let photoInfo else {
      imageView.isHidden = showsProviderPlaceholder || isVideo
      imageView.showsLoadingPlaceholder = false
      imageView.setPhoto(nil)
      return
    }

    imageView.isHidden = false
    providerPlaceholderView.isHidden = true
    imageContainer.backgroundColor = backgroundColor.withAlphaComponent(0.2)
    imageView.showsLoadingPlaceholder = true
    imageView.setPhoto(photoInfo, reloadMessageOnFinish: reloadMessage)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesBegan(touches, with: event)
    setPressed(true)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesMoved(touches, with: event)
    guard let touch = touches.first else { return }
    let location = touch.location(in: self)
    setPressed(bounds.insetBy(dx: -12, dy: -12).contains(location))
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    setPressed(false)
    super.touchesEnded(touches, with: event)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    setPressed(false)
    super.touchesCancelled(touches, with: event)
  }

  private func setPressed(_ pressed: Bool) {
    guard self.pressed != pressed else { return }
    self.pressed = pressed

    UIView.animate(
      withDuration: pressed ? 0.08 : 0.14,
      delay: 0,
      options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
    ) {
      self.alpha = pressed ? 0.92 : 1
      self.transform = pressed
        ? CGAffineTransform(scaleX: Metrics.pressedScale, y: Metrics.pressedScale)
        : .identity
    }
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard previewUrl != nil else { return nil }

    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      let openAction = UIAction(
        title: "Open Link",
        image: UIImage(systemName: "safari")
      ) { _ in
        guard let self, let url = self.previewUrl else { return }
        InAppBrowser.shared.open(url, from: self.currentPresenter())
      }

      let copyAction = UIAction(
        title: "Copy Link",
        image: UIImage(systemName: "doc.on.doc")
      ) { [weak self] _ in
        UIPasteboard.general.string = self?.previewUrl?.absoluteString
      }

      var actions: [UIMenuElement] = [openAction, copyAction]

      if let exclusion = self?.neverShowPreviewActionProvider?() {
        let excludeAction = UIAction(
          title: "Never Show Previews for \(exclusion.host)",
          image: UIImage(systemName: "eye.slash")
        ) { _ in
          exclusion.action()
        }
        actions.append(excludeAction)
      }

      if self?.canRemove == true {
        let removeAction = UIAction(
          title: "Remove",
          image: UIImage(systemName: "trash"),
          attributes: .destructive
        ) { [weak self] _ in
          self?.onRemove?()
        }
        actions.append(removeAction)
      }

      return UIMenu(title: "", children: actions)
    }
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    let parameters = UIPreviewParameters()
    parameters.backgroundColor = .clear
    return UITargetedPreview(view: self, parameters: parameters)
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    false
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    false
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    false
  }
}

#if DEBUG
import SwiftUI

struct URLPreviewView_Previews: PreviewProvider {
  static let previewUrl = "https://www.example.com"
  static let previewSiteName = "Example Site"
  static let previewTitle = "Example Title for a Link Preview"
  static let previewDescription = "This is a description of the link preview. It should be concise and informative."
  static let previewImageUrl =
    "https://44e08acdf82fee3abb51e2515ffef378.r2.cloudflarestorage.com/inline-dev/files/INPoG6WSxR9MC9NRlvjtMQ-e/ecWph8KGLLB7CXtlRyOUckLO99KRpBNI.jpg?X-Amz-Acl=public-read&X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=f231f2e0219ab9bcc81c71c93b3615e1%2F20250504%2Fauto%2Fs3%2Faws4_request&X-Amz-Date=20250504T150223Z&X-Amz-Expires=604800&X-Amz-SignedHeaders=host&X-Amz-Signature=cd54e3342fad310cb71560b32b6f98a07c32cdda49607a3b7a06c4fbf60a8c7b"
  static let previewImageWidth = 1_024
  static let previewImageHeight = 666

  static var mockPhotoInfo: PhotoInfo {
    let size = PhotoSize(
      id: 1,
      photoId: 1,
      type: "f",
      width: previewImageWidth,
      height: previewImageHeight,
      size: nil,
      bytes: nil,
      cdnUrl: previewImageUrl,
      localPath: nil
    )
    let photo = Photo(
      id: 1,
      photoId: 1,
      date: Date(),
      format: .jpeg
    )
    return PhotoInfo(photo: photo, sizes: [size])
  }

  static var mockPreview: UrlPreview {
    UrlPreview(
      id: 1,
      url: previewUrl,
      siteName: previewSiteName,
      title: previewTitle,
      description: previewDescription,
      photoId: 1,
      duration: nil,
      mediaType: nil
    )
  }

  struct Container: UIViewRepresentable {
    func makeUIView(context: Context) -> URLPreviewView {
      let view = URLPreviewView()
      view.configure(with: mockPreview, photoInfo: mockPhotoInfo, parentViewController: nil, outgoing: true)
      view.translatesAutoresizingMaskIntoConstraints = false
      return view
    }

    func updateUIView(_ uiView: URLPreviewView, context: Context) {}
  }

  static var previews: some View {
    Container()
      .frame(maxWidth: 320, maxHeight: 300)
      .padding()
      .background(Color(.systemBlue))
      .previewLayout(.sizeThatFits)
  }
}
#endif
