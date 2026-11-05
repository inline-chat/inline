import AppKit
import InlineKit

/// A short upload bar under an outgoing photo's bubble, like Messages.
final class PhotoUploadProgressView: NSView {
  static let size = CGSize(width: 60, height: 4)
  static let topSpacing: CGFloat = 4
  private static let minimumFraction: Double = 0.04

  private let fillLayer = CALayer()
  private let binding = PhotoUploadProgressBinding()
  private var photoLocalId: Int64?
  private var fraction = PhotoUploadProgressView.minimumFraction

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = Self.size.height / 2
    layer?.masksToBounds = true
    fillLayer.cornerRadius = Self.size.height / 2
    fillLayer.anchorPoint = .zero
    layer?.addSublayer(fillLayer)
    updateColors()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(photoLocalId: Int64) {
    guard self.photoLocalId != photoLocalId else { return }
    self.photoLocalId = photoLocalId
    fraction = Self.minimumFraction
    updateFill(animated: false)
    binding.bind(photoLocalId: photoLocalId) { [weak self] progress in
      guard let self else { return }
      fraction = max(Self.minimumFraction, progress.fractionCompleted)
      updateFill(animated: true)
    }
  }

  /// Fills the bar when `filling`, fades it out and removes it.
  func dismiss(filling: Bool) {
    binding.clear()
    if filling {
      fraction = 1
      updateFill(animated: true)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + (filling ? 0.25 : 0)) {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        self.animator().alphaValue = 0
      } completionHandler: {
        self.removeFromSuperview()
      }
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func layout() {
    super.layout()
    updateFill(animated: false)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  private func updateColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
      fillLayer.backgroundColor = Theme.accentColor.cgColor
    }
  }

  private func updateFill(animated: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(!animated)
    CATransaction.setAnimationDuration(0.2)
    fillLayer.bounds = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
    fillLayer.position = .zero
    CATransaction.commit()
  }
}
