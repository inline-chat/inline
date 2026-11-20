#if os(macOS)
import AppKit
import InlineAvatarCore
import InlineKit
import Kingfisher
import SwiftUI

/// `UserAvatar` drawn with plain layers: the same initials, gradient, border and cached photo, without
/// a hosting view. A hosting view inside a scrolling message list re-runs SwiftUI's graph every frame it
/// moves (its window transform and safe area change), and the window's drag-margin pass walks its
/// content; layers do neither. The macOS counterpart of the iOS `UserAvatarLayerView`.
///
/// Sized by its frame; it has no constraints. Only the agent badge, shown when an agent sent the
/// message for this user, is a small hosted SwiftUI view.
@MainActor
public final class UserAvatarLayerView: NSView {
  private struct Signature: Equatable {
    let userId: Int64
    let seed: String
    let showsPersonSymbol: Bool
    let hasConfiguredPhoto: Bool
    let imageCacheKey: String?
    let size: CGFloat
    let scale: CGFloat
  }

  /// The circle: everything but the agent badge, which sits on its edge.
  private let contentLayer = CALayer()
  private let gradientLayer = CAGradientLayer()
  private let borderLayer = CAShapeLayer()
  private let initialsLayer = CATextLayer()
  private let symbolLayer = CALayer()
  private let imageLayer = CALayer()
  private var badgeHost: NSHostingView<AnyView>?
  private var badgeMark: MessageViaPresentation.Mark?
  private var signature: Signature?
  private var configuration: (userInfo: UserInfo, size: CGFloat, viaMark: MessageViaPresentation.Mark?)?
  private var imageTask: DownloadTask?
  private var initialsFont: NSFont = .systemFont(ofSize: 17)

  override public var isFlipped: Bool { true }

  override public init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    let layers: [CALayer] = [contentLayer, gradientLayer, borderLayer, initialsLayer, symbolLayer, imageLayer]
    for layer in layers {
      layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
    }
    contentLayer.masksToBounds = true
    layer?.addSublayer(contentLayer)
    gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
    gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
    contentLayer.addSublayer(gradientLayer)
    borderLayer.fillColor = nil
    contentLayer.addSublayer(borderLayer)
    initialsLayer.alignmentMode = .center
    contentLayer.addSublayer(initialsLayer)
    symbolLayer.contentsGravity = .center
    contentLayer.addSublayer(symbolLayer)
    imageLayer.contentsGravity = .resizeAspectFill
    imageLayer.masksToBounds = true
    contentLayer.addSublayer(imageLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Shows `userInfo` the way `UserAvatar(userInfo:size:)` does; `viaMark` pins the agent badge to its
  /// corner when an agent sent the message for this user, as `MessageViaAvatar` draws it.
  public func configure(with userInfo: UserInfo, size: CGFloat, viaMark: MessageViaPresentation.Mark? = nil) {
    configuration = (userInfo, size, viaMark)
    setBadge(viaMark, size: size)
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
    let scale = displayScale
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
      size: size,
      scale: scale
    )
    guard signature != self.signature else { return }
    self.signature = signature

    let style = InlineAvatarStyle.resolved(seed: presentation.seed)
    let foreground = NSColor(style.foregroundColor)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for layer in [contentLayer, gradientLayer, borderLayer, initialsLayer, symbolLayer, imageLayer] {
      layer.contentsScale = scale
    }
    gradientLayer.colors = style.gradientStops.map { NSColor($0.color).cgColor }
    gradientLayer.locations = style.gradientStops.map { NSNumber(value: $0.location) }
    borderLayer.strokeColor = NSColor(style.borderColor).cgColor
    borderLayer.lineWidth = style.borderWidth
    initialsFont = .systemFont(ofSize: size * 0.55, weight: .regular)
    initialsLayer.string = NSAttributedString(
      string: presentation.seed.first.map(String.init)?.uppercased() ?? "",
      attributes: [.font: initialsFont, .foregroundColor: foreground]
    )
    symbolLayer.contents = Self.symbolImage(size: size, color: foreground, scale: scale)

    imageTask?.cancel()
    imageTask = nil
    imageLayer.contents = nil
    // While a photo loads, a gray circle stands in, as in `UserAvatar`.
    let placeholder = NSColor.gray.withAlphaComponent(0.5).cgColor
    if let source {
      showInitials(false)
      imageLayer.isHidden = false
      imageLayer.backgroundColor = placeholder
      loadImage(source, signature: signature, userId: user.id, identity: identity, localURL: localURL)
    } else if signature.hasConfiguredPhoto {
      showInitials(false)
      imageLayer.isHidden = false
      imageLayer.backgroundColor = placeholder
    } else {
      showInitials(true)
      initialsLayer.isHidden = presentation.showsPersonSymbol
      symbolLayer.isHidden = !presentation.showsPersonSymbol
      imageLayer.isHidden = true
    }
    CATransaction.commit()
    needsLayout = true
  }

  private var displayScale: CGFloat {
    window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
  }

  override public func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    // Photos are cached per scale; redraw at the new screen's.
    guard let configuration, signature?.scale != displayScale else { return }
    configure(with: configuration.userInfo, size: configuration.size, viaMark: configuration.viaMark)
  }

  private func setBadge(_ mark: MessageViaPresentation.Mark?, size: CGFloat) {
    let shown = mark.flatMap { MessageViaAgentIcon.hasBadge($0) ? $0 : nil }
    guard shown != badgeMark || (shown != nil && badgeHost == nil) else { return }
    badgeMark = shown
    guard let shown else {
      badgeHost?.removeFromSuperview()
      badgeHost = nil
      return
    }
    let badge = AnyView(
      MessageViaBadge(mark: shown, size: MessageViaBadge.diameter(forAvatar: size))
        .padding(1.5)
        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
    )
    if let badgeHost {
      badgeHost.rootView = badge
    } else {
      let host = NSHostingView(rootView: badge)
      host.translatesAutoresizingMaskIntoConstraints = true
      addSubview(host)
      badgeHost = host
    }
    needsLayout = true
  }

  private func showInitials(_ shows: Bool) {
    initialsLayer.isHidden = !shows
    symbolLayer.isHidden = !shows
    borderLayer.isHidden = !shows
  }

  private func loadImage(
    _ source: UserAvatarImageSource,
    signature: Signature,
    userId: Int64,
    identity: String?,
    localURL: URL?
  ) {
    let side = max(signature.size, 1)
    // Same processor, scale and key as `UserAvatar`'s KFImage, so both share cached images.
    imageTask = KingfisherManager.shared.retrieveImage(
      with: source.url.convertToSource(overrideCacheKey: source.cacheKey),
      options: [
        .processor(DownsamplingImageProcessor(size: CGSize(width: side, height: side))),
        .scaleFactor(signature.scale),
        .cacheOriginalImage,
        .loadDiskFileSynchronously,
        .retryStrategy(DelayRetryStrategy(maxRetryCount: 1, retryInterval: .seconds(1))),
      ]
    ) { [weak self] result in
      guard case let .success(value) = result else { return }
      // Kingfisher calls back on the main queue.
      MainActor.assumeIsolated {
        guard let self, self.signature == signature else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.imageLayer.contents = value.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        self.imageLayer.backgroundColor = nil
        CATransaction.commit()
        let sourceURL = source.url
        guard !sourceURL.isFileURL,
              localURL?.lastPathComponent.hasPrefix(User.remoteProfilePhotoCacheFilePrefix) != true
        else { return }
        UserAvatarMirror.shared.mirror(userId: userId, sourceURL: sourceURL, expectedAvatarIdentity: identity) {
          try await source.originalImageData()
        }
      }
    }
  }

  private static var symbolImages: [String: CGImage] = [:]

  /// `person.fill` at the initials' symbol size, tinted with the foreground color.
  private static func symbolImage(size: CGFloat, color: NSColor, scale: CGFloat) -> CGImage? {
    let key = "\(size)|\(scale)|\(color.description)"
    if let image = symbolImages[key] { return image }
    let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .regular)
      .applying(.init(paletteColors: [color]))
    guard let symbol = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration)
    else { return nil }
    var rect = NSRect(origin: .zero, size: symbol.size)
    let hints: [NSImageRep.HintKey: Any] = [.ctm: NSAffineTransform(transform: .init(scale: scale))]
    let image = symbol.cgImage(forProposedRect: &rect, context: nil, hints: hints)
    symbolImages[key] = image
    return image
  }

  override public func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    contentLayer.frame = bounds
    contentLayer.cornerRadius = min(bounds.width, bounds.height) / 2
    gradientLayer.frame = bounds
    borderLayer.frame = bounds
    borderLayer.path = CGPath(ellipseIn: bounds, transform: nil)
    // Centered on its line box, as SwiftUI centers `Text`.
    let lineHeight = ceil(initialsFont.ascender - initialsFont.descender)
    initialsLayer.frame = CGRect(
      x: 0,
      y: ((bounds.height - lineHeight) / 2).rounded(),
      width: bounds.width,
      height: lineHeight
    )
    symbolLayer.frame = bounds
    imageLayer.frame = bounds
    CATransaction.commit()
    if let badgeHost {
      // In the avatar's bottom-right corner, inside its square, as `MessageViaAvatar` places it.
      let side = MessageViaBadge.diameter(forAvatar: min(bounds.width, bounds.height)) + 3
      badgeHost.frame = CGRect(x: bounds.maxX - side, y: bounds.maxY - side, width: side, height: side)
    }
  }
}

private extension NSColor {
  convenience init(_ color: InlineAvatarColor) {
    self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
  }
}
#endif
