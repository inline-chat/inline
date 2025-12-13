import AppKit
import Combine
import InlineKit
import Logger
import Nuke

@MainActor
class UserAvatarView: NSView {
  private static let userImageCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 2_000
    cache.totalCostLimit = 1_024 * 1_024 * 200
    return cache
  }()

  private(set) var userId: Int64?

  private var size: CGFloat
  private var user: User?

  private var cancellable: AnyCancellable?
  private var imageLoadTask: Task<Void, Never>?
  private var currentRequestKey: NSString?
  private var currentURL: URL?

  private let imageLayer: CALayer = {
    let layer = CALayer()
    layer.contentsGravity = .resizeAspectFill
    layer.opacity = 0
    return layer
  }()

  private let placeholderLayer: CALayer = {
    let layer = CALayer()
    layer.backgroundColor = NSColor.gray.withAlphaComponent(0.5).cgColor
    layer.opacity = 0
    return layer
  }()

  private let gradientLayer: CAGradientLayer = {
    let layer = CAGradientLayer()
    layer.startPoint = CGPoint(x: 0.5, y: 0)
    layer.endPoint = CGPoint(x: 0.5, y: 1)
    layer.type = .axial
    return layer
  }()

  private let strokeLayer: CAShapeLayer = {
    let layer = CAShapeLayer()
    layer.fillColor = NSColor.clear.cgColor
    layer.lineWidth = 0.5
    layer.opacity = 1
    return layer
  }()

  private let initialsLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.alignment = .center
    label.textColor = .white
    label.isBezeled = false
    label.drawsBackground = false
    label.isEditable = false
    label.isSelectable = false
    label.maximumNumberOfLines = 1
    label.lineBreakMode = .byClipping
    label.usesSingleLineMode = true
    label.isHidden = true
    return label
  }()

  private let symbolImageView: NSImageView = {
    let view = NSImageView()
    view.imageScaling = .scaleProportionallyDown
    view.imageAlignment = .alignCenter
    view.contentTintColor = .white
    view.isHidden = true
    return view
  }()

  init(size: CGFloat = Theme.messageAvatarSize) {
    self.size = size
    super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
    setupView()
  }

  convenience init(userInfo: UserInfo, size: CGFloat = Theme.messageAvatarSize) {
    self.init(size: size)
    update(userInfo: userInfo)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    imageLoadTask?.cancel()
    cancellable?.cancel()
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: size, height: size)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    layer?.rasterizationScale = window?.backingScaleFactor ?? 2.0
    updateLayerScales()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  override func layout() {
    super.layout()

    let diameter = min(bounds.width, bounds.height)
    let radius = diameter / 2

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.cornerRadius = radius
    placeholderLayer.frame = bounds
    gradientLayer.frame = bounds
    imageLayer.frame = bounds
    strokeLayer.frame = bounds
    strokeLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.25, dy: 0.25), transform: nil)
    CATransaction.commit()

    let fontSize = max(8, diameter * 0.55)
    initialsLabel.font = .systemFont(ofSize: fontSize, weight: .regular)

    // Center the label using its fitted size (NSTextField doesn't vertically center within a full-frame box).
    initialsLabel.sizeToFit()
    let labelSize = initialsLabel.fittingSize
    initialsLabel.frame = CGRect(
      x: (bounds.width - labelSize.width) / 2,
      y: (bounds.height - labelSize.height) / 2,
      width: labelSize.width,
      height: labelSize.height
    )

    let symbolPointSize = max(8, diameter * 0.46)
    symbolImageView.symbolConfiguration = .init(pointSize: symbolPointSize, weight: .regular)
    symbolImageView.frame = bounds

    updateLayerScales()
  }

  func update(userInfo: UserInfo) {
    cancellable?.cancel()
    cancellable = nil

    userId = userInfo.user.id
    user = userInfo.user
    applyCurrentUser()
  }

  func update(userId: Int64, user: User?) {
    let didChangeId = self.userId != userId
    self.userId = userId
    self.user = user

    if didChangeId {
      currentURL = nil
      currentRequestKey = nil
      cancellable?.cancel()
      cancellable = ObjectCache.shared.getUserPublisher(id: userId).sink { [weak self] info in
        Task { @MainActor in
          guard let self else { return }
          self.user = info?.user
          self.applyCurrentUser()
        }
      }
    }

    applyCurrentUser()
  }

  private func setupView() {
    wantsLayer = true
    translatesAutoresizingMaskIntoConstraints = false

    layerContentsRedrawPolicy = .onSetNeedsDisplay
    layer?.drawsAsynchronously = true
    layer?.shouldRasterize = true
    layer?.rasterizationScale = window?.backingScaleFactor ?? 2.0
    layer?.masksToBounds = true

    guard let rootLayer = layer else { return }
    rootLayer.addSublayer(gradientLayer)
    rootLayer.addSublayer(placeholderLayer)
    rootLayer.addSublayer(imageLayer)
    rootLayer.addSublayer(strokeLayer)

    addSubview(initialsLabel)
    addSubview(symbolImageView)

    updateColors()
  }

  private func applyCurrentUser() {
    guard let userId else { return }

    let previousKey = currentRequestKey
    let requestKey = Self.cacheKey(for: userId, user: user, pixelWidth: requestedPixelWidth())

    if previousKey != requestKey {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      imageLayer.contents = nil
      imageLayer.opacity = 0
      CATransaction.commit()
    }

    if let cached = Self.userImageCache.object(forKey: requestKey) {
      currentRequestKey = requestKey
      currentURL = nil
      showImage(cached, animated: false)
      return
    }

    currentRequestKey = requestKey

    updateColors()

    let localUrl = user?.getLocalURL()
    let remoteUrl = user?.getRemoteURL()
    let url = localUrl ?? remoteUrl

    currentURL = url
    imageLoadTask?.cancel()

    guard let url else {
      hidePlaceholder()
      // Keep any existing image if present, otherwise show initials/symbol.
      if imageLayer.contents == nil {
        showInitialsOrSymbol()
      }
      return
    }

    let request = ImageRequest(
      url: url,
      processors: [.resize(width: CGFloat(requestedPixelWidth()))],
      priority: .normal,
      options: []
    )

    // Fast path: Nuke in-memory cache.
    if let cached = ImagePipeline.shared.cache.cachedImage(for: request) {
      if currentRequestKey == requestKey, currentURL == url {
        Self.userImageCache.setObject(cached.image, forKey: requestKey, cost: cached.image.approximateCost)
        showImage(cached.image, animated: false)
        maybeCacheToDisk(userId: userId, localUrl: localUrl, remoteUrl: remoteUrl)
      }
      return
    }

    if imageLayer.contents == nil {
      showPlaceholder()
    } else {
      hidePlaceholder()
      initialsLabel.isHidden = true
      symbolImageView.isHidden = true
    }

    imageLoadTask = Task { [weak self] in
      do {
        let image = try await ImagePipeline.shared.image(for: request)
        if Task.isCancelled { return }
        guard let self else { return }

        guard self.currentRequestKey == requestKey, self.currentURL == url else { return }

        Self.userImageCache.setObject(image, forKey: requestKey, cost: image.approximateCost)
        self.showImage(image, animated: true)
        self.maybeCacheToDisk(userId: userId, localUrl: localUrl, remoteUrl: remoteUrl)
      } catch {
        guard let self else { return }
        self.hidePlaceholder()
        if self.imageLayer.contents == nil {
          self.showInitialsOrSymbol()
        }
      }
    }
  }

  private func showImage(_ image: NSImage, animated: Bool) {
    hidePlaceholder()

    initialsLabel.isHidden = true
    symbolImageView.isHidden = true

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.contents = image
    CATransaction.commit()

    if animated {
      imageLayer.removeAllAnimations()
      imageLayer.opacity = 0
      let anim = CABasicAnimation(keyPath: "opacity")
      anim.fromValue = 0
      anim.toValue = 1
      anim.duration = 0.18
      anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
      imageLayer.add(anim, forKey: "fadeIn")
      imageLayer.opacity = 1
    } else {
      imageLayer.opacity = 1
    }
  }

  private func showPlaceholder() {
    placeholderLayer.opacity = 1
    gradientLayer.opacity = 0
    strokeLayer.opacity = 0
    initialsLabel.isHidden = true
    symbolImageView.isHidden = true
  }

  private func hidePlaceholder() {
    placeholderLayer.opacity = 0
    gradientLayer.opacity = 1
    strokeLayer.opacity = 1
  }

  private func showInitialsOrSymbol() {
    hidePlaceholder()

    let (name, shouldShowPersonSymbol) = Self.nameAndSymbolDecision(user: user)
    let initial = name.first.map { String($0).uppercased() } ?? "?"

    if shouldShowPersonSymbol {
      initialsLabel.isHidden = true
      symbolImageView.image = NSImage(systemSymbolName: "person.fill", accessibilityDescription: "User")
      symbolImageView.isHidden = false
    } else {
      symbolImageView.isHidden = true
      initialsLabel.stringValue = initial
      initialsLabel.isHidden = false
      // Ensure centering updates when the string changes.
      needsLayout = true
    }
  }

  private func updateColors() {
    let (name, _) = Self.nameAndSymbolDecision(user: user)
    let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

    let base = Self.paletteColor(for: name).adjustLuminosity(by: isDark ? -0.1 : 0)
    let top = base.adjustLuminosity(by: 0.2).cgColor
    let bottom = base.adjustLuminosity(by: 0.0).cgColor

    gradientLayer.colors = [top, bottom]
    strokeLayer.strokeColor = base.adjustLuminosity(by: -0.4).withAlphaComponent(0.1).cgColor
  }

  private func updateLayerScales() {
    let scaleFactor = window?.backingScaleFactor ?? 2.0
    gradientLayer.contentsScale = scaleFactor
    placeholderLayer.contentsScale = scaleFactor
    imageLayer.contentsScale = scaleFactor
    strokeLayer.contentsScale = scaleFactor
  }

  private func requestedPixelWidth() -> Int {
    let diameter: CGFloat
    if bounds.width > 0, bounds.height > 0 {
      diameter = max(1, min(bounds.width, bounds.height))
    } else {
      diameter = max(1, size)
    }
    let scaleFactor = window?.backingScaleFactor ?? 2.0
    return max(1, Int(ceil(diameter * scaleFactor)))
  }

  private func maybeCacheToDisk(userId: Int64, localUrl: URL?, remoteUrl: URL?) {
    guard localUrl == nil, remoteUrl != nil else { return }

    Task.detached {
      do {
        // Fetch without resizing so the on-disk cache stays high-quality.
        let image = try await ImagePipeline.shared.image(for: remoteUrl!)
        try await User.cacheImage(userId: userId, image: image)
      } catch {
        Log.shared.error("Failed to cache avatar image", error: error)
      }
    }
  }

  private static func cacheKey(for userId: Int64, user: User?, pixelWidth: Int) -> NSString {
    let unique = user?.profileFileUniqueId ?? user?.profileLocalPath ?? user?.profileCdnUrl ?? ""
    return "\(userId)|\(unique)|w=\(pixelWidth)" as NSString
  }

  private static func nameAndSymbolDecision(user: User?) -> (name: String, shouldShowPersonSymbol: Bool) {
    let firstName = user?.firstName?.nilIfEmpty
    let lastName = user?.lastName?.nilIfEmpty
    let email = user?.email?.nilIfEmpty
    let username = user?.username?.nilIfEmpty

    let shouldShowPersonSymbol = (firstName == nil && lastName == nil && email == nil && username == nil)

    let formattedFirstName = firstName ?? email?.components(separatedBy: "@").first ?? "User"
    let name = lastName != nil ? "\(formattedFirstName) \(lastName!)" : formattedFirstName
    return (name, shouldShowPersonSymbol)
  }

  private static func paletteColor(for name: String) -> NSColor {
    let colors: [NSColor] = [
      NSColor.systemPink.adjustLuminosity(by: -0.1),
      .systemOrange,
      .systemPurple,
      NSColor.systemYellow.adjustLuminosity(by: -0.1),
      .systemTeal,
      .systemBlue,
      .systemTeal,
      .systemGreen,
      .systemRed,
      .systemIndigo,
      .systemMint,
      .systemCyan,
    ]

    let hash = name.utf8.reduce(0) { $0 + Int($1) }
    return colors[abs(hash) % colors.count]
  }
}

private extension String {
  var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

private extension NSImage {
  var approximateCost: Int {
    let rep = representations.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh })
    let pixelsWide = rep?.pixelsWide ?? Int(size.width)
    let pixelsHigh = rep?.pixelsHigh ?? Int(size.height)
    return max(1, pixelsWide * pixelsHigh * 4)
  }
}

private extension NSColor {
  func adjustLuminosity(by amount: Double) -> NSColor {
    let amount = CGFloat(amount)
    guard let rgb = usingColorSpace(.deviceRGB) else { return self }
    let r = rgb.redComponent
    let g = rgb.greenComponent
    let b = rgb.blueComponent
    let a = rgb.alphaComponent

    func clamp01(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }

    let transform: (CGFloat) -> CGFloat = { c in
      if amount >= 0 {
        return clamp01(c + (1 - c) * amount)
      } else {
        return clamp01(c * (1 + amount))
      }
    }

    return NSColor(
      red: transform(r),
      green: transform(g),
      blue: transform(b),
      alpha: a
    )
  }
}
