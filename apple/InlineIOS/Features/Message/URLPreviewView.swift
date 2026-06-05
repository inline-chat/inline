import InlineKit
import InlineUI
import UIKit

class URLPreviewView: UIView, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
  enum Mode {
    case compact
    case large
  }

  private enum Metrics {
    static let compactImageSize = CGSize(width: 32, height: 32)
    static let largeImageWidth: CGFloat = 240
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
  private let imageContainer: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.layer.cornerRadius = 6
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
    imageContainer.addSubview(playIconView)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),

      providerPlaceholderView.centerXAnchor.constraint(equalTo: imageContainer.centerXAnchor),
      providerPlaceholderView.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor),
      providerPlaceholderView.widthAnchor.constraint(equalToConstant: Metrics.providerPlaceholderSize),
      providerPlaceholderView.heightAnchor.constraint(equalToConstant: Metrics.providerPlaceholderSize),

      playIconView.centerXAnchor.constraint(equalTo: imageContainer.centerXAnchor),
      playIconView.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor),
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
    InAppBrowser.shared.open(url, from: parentViewController)
  }

  func configure(
    with preview: UrlPreview,
    photoInfo: PhotoInfo?,
    parentViewController: UIViewController?,
    outgoing: Bool,
    mode: Mode = .compact,
    reloadMessageOnFinish message: Message? = nil,
    canRemove: Bool = false,
    onRemove: (() -> Void)? = nil
  ) {
    self.parentViewController = parentViewController
    previewUrl = preview.openURL
    self.canRemove = canRemove
    self.onRemove = onRemove

    resetLayout()

    let trailingPadding: CGFloat = 8
    let verticalPadding: CGFloat = mode == .large ? 7 : 6
    let rectangleWidth: CGFloat = 4
    let contentSpacing: CGFloat = mode == .large ? 8 : 12
    let cornerRadius: CGFloat = 8

    let theme = ThemeManager.shared.selected
    let bgColor = outgoing ? .white.withAlphaComponent(0.1) : theme.secondaryTextColor?
      .withAlphaComponent(0.2) ?? .systemGray5.withAlphaComponent(0.2)
    let primaryTextColor = outgoing ? UIColor.white : (theme.primaryTextColor ?? .label)
    let secondaryTextColor = outgoing ? UIColor.white
      .withAlphaComponent(0.7) : (theme.primaryTextColor?.withAlphaComponent(0.7) ?? .secondaryLabel)
    let rectangleColor = outgoing ? UIColor.white : theme.accent

    let isVideo = preview.isVideoPreview
    let display = preview.displayContent(maxDescriptionLength: mode == .large ? 420 : 110)
    playIconView.tintColor = photoInfo == nil ? secondaryTextColor : .white

    titleLabel.text = display.title
    titleLabel.font = UIFont.systemFont(ofSize: mode == .large ? 15 : 13, weight: .medium)
    titleLabel.textColor = primaryTextColor
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.isHidden = display.title.isEmpty
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.isUserInteractionEnabled = false
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let shouldShowDescription = display.subtitle != nil
    descriptionLabel.text = display.subtitle
    descriptionLabel.font = UIFont.systemFont(ofSize: 12)
    descriptionLabel.textColor = secondaryTextColor
    descriptionLabel.numberOfLines = 1
    descriptionLabel.lineBreakMode = .byTruncatingTail
    descriptionLabel.isHidden = !shouldShowDescription
    descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
    descriptionLabel.isUserInteractionEnabled = false
    descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    configureImage(
      photoInfo: photoInfo,
      isVideo: isVideo,
      providerPlaceholderImage: !isVideo && photoInfo == nil && preview.isNotionPreview ? UIImage(named: "notion-logo") : nil,
      backgroundColor: bgColor,
      reloadMessage: message
    )

    rectangleView.backgroundColor = rectangleColor
    addSubview(rectangleView)

    let bodyStack = UIStackView()
    bodyStack.axis = .vertical
    bodyStack.spacing = 4
    bodyStack.alignment = mode == .large ? .leading : .fill
    bodyStack.translatesAutoresizingMaskIntoConstraints = false
    bodyStack.isUserInteractionEnabled = false

    let textStack = UIStackView()
    textStack.axis = .vertical
    textStack.spacing = 3
    textStack.alignment = .fill
    textStack.translatesAutoresizingMaskIntoConstraints = false
    textStack.isUserInteractionEnabled = false
    textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    textStack.addArrangedSubview(titleLabel)
    if shouldShowDescription {
      textStack.addArrangedSubview(descriptionLabel)
    }

    if mode == .compact {
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
        let imageWidth = imageContainer.widthAnchor.constraint(equalToConstant: Metrics.largeImageWidth)
        imageWidth.priority = .defaultHigh
        activeConstraints.append(contentsOf: [
          imageWidth,
          imageContainer.widthAnchor.constraint(lessThanOrEqualTo: bodyStack.widthAnchor),
          imageContainer.heightAnchor.constraint(equalTo: imageContainer.widthAnchor, multiplier: 9.0 / 16.0),
        ])
      }
      bodyStack.addArrangedSubview(textStack)
      activeConstraints.append(textStack.widthAnchor.constraint(equalTo: bodyStack.widthAnchor))
    }

    addSubview(bodyStack)

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
    preview.isVideoPreview && photoInfo != nil ? .large : .compact
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
        InAppBrowser.shared.open(url, from: self.parentViewController)
      }

      let copyAction = UIAction(
        title: "Copy Link",
        image: UIImage(systemName: "doc.on.doc")
      ) { [weak self] _ in
        UIPasteboard.general.string = self?.previewUrl?.absoluteString
      }

      var actions: [UIMenuElement] = [openAction, copyAction]
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

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
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
