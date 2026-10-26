#if os(iOS)
import InlineAvatarCore
import InlineKit
import Kingfisher
import UIKit

/// `UserAvatar` drawn with plain views: the same initials, gradient, border and cached photo,
/// without a hosting controller. For rows that create many avatars, such as reaction pills,
/// where a hosting controller per avatar costs more than the rest of the message.
///
/// Sized by its frame; it has no constraints.
@MainActor
public final class UserAvatarLayerView: UIView {
  private struct Signature: Equatable {
    let userId: Int64
    let seed: String
    let showsPersonSymbol: Bool
    let hasConfiguredPhoto: Bool
    let imageCacheKey: String?
    let size: CGFloat
  }

  private let gradientLayer = CAGradientLayer()
  private let borderLayer = CAShapeLayer()
  private let initialsLabel = UILabel()
  private let symbolView = UIImageView()
  private let imageView = UIImageView()
  private var signature: Signature?

  override public init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    clipsToBounds = true
    gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
    gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
    layer.addSublayer(gradientLayer)
    borderLayer.fillColor = nil
    layer.addSublayer(borderLayer)
    initialsLabel.textAlignment = .center
    initialsLabel.adjustsFontSizeToFitWidth = false
    symbolView.contentMode = .center
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    for view in [initialsLabel, symbolView, imageView] {
      view.isUserInteractionEnabled = false
      addSubview(view)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Shows `userInfo` the way `UserAvatar(userInfo:size:)` does.
  public func configure(with userInfo: UserInfo, size: CGFloat) {
    let user = userInfo.user
    let presentation = InlineAvatarPresentation.user(identity: .init(
      firstName: user.firstName,
      lastName: user.lastName,
      displayName: nil,
      email: user.email,
      username: user.username,
      stableIdentifier: "user:\(user.id)"
    ))
    let remoteURL = user.getRemoteURL()
    let localURL = user.getLocalURL().flatMap { url in
      !url.isFileURL || FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    let identity = userInfo.stableAvatarIdentity
    let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : UITraitCollection.current.displayScale
    let source = UserAvatarImageSource(
      userID: user.id,
      identity: identity,
      remoteURL: remoteURL,
      localURL: localURL,
      scale: scale
    )
    let signature = Signature(
      userId: user.id,
      seed: presentation.seed,
      showsPersonSymbol: presentation.showsPersonSymbol,
      hasConfiguredPhoto: identity != nil || remoteURL != nil || localURL != nil,
      imageCacheKey: source?.cacheKey,
      size: size
    )
    guard signature != self.signature else { return }
    self.signature = signature

    let style = InlineAvatarStyle.resolved(seed: presentation.seed)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradientLayer.colors = style.gradientStops.map { UIColor($0.color).cgColor }
    gradientLayer.locations = style.gradientStops.map { NSNumber(value: $0.location) }
    borderLayer.strokeColor = UIColor(style.borderColor).cgColor
    borderLayer.lineWidth = style.borderWidth
    CATransaction.commit()

    let foreground = UIColor(style.foregroundColor)
    initialsLabel.text = presentation.seed.first.map(String.init)?.uppercased()
    initialsLabel.font = .systemFont(ofSize: size * 0.55, weight: .regular)
    initialsLabel.textColor = foreground
    symbolView.image = UIImage(
      systemName: "person.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.46, weight: .regular)
    )
    symbolView.tintColor = foreground

    imageView.kf.cancelDownloadTask()
    imageView.image = nil
    // While a photo loads, a gray circle stands in, as in `UserAvatar`.
    let placeholder = UIColor.gray.withAlphaComponent(0.5)
    if let source {
      showInitials(false)
      imageView.isHidden = false
      imageView.backgroundColor = placeholder
      loadImage(source, size: size, scale: scale, userId: user.id, identity: identity, localURL: localURL)
    } else if signature.hasConfiguredPhoto {
      showInitials(false)
      imageView.isHidden = false
      imageView.backgroundColor = placeholder
    } else {
      showInitials(true)
      initialsLabel.isHidden = presentation.showsPersonSymbol
      symbolView.isHidden = !presentation.showsPersonSymbol
      imageView.isHidden = true
    }
    setNeedsLayout()
  }

  private func showInitials(_ shows: Bool) {
    initialsLabel.isHidden = !shows
    symbolView.isHidden = !shows
    borderLayer.isHidden = !shows
  }

  private func loadImage(
    _ source: UserAvatarImageSource,
    size: CGFloat,
    scale: CGFloat,
    userId: Int64,
    identity: String?,
    localURL: URL?
  ) {
    let side = max(size, 1)
    // Same processor, scale and key as `UserAvatar`'s KFImage, so both share cached images.
    imageView.kf.setImage(
      with: source.url.convertToSource(overrideCacheKey: source.cacheKey),
      options: [
        .processor(DownsamplingImageProcessor(size: CGSize(width: side, height: side))),
        .scaleFactor(scale),
        .cacheOriginalImage,
        .loadDiskFileSynchronously,
        .retryStrategy(DelayRetryStrategy(maxRetryCount: 1, retryInterval: .seconds(1))),
      ]
    ) { [weak self] result in
      guard case .success = result else { return }
      // Kingfisher calls back on the main queue.
      MainActor.assumeIsolated {
        self?.imageView.backgroundColor = nil
        let sourceURL = source.url
        guard !sourceURL.isFileURL,
              localURL?.lastPathComponent.hasPrefix(User.remoteProfilePhotoCacheFilePrefix) != true
        else { return }
        UserAvatarMirror.shared.mirror(userId: userId, sourceURL: sourceURL, expectedAvatarIdentity: identity) {
          try await source.originalImageData()
        }
      }
    }
    if imageView.image != nil {
      imageView.backgroundColor = nil
    }
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = min(bounds.width, bounds.height) / 2
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradientLayer.frame = bounds
    borderLayer.frame = bounds
    borderLayer.path = UIBezierPath(ovalIn: bounds).cgPath
    CATransaction.commit()
    initialsLabel.frame = bounds
    symbolView.frame = bounds
    imageView.frame = bounds
  }
}

private extension UIColor {
  convenience init(_ color: InlineAvatarColor) {
    self.init(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
  }
}
#endif
