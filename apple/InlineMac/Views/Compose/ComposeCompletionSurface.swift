import AppKit

enum ComposeCompletionSurfaceStyle: Equatable {
  case glass
  case material
}

class ComposeCompletionMenuView: NSView {
  private static let heightTimingFunction = CAMediaTimingFunction(
    controlPoints: 0.25,
    0.46,
    0.45,
    0.94
  )

  private(set) var isPresented = false
  private var visibilityGeneration = 0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    alphaValue = 0
    isHidden = true
    setAccessibilityHidden(true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var acceptsFirstResponder: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isPresented, alphaValue > 0.01 else { return nil }
    return super.hitTest(point)
  }

  func present(animated: Bool = true) {
    if isPresented {
      isHidden = false
      return
    }

    visibilityGeneration += 1
    isPresented = true
    isHidden = false
    setAccessibilityHidden(false)

    guard shouldAnimate(animated) else {
      alphaValue = 1
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animator().alphaValue = 1
    }
  }

  func dismiss(animated: Bool = true) {
    guard isPresented else { return }

    visibilityGeneration += 1
    let generation = visibilityGeneration
    isPresented = false
    setAccessibilityHidden(true)

    guard shouldAnimate(animated) else {
      alphaValue = 0
      isHidden = true
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      animator().alphaValue = 0
    } completionHandler: { [weak self] in
      guard let self,
            visibilityGeneration == generation,
            !isPresented
      else {
        return
      }
      isHidden = true
    }
  }

  func setHeight(_ height: CGFloat, constraint: NSLayoutConstraint, animated: Bool = true) {
    guard abs(constraint.constant - height) > 0.5 else { return }

    let shouldAnimateHeight = isPresented && shouldAnimate(animated)
    guard shouldAnimateHeight else {
      constraint.constant = height
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      context.timingFunction = Self.heightTimingFunction
      constraint.animator().constant = height
    }
  }

  private func shouldAnimate(_ requested: Bool) -> Bool {
    requested && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }
}

final class ComposeCompletionSurfaceView: NSView {
  private let backgroundView: NSView

  var cornerRadius: CGFloat {
    didSet {
      updateGeometry()
    }
  }

  init(style: ComposeCompletionSurfaceStyle, cornerRadius: CGFloat) {
    self.cornerRadius = cornerRadius

    if style == .glass, #available(macOS 26.0, *) {
      let glassView = NSGlassEffectView()
      glassView.style = .regular
      glassView.cornerRadius = cornerRadius
      if #available(macOS 27.0, *) {
        glassView.effectIsInteractive = true
      }
      backgroundView = glassView
    } else {
      let materialView = NSVisualEffectView()
      materialView.material = .headerView
      materialView.blendingMode = .withinWindow
      materialView.state = .active
      backgroundView = materialView
    }

    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.masksToBounds = true

    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backgroundView)
    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    updateGeometry()
  }

  private func updateGeometry() {
    layer?.cornerRadius = cornerRadius
    layer?.cornerCurve = .continuous
    backgroundView.wantsLayer = true
    backgroundView.layer?.cornerRadius = cornerRadius
    backgroundView.layer?.cornerCurve = .continuous
    backgroundView.layer?.masksToBounds = true

    if #available(macOS 26.0, *), let glassView = backgroundView as? NSGlassEffectView {
      glassView.cornerRadius = cornerRadius
    }
  }
}
