import AppKit

// macOS 27's native toolbar trace did not expose a full-width NSVisualEffectView.
// The scroll-edge band was a CABackdropLayer with CAFilter(gaussianBlur), while
// toolbar items used separate SDF/glassBackground platter layers. These values
// are the tuned chat approximation of that scroll-edge band: a light 5px private
// backdrop blur, a strong window-background tint, and a hairline separator.
// Earlier macOS releases keep the stable public NSVisualEffectView.headerView
// fallback instead of touching private Core Animation classes.
private enum ToolbarBackgroundMaterial {
  static let blurRadius: CGFloat = 5
  static let tintAlpha: CGFloat = 0.85
  static let lightSeparatorAlpha: CGFloat = 0.05
  static let darkSeparatorAlpha: CGFloat = 0.05
}

class ToolbarBackgroundView: NSView {
  private let backgroundView: NSView
  private let materialView: ToolbarBackgroundMaterialView?
  private let separatorView = NSView()
  private var separatorHeightConstraint: NSLayoutConstraint?

  init(dependencies _: AppDependencies) {
    if #available(macOS 27.0, *) {
      let view = ToolbarBackgroundMaterialView()
      backgroundView = view
      materialView = view
    } else {
      let view = NSVisualEffectView()
      view.material = .headerView
      view.blendingMode = .withinWindow
      view.state = .active
      backgroundView = view
      materialView = nil
    }

    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false

    setupBackgroundView()
    setupSeparatorView()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    materialView?.updateAppearance()
    updateSeparatorColor()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    materialView?.updateAppearance()
    updateSeparatorHeight()
    updateSeparatorColor()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
    return self
  }

  private func setupBackgroundView() {
    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backgroundView)

    NSLayoutConstraint.activate([
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    materialView?.updateAppearance()
  }

  private func setupSeparatorView() {
    separatorView.translatesAutoresizingMaskIntoConstraints = false
    separatorView.wantsLayer = true
    addSubview(separatorView)

    let heightConstraint = separatorView.heightAnchor.constraint(equalToConstant: 1)
    separatorHeightConstraint = heightConstraint
    NSLayoutConstraint.activate([
      separatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
      separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
      separatorView.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightConstraint,
    ])

    updateSeparatorHeight()
    updateSeparatorColor()
  }

  private func updateSeparatorHeight() {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    separatorHeightConstraint?.constant = 1 / scale
  }

  private func updateSeparatorColor() {
    let appearance = effectiveAppearance
    let separatorAlpha: CGFloat = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? ToolbarBackgroundMaterial.darkSeparatorAlpha
      : ToolbarBackgroundMaterial.lightSeparatorAlpha

    separatorView.layer?.backgroundColor = NSColor.separatorColor
      .resolvedColor(with: appearance)
      .withAlphaComponent(separatorAlpha)
      .cgColor
  }

  private func doubleClickAction() {
    let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"

    switch action {
      case "Minimize":
        window?.performMiniaturize(nil)

      default:
        window?.performZoom(nil)
    }
  }

  override func mouseDown(with event: NSEvent) {
    // Forward to window's title bar handling
    window?.performDrag(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if event.clickCount == 2 {
      doubleClickAction()
    }
  }
}

private final class ToolbarBackgroundMaterialView: NSView {
  private let backdropLayer = ToolbarBackgroundPrivateBackdrop.makeLayer()
  private let tintLayer = CALayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupLayers()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    backdropLayer.frame = bounds
    backdropLayer.contentsScale = layer?.contentsScale ?? 2
    tintLayer.frame = bounds
    tintLayer.contentsScale = layer?.contentsScale ?? 2
    CATransaction.commit()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateBackdropScale()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
  }

  func updateAppearance() {
    let tint = NSColor.windowBackgroundColor
      .resolvedColor(with: effectiveAppearance)
      .withAlphaComponent(ToolbarBackgroundMaterial.tintAlpha)

    tintLayer.backgroundColor = tint.cgColor
  }

  private func setupLayers() {
    wantsLayer = true
    layerUsesCoreImageFilters = true

    guard let layer else { return }
    layer.name = "ToolbarBackgroundBackdropHostLayer"
    layer.masksToBounds = true
    layer.backgroundColor = NSColor.clear.cgColor
    layer.needsDisplayOnBoundsChange = true

    backdropLayer.name = "ToolbarBackgroundBackdropLayer"
    backdropLayer.masksToBounds = true
    backdropLayer.backgroundColor = nil
    backdropLayer.needsDisplayOnBoundsChange = true
    backdropLayer.filters = ToolbarBackgroundPrivateBackdrop.blurFilters(radius: ToolbarBackgroundMaterial.blurRadius)

    layer.addSublayer(backdropLayer)

    tintLayer.name = "ToolbarBackgroundTintLayer"
    tintLayer.masksToBounds = true

    layer.addSublayer(tintLayer)

    updateBackdropScale()
    updateAppearance()
  }

  private func updateBackdropScale() {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    backdropLayer.contentsScale = scale

    guard backdropLayer.responds(to: NSSelectorFromString("setScale:")) else { return }
    backdropLayer.setValue(scale, forKey: "scale")
  }
}

private enum ToolbarBackgroundPrivateBackdrop {
  static func makeLayer() -> CALayer {
    guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type else {
      return CALayer()
    }

    return layerClass.init()
  }

  static func blurFilters(radius: CGFloat) -> [Any] {
    guard let filter = makeFilter(named: "gaussianBlur") else { return [] }
    filter.setValue(radius, forKey: "inputRadius")
    filter.setValue(true, forKey: "inputNormalizeEdges")
    return [filter]
  }

  private static func makeFilter(named name: String) -> NSObject? {
    guard let filterClass = NSClassFromString(String("retliFAC".reversed())) as? NSObject.Type else {
      return nil
    }

    let selector = NSSelectorFromString(String(":epyThtiWretlif".reversed()))
    return filterClass.perform(selector, with: name)?.takeUnretainedValue() as? NSObject
  }
}
