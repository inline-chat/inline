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

  /// The circle: everything but the agent badge, which sits on its edge.
  private let contentView = UIView()
  private var badgeView: MessageViaBadgeLayerView?
  private var badgeMark: MessageViaPresentation.Mark?
  private var badgeDiameter: CGFloat = 0
  private let gradientLayer = CAGradientLayer()
  private let borderLayer = CAShapeLayer()
  private let initialsLabel = UILabel()
  private let symbolView = UIImageView()
  private let imageView = UIImageView()
  private var signature: Signature?

  override public init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    contentView.clipsToBounds = true
    contentView.isUserInteractionEnabled = false
    addSubview(contentView)
    gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
    gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
    contentView.layer.addSublayer(gradientLayer)
    borderLayer.fillColor = nil
    contentView.layer.addSublayer(borderLayer)
    initialsLabel.textAlignment = .center
    initialsLabel.adjustsFontSizeToFitWidth = false
    symbolView.contentMode = .center
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    for view in [initialsLabel, symbolView, imageView] {
      view.isUserInteractionEnabled = false
      contentView.addSubview(view)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Shows `userInfo` the way `UserAvatar(userInfo:size:)` does; `viaMark` pins the agent badge to its
  /// corner when an agent sent the message for this user, as `MessageViaAvatar` draws it.
  /// The photo on screen, if it has loaded; nil while initials show.
  public var displayedImage: UIImage? { imageView.image }

  public func configure(with userInfo: UserInfo, size: CGFloat, viaMark: MessageViaPresentation.Mark? = nil) {
    let user = userInfo.user
    configure(
      userID: user.id,
      firstName: user.firstName,
      lastName: user.lastName,
      email: user.email,
      username: user.username,
      stableAvatarIdentity: userInfo.stableAvatarIdentity,
      remoteURL: user.getRemoteURL(),
      localURL: user.getLocalURL(),
      size: size,
      viaMark: viaMark
    )
  }

  /// Same drawing from plain fields, for list snapshots that carry no `UserInfo`.
  public func configure(
    userID: Int64,
    firstName: String?,
    lastName: String?,
    email: String?,
    username: String?,
    stableAvatarIdentity identity: String?,
    remoteURL: URL?,
    localURL rawLocalURL: URL?,
    size: CGFloat,
    viaMark: MessageViaPresentation.Mark? = nil
  ) {
    setBadge(viaMark, size: size)
    let presentation = InlineAvatarPresentation.user(identity: .init(
      firstName: firstName,
      lastName: lastName,
      displayName: nil,
      email: email,
      username: username,
      stableIdentifier: "user:\(userID)"
    ))
    let localURL = rawLocalURL.flatMap { url in
      !url.isFileURL || FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : UITraitCollection.current.displayScale
    let source = UserAvatarImageSource(
      userID: userID,
      identity: identity,
      remoteURL: remoteURL,
      localURL: localURL,
      scale: scale
    )
    let signature = Signature(
      userId: userID,
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
      loadImage(source, size: size, scale: scale, userId: userID, identity: identity, localURL: localURL)
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

  private func setBadge(_ mark: MessageViaPresentation.Mark?, size: CGFloat) {
    let shown = mark.flatMap { MessageViaAgentIcon.hasBadge($0) ? $0 : nil }
    let diameter = MessageViaBadge.diameter(forAvatar: size)
    guard shown != badgeMark || diameter != badgeDiameter || (shown != nil && badgeView == nil) else { return }
    badgeMark = shown
    badgeDiameter = diameter
    guard let shown else {
      badgeView?.removeFromSuperview()
      badgeView = nil
      return
    }
    let badge = badgeView ?? {
      let view = MessageViaBadgeLayerView()
      addSubview(view)
      badgeView = view
      return view
    }()
    badge.configure(mark: shown, diameter: diameter)
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
    contentView.frame = bounds
    contentView.layer.cornerRadius = min(bounds.width, bounds.height) / 2
    if let badgeView {
      // In the avatar's bottom-right corner, inside its square, as `MessageViaAvatar` places it.
      let side = MessageViaBadge.diameter(forAvatar: min(bounds.width, bounds.height)) + MessageViaBadgeLayerView.ringWidth * 2
      badgeView.frame = CGRect(x: bounds.maxX - side, y: bounds.maxY - side, width: side, height: side)
    }
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

/// UIKit twin of `MessageViaBadge` on its ring, as `MessageViaAvatar` and the old hosted badge
/// drew it: the agent's icon (filling the disc, or fitted on a white one) or the bot's avatar,
/// clipped to a circle on a `systemBackground` ring.
final class MessageViaBadgeLayerView: UIView {
  static let ringWidth: CGFloat = 1.5

  private let discView = UIView()
  private let iconView = UIImageView()
  private var botAvatar: UserAvatarLayerView?
  private var diameter: CGFloat = 0
  private var iconInset: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    accessibilityElementsHidden = true
    backgroundColor = .systemBackground
    discView.clipsToBounds = true
    discView.isUserInteractionEnabled = false
    addSubview(discView)
    iconView.clipsToBounds = true
    discView.addSubview(iconView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(mark: MessageViaPresentation.Mark, diameter: CGFloat) {
    self.diameter = diameter
    switch mark {
    case let .agent(id):
      botAvatar?.removeFromSuperview()
      botAvatar = nil
      let icon = MessageViaAgentIcon.icon(for: id)
      iconView.isHidden = icon == nil
      iconView.image = icon.flatMap { UIImage(named: $0.asset, in: .module, compatibleWith: nil) }
      let fills = icon?.fillsBadge ?? true
      iconView.contentMode = fills ? .scaleAspectFill : .scaleAspectFit
      iconInset = fills ? 0 : diameter * 0.14
      discView.backgroundColor = fills ? nil : .white
    case let .bot(bot):
      iconView.isHidden = true
      iconView.image = nil
      discView.backgroundColor = nil
      let avatar = botAvatar ?? {
        let view = UserAvatarLayerView()
        view.isUserInteractionEnabled = false
        discView.addSubview(view)
        botAvatar = view
        return view
      }()
      avatar.configure(with: bot, size: diameter)
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = min(bounds.width, bounds.height) / 2
    // The disc keeps the badge diameter, centered on the ring, like the padded SwiftUI frame.
    let side = diameter > 0 ? diameter : max(min(bounds.width, bounds.height) - Self.ringWidth * 2, 0)
    discView.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    discView.layer.cornerRadius = side / 2
    iconView.frame = discView.bounds.insetBy(dx: iconInset, dy: iconInset)
    botAvatar?.frame = discView.bounds
  }
}

private extension UIColor {
  convenience init(_ color: InlineAvatarColor) {
    self.init(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
  }
}
#endif
