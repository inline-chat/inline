#if os(iOS)
import InlineKit
import UIKit

/// UIKit twin of `ThreadIconView`: same background, emoji or symbol and content scale, drawn
/// with layers so list cells need no SwiftUI host and no iOS 16 `ImageRenderer`.
public final class ThreadIconLayerView: UIView {
  private let gradientLayer = CAGradientLayer()
  private let emojiLabel = UILabel()
  private let symbolView = UIImageView()
  private var descriptor = ThreadIconDescriptor(emoji: nil)
  private var size: ThreadIconSize = .regular(32)
  private var shape: ThreadIconShape = .circle
  private var symbolColor: ThreadIconSymbolColor = .secondary
  private var background: ThreadIconBackground = .automatic
  private var contentScaleMultiplier: CGFloat = 1
  private var fallbackSymbolName: String?

  override public init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    isUserInteractionEnabled = false
    gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
    gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
    layer.addSublayer(gradientLayer)
    emojiLabel.textAlignment = .center
    emojiLabel.adjustsFontSizeToFitWidth = true
    emojiLabel.minimumScaleFactor = 0.75
    emojiLabel.isAccessibilityElement = false
    symbolView.contentMode = .center
    symbolView.isAccessibilityElement = false
    addSubview(emojiLabel)
    addSubview(symbolView)
    isAccessibilityElement = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  public func configure(
    _ descriptor: ThreadIconDescriptor,
    size: ThreadIconSize,
    shape: ThreadIconShape = .circle,
    symbolColor: ThreadIconSymbolColor = .secondary,
    background: ThreadIconBackground = .automatic,
    contentScaleMultiplier: CGFloat = 1,
    fallbackSymbolName: String? = nil
  ) {
    self.descriptor = descriptor
    self.size = size
    self.shape = shape
    self.symbolColor = symbolColor
    self.background = background
    self.contentScaleMultiplier = max(contentScaleMultiplier, 0)
    self.fallbackSymbolName = fallbackSymbolName
    accessibilityLabel = descriptor.accessibilityLabel ?? descriptor.title ?? "Thread"
    applyContent()
    applyColors()
    setNeedsLayout()
  }

  override public var intrinsicContentSize: CGSize {
    CGSize(width: size.points, height: size.points)
  }

  override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
      applyColors()
    }
  }

  private func applyContent() {
    let side = size.points
    let scale = ContentScale.resolved(for: size, shape: shape)
    if let emoji = descriptor.emoji {
      emojiLabel.text = emoji
      emojiLabel.font = .systemFont(ofSize: side * scale.emojiRatio * contentScaleMultiplier)
      emojiLabel.isHidden = false
      symbolView.isHidden = true
    } else {
      let name = fallbackSymbolName ?? ThreadIconDefaults.fallbackSymbolName(isReplyThread: descriptor.isReplyThread)
      symbolView.image = UIImage(
        systemName: name,
        withConfiguration: UIImage.SymbolConfiguration(
          pointSize: side * scale.symbolRatio * contentScaleMultiplier,
          weight: descriptor.isReplyThread ? .bold : .semibold
        )
      )
      symbolView.isHidden = false
      emojiLabel.isHidden = true
    }
  }

  private func applyColors() {
    let dark = traitCollection.userInterfaceStyle == .dark
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if shape == .none {
      gradientLayer.colors = nil
    } else if background == .solid {
      // ThreadIconView's solid fill; `.automatic` is the gradient on iOS.
      let fill = dark ? UIColor.white.withAlphaComponent(0.14) : UIColor.black.withAlphaComponent(0.065)
      gradientLayer.colors = [fill.cgColor, fill.cgColor]
    } else {
      let top = dark ? UIColor.white.withAlphaComponent(0.20) : UIColor.black.withAlphaComponent(0.05)
      let bottom = dark ? UIColor.white.withAlphaComponent(0.13) : UIColor.black.withAlphaComponent(0.08)
      gradientLayer.colors = [top.cgColor, bottom.cgColor]
    }
    CATransaction.commit()
    let foreground: UIColor = switch symbolColor {
    case .primary: .label
    case .mutedPrimary: UIColor.label.withAlphaComponent(0.76)
    case .secondary: .secondaryLabel
    case .white: UIColor.white.withAlphaComponent(0.94)
    }
    symbolView.tintColor = foreground
    emojiLabel.textColor = foreground
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
    let side = min(bounds.width, bounds.height)
    let square = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradientLayer.frame = square
    switch shape {
    case .circle: gradientLayer.cornerRadius = side / 2
    case .roundedSquare: gradientLayer.cornerRadius = side * size.cornerRadiusRatio
    case .none: gradientLayer.cornerRadius = 0
    }
    gradientLayer.cornerCurve = .continuous
    CATransaction.commit()
    emojiLabel.frame = square
    symbolView.frame = square
  }

  /// Draws the configured icon into a bitmap of the view's bounds, in its trait collection (set
  /// `overrideUserInterfaceStyle` first for a fixed appearance). Needs no window.
  func renderImage(scale: CGFloat) -> UIImage {
    setNeedsLayout()
    layoutIfNeeded()
    let traits = traitCollection
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    return UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
      let cgContext = context.cgContext
      traits.performAsCurrent {
        if gradientLayer.colors != nil {
          // Clip by hand: `render(in:)` is not guaranteed to honor the layer's corner radius.
          let frame = gradientLayer.frame
          cgContext.saveGState()
          let clip = shape == .circle
            ? UIBezierPath(ovalIn: frame)
            : UIBezierPath(roundedRect: frame, cornerRadius: gradientLayer.cornerRadius)
          clip.addClip()
          cgContext.translateBy(x: frame.minX, y: frame.minY)
          gradientLayer.render(in: cgContext)
          cgContext.restoreGState()
        }
        if !emojiLabel.isHidden {
          cgContext.saveGState()
          cgContext.translateBy(x: emojiLabel.frame.minX, y: emojiLabel.frame.minY)
          emojiLabel.layer.render(in: cgContext)
          cgContext.restoreGState()
        }
        // `render(in:)` skips an image view's template tint, so draw the symbol tinted.
        if !symbolView.isHidden, let image = symbolView.image {
          let tint = (symbolView.tintColor ?? .secondaryLabel).resolvedColor(with: traits)
          let box = symbolView.frame
          let rect = CGRect(
            x: box.midX - image.size.width / 2,
            y: box.midY - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
          )
          image.withTintColor(tint, renderingMode: .alwaysOriginal).draw(in: rect)
        }
      }
    }
  }
}
#endif
