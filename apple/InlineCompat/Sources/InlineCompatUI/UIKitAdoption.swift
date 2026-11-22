#if canImport(UIKit)
import UIKit

// Helpers that use the newest UIKit API where it exists and an equivalent fallback elsewhere.
// Each names the release that introduced the native API, so the fallback can be deleted
// when the deployment target catches up.

// MARK: - Sheets (custom detents: iOS 16)

public enum CompatSheetDetent: Equatable, Sendable {
  case medium
  case large
  /// Fraction of the container height. iOS 15 rounds to medium (≤ 0.6) or large.
  case fraction(CGFloat)
  /// Fixed height in points. iOS 15 rounds to medium or large against the screen height.
  case height(CGFloat)
}

extension UIViewController {
  /// Configures `sheetPresentationController` before presenting. No-op for non-sheet styles.
  public func compatConfigureSheet(
    detents: [CompatSheetDetent],
    prefersGrabber: Bool = true,
    cornerRadius: CGFloat? = nil,
    largestUndimmed: CompatSheetDetent? = nil,
    prefersScrollingExpandsWhenScrolledToEdge: Bool = true
  ) {
    guard let sheet = sheetPresentationController else { return }
    sheet.detents = detents.map(Self.nativeDetent)
    sheet.prefersGrabberVisible = prefersGrabber
    sheet.prefersScrollingExpandsWhenScrolledToEdge = prefersScrollingExpandsWhenScrolledToEdge
    if let cornerRadius { sheet.preferredCornerRadius = cornerRadius }
    if let largestUndimmed {
      sheet.largestUndimmedDetentIdentifier = Self.nativeDetent(largestUndimmed).compatIdentifier
    }
  }

  private static func nativeDetent(_ detent: CompatSheetDetent) -> UISheetPresentationController.Detent {
    switch detent {
    case .medium:
      return .medium()
    case .large:
      return .large()
    case let .fraction(fraction):
      if #available(iOS 16.0, *), CompatRuntime.allows(.iOS16) {
        return .custom(identifier: .init("fraction-\(fraction)")) { $0.maximumDetentValue * fraction }
      }
      return fraction <= 0.6 ? .medium() : .large()
    case let .height(height):
      if #available(iOS 16.0, *), CompatRuntime.allows(.iOS16) {
        return .custom(identifier: .init("height-\(height)")) { min(height, $0.maximumDetentValue) }
      }
      let screenHeight = UIScreen.main.bounds.height
      return height <= screenHeight * 0.55 ? .medium() : .large()
    }
  }
}

extension UISheetPresentationController.Detent {
  fileprivate var compatIdentifier: UISheetPresentationController.Detent.Identifier {
    if #available(iOS 16.0, *) { return identifier }
    // iOS 15 only has the two system detents; compare by description is not possible, so
    // assume medium for undimmed purposes, which is the common case.
    return .medium
  }
}

// MARK: - Materials and Liquid Glass (iOS 26)

public enum CompatMaterial: Sendable, Equatable {
  /// Bars and floating chrome. Liquid Glass on iOS 26, system chrome blur before.
  case chrome
  /// Regular glass with an optional tint. Liquid Glass on iOS 26, thin blur before.
  case glass(tint: UIColor? = nil, interactive: Bool = false)
  /// Plain blur on every system.
  case blur(UIBlurEffect.Style)
}

/// A visual effect view that renders Liquid Glass where available and a blur otherwise.
public final class CompatMaterialView: UIVisualEffectView {
  public private(set) var material: CompatMaterial

  public init(_ material: CompatMaterial = .chrome) {
    self.material = material
    super.init(effect: nil)
    apply(material)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  public func apply(_ material: CompatMaterial) {
    self.material = material
    switch material {
    case .chrome:
      if #available(iOS 26.0, *), CompatRuntime.allows(.iOS26) {
        effect = UIGlassEffect()
      } else {
        effect = UIBlurEffect(style: .systemChromeMaterial)
      }
    case let .glass(tint, interactive):
      if #available(iOS 26.0, *), CompatRuntime.allows(.iOS26) {
        let glass = UIGlassEffect()
        glass.tintColor = tint
        glass.isInteractive = interactive
        effect = glass
      } else {
        effect = UIBlurEffect(style: .systemThinMaterial)
        contentView.backgroundColor = tint?.withAlphaComponent(0.18)
      }
    case let .blur(style):
      effect = UIBlurEffect(style: style)
    }
  }

  /// Whether this view is currently drawing Liquid Glass.
  public var isGlass: Bool {
    if #available(iOS 26.0, *) { return effect is UIGlassEffect }
    return false
  }
}

// MARK: - Haptics

@MainActor
public enum CompatHaptics {
  public static func selection() {
    UISelectionFeedbackGenerator().selectionChanged()
  }

  public static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light, intensity: CGFloat = 1) {
    UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: intensity)
  }

  public static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
    UINotificationFeedbackGenerator().notificationOccurred(type)
  }
}

// MARK: - Trait changes (registerForTraitChanges: iOS 17)

public enum CompatTrait: Sendable, Hashable {
  case userInterfaceStyle
  case preferredContentSizeCategory
  case horizontalSizeClass
  case verticalSizeClass
  case layoutDirection
  case displayScale
  case accessibilityContrast
  case legibilityWeight
}

extension UIView {
  /// Calls `handler` after any of `traits` changes for this view. Lives as long as the view.
  public func compatRegisterForTraitChanges(
    _ traits: [CompatTrait],
    handler: @escaping @MainActor (UIView, UITraitCollection) -> Void
  ) {
    if #available(iOS 17.0, *), CompatRuntime.allows(.iOS17) {
      registerForTraitChanges(traits.map(\.nativeTrait)) { (view: UIView, previous: UITraitCollection) in
        handler(view, previous)
      }
      return
    }
    let relay = TraitRelayView(traits: Set(traits)) { [weak self] previous in
      guard let self else { return }
      handler(self, previous)
    }
    addSubview(relay)
  }
}

extension UIViewController {
  /// Calls `handler` after any of `traits` changes for this controller's view.
  public func compatRegisterForTraitChanges(
    _ traits: [CompatTrait],
    handler: @escaping @MainActor (UIViewController, UITraitCollection) -> Void
  ) {
    if #available(iOS 17.0, *), CompatRuntime.allows(.iOS17) {
      registerForTraitChanges(traits.map(\.nativeTrait)) { (controller: UIViewController, previous: UITraitCollection) in
        handler(controller, previous)
      }
      return
    }
    view.compatRegisterForTraitChanges(traits) { [weak self] _, previous in
      guard let self else { return }
      handler(self, previous)
    }
  }
}

extension CompatTrait {
  @available(iOS 17.0, *)
  var nativeTrait: UITraitDefinition.Type {
    switch self {
    case .userInterfaceStyle: UITraitUserInterfaceStyle.self
    case .preferredContentSizeCategory: UITraitPreferredContentSizeCategory.self
    case .horizontalSizeClass: UITraitHorizontalSizeClass.self
    case .verticalSizeClass: UITraitVerticalSizeClass.self
    case .layoutDirection: UITraitLayoutDirection.self
    case .displayScale: UITraitDisplayScale.self
    case .accessibilityContrast: UITraitAccessibilityContrast.self
    case .legibilityWeight: UITraitLegibilityWeight.self
    }
  }

  func differs(_ a: UITraitCollection, _ b: UITraitCollection) -> Bool {
    switch self {
    case .userInterfaceStyle: a.userInterfaceStyle != b.userInterfaceStyle
    case .preferredContentSizeCategory: a.preferredContentSizeCategory != b.preferredContentSizeCategory
    case .horizontalSizeClass: a.horizontalSizeClass != b.horizontalSizeClass
    case .verticalSizeClass: a.verticalSizeClass != b.verticalSizeClass
    case .layoutDirection: a.layoutDirection != b.layoutDirection
    case .displayScale: a.displayScale != b.displayScale
    case .accessibilityContrast: a.accessibilityContrast != b.accessibilityContrast
    case .legibilityWeight: a.legibilityWeight != b.legibilityWeight
    }
  }
}

/// Invisible subview that relays `traitCollectionDidChange` on iOS 15/16.
private final class TraitRelayView: UIView {
  private let traits: Set<CompatTrait>
  private let onChange: @MainActor (UITraitCollection) -> Void

  init(traits: Set<CompatTrait>, onChange: @escaping @MainActor (UITraitCollection) -> Void) {
    self.traits = traits
    self.onChange = onChange
    super.init(frame: .zero)
    isHidden = true
    isUserInteractionEnabled = false
    isAccessibilityElement = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    guard let previousTraitCollection else { return }
    if traits.contains(where: { $0.differs(previousTraitCollection, traitCollection) }) {
      onChange(previousTraitCollection)
    }
  }
}

// MARK: - SF Symbol effects (iOS 17)

extension UIImageView {
  /// Bounce on iOS 17+, a short spring pulse before.
  public func compatBounce() {
    if #available(iOS 17.0, *), CompatRuntime.allows(.iOS17) {
      addSymbolEffect(.bounce)
      return
    }
    compatPulse()
  }

  /// Replaces the symbol with a replace transition on iOS 17+, a crossfade before.
  public func compatSetSymbol(_ image: UIImage?, animated: Bool = true) {
    guard animated else {
      self.image = image
      return
    }
    if #available(iOS 17.0, *), CompatRuntime.allows(.iOS17), let image {
      setSymbolImage(image, contentTransition: .replace)
      return
    }
    UIView.transition(with: self, duration: 0.2, options: .transitionCrossDissolve) {
      self.image = image
    }
  }
}

extension UIView {
  /// Small scale pulse used as the pre-iOS 17 stand-in for symbol effects.
  public func compatPulse(scale: CGFloat = 1.18) {
    UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
      self.transform = CGAffineTransform(scaleX: scale, y: scale)
    } completion: { _ in
      UIView.animate(
        withDuration: 0.35,
        delay: 0,
        usingSpringWithDamping: 0.5,
        initialSpringVelocity: 0,
        options: [.allowUserInteraction]
      ) {
        self.transform = .identity
      }
    }
  }
}

// MARK: - Text views (TextKit 2 UITextView: iOS 16)

public enum CompatTextView {
  /// A text view on TextKit 2 when the system supports it for UITextView (iOS 16+), TextKit 1
  /// before. Pass `textKit2: false` to force TextKit 1 everywhere.
  @MainActor
  public static func make<T: UITextView>(_ type: T.Type = UITextView.self, textKit2: Bool = true) -> T {
    if textKit2, #available(iOS 16.0, *), CompatRuntime.allows(.iOS16) {
      return T(usingTextLayoutManager: true)
    }
    if #available(iOS 16.0, *) {
      return T(usingTextLayoutManager: false)
    }
    return T(frame: .zero, textContainer: nil)
  }
}

// MARK: - Bars and scroll edges

extension UIBarButtonItem {
  /// `isHidden` (iOS 16). Before iOS 16 the item is disabled and cleared instead; callers that
  /// need a real removal should rebuild the items array.
  public func compatSetHidden(_ hidden: Bool) {
    if #available(iOS 16.0, *), CompatRuntime.allows(.iOS16) {
      isHidden = hidden
      return
    }
    isEnabled = !hidden
    tintColor = hidden ? .clear : nil
  }

  /// Glass background sharing (iOS 26). No-op before.
  public func compatSetSharesBackground(_ shares: Bool) {
    if #available(iOS 26.0, *), CompatRuntime.allows(.iOS26) {
      sharesBackground = shares
    }
  }
}

extension UINavigationItem {
  public enum CompatStyle: Sendable { case navigator, browser, editor }

  /// `style` (iOS 16). No-op before.
  public func compatSetStyle(_ style: CompatStyle) {
    guard #available(iOS 16.0, *), CompatRuntime.allows(.iOS16) else { return }
    switch style {
    case .navigator: self.style = .navigator
    case .browser: self.style = .browser
    case .editor: self.style = .editor
    }
  }
}

extension UIScrollView {
  public enum CompatEdgeEffect: Sendable { case automatic, soft, hard, hidden }

  /// Scroll edge effects (iOS 26). No-op before.
  public func compatSetTopEdgeEffect(_ effect: CompatEdgeEffect) {
    guard #available(iOS 26.0, *), CompatRuntime.allows(.iOS26) else { return }
    switch effect {
    case .automatic: topEdgeEffect.style = .automatic
    case .soft: topEdgeEffect.style = .soft
    case .hard: topEdgeEffect.style = .hard
    case .hidden: topEdgeEffect.isHidden = true
    }
  }

  public func compatSetBottomEdgeEffect(_ effect: CompatEdgeEffect) {
    guard #available(iOS 26.0, *), CompatRuntime.allows(.iOS26) else { return }
    switch effect {
    case .automatic: bottomEdgeEffect.style = .automatic
    case .soft: bottomEdgeEffect.style = .soft
    case .hard: bottomEdgeEffect.style = .hard
    case .hidden: bottomEdgeEffect.isHidden = true
    }
  }
}

// MARK: - Corner configuration (iOS 26)

extension UIView {
  /// Continuous rounded corners. Uses `cornerConfiguration` concentric corners on iOS 26 when
  /// `concentric` is true, `layer.cornerRadius` with continuous curve otherwise.
  public func compatSetCornerRadius(_ radius: CGFloat, concentric: Bool = false) {
    if concentric, #available(iOS 26.0, *), CompatRuntime.allows(.iOS26) {
      cornerConfiguration = .corners(radius: .containerConcentric(minimum: radius))
      return
    }
    layer.cornerRadius = radius
    layer.cornerCurve = .continuous
  }
}
#endif
