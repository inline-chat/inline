import AppKit
import QuartzCore

/// Telegram-style round checkbox shown beside each message while selecting.
/// The accent fill springs in and the tick draws itself on select; both shrink away on deselect.
final class ForwardMessageSelectionCheckmark: NSView {
  static let size: CGFloat = 22
  var onToggle: (() -> Void)?

  private let ring = CAShapeLayer()
  private let fill = CAShapeLayer()
  private let tick = CAShapeLayer()
  private(set) var isSelected = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = false
    ring.fillColor = nil
    ring.lineWidth = 1.5
    tick.fillColor = nil
    tick.lineWidth = 1.8
    tick.lineCap = .round
    tick.lineJoin = .round
    for sublayer in [ring, fill, tick] {
      layer?.addSublayer(sublayer)
    }
    applySelectedState()
    setAccessibilityElement(true)
    setAccessibilityRole(.checkBox)
    setAccessibilityLabel("Select message")
  }

  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }
  override var wantsUpdateLayer: Bool { true }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let circle = CGPath(ellipseIn: bounds.insetBy(dx: 1.75, dy: 1.75), transform: nil)
    for sublayer in [ring, fill, tick] {
      sublayer.frame = bounds
    }
    ring.path = circle
    fill.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
    // Layer space is unflipped: the tick's elbow sits below both ends.
    let tickPath = CGMutablePath()
    tickPath.move(to: CGPoint(x: bounds.midX - 4.5, y: bounds.midY + 0.5))
    tickPath.addLine(to: CGPoint(x: bounds.midX - 1.5, y: bounds.midY - 2.5))
    tickPath.addLine(to: CGPoint(x: bounds.midX + 4.5, y: bounds.midY + 3.5))
    tick.path = tickPath
    CATransaction.commit()
  }

  override func updateLayer() {
    ring.strokeColor = NSColor.tertiaryLabelColor.cgColor
    fill.fillColor = Theme.accentColor.cgColor
    tick.strokeColor = NSColor.white.cgColor
  }

  func setSelected(_ selected: Bool, animated: Bool) {
    guard selected != isSelected else { return }
    isSelected = selected
    setAccessibilityValue(selected)
    applySelectedState()
    guard animated else {
      fill.removeAllAnimations()
      tick.removeAllAnimations()
      return
    }
    if selected {
      let pop = CASpringAnimation(keyPath: "transform.scale")
      pop.fromValue = 0.45
      pop.toValue = 1
      pop.damping = 14
      pop.stiffness = 320
      pop.mass = 1
      pop.initialVelocity = 2
      pop.duration = pop.settlingDuration
      fill.add(pop, forKey: "pop")
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0
      fade.toValue = 1
      fade.duration = 0.1
      fill.add(fade, forKey: "fade")

      let draw = CABasicAnimation(keyPath: "strokeEnd")
      draw.fromValue = 0
      draw.toValue = 1
      draw.beginTime = CACurrentMediaTime() + 0.06
      draw.duration = 0.18
      draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
      draw.fillMode = .backwards
      tick.add(draw, forKey: "draw")
    } else {
      let shrink = CABasicAnimation(keyPath: "transform.scale")
      shrink.fromValue = 1
      shrink.toValue = 0.45
      shrink.duration = 0.16
      shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 1
      fade.toValue = 0
      fade.duration = 0.16
      fill.add(shrink, forKey: "pop")
      fill.add(fade, forKey: "fade")
      tick.add(fade, forKey: "fade")
    }
  }

  private func applySelectedState() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fill.opacity = isSelected ? 1 : 0
    tick.opacity = isSelected ? 1 : 0
    ring.opacity = isSelected ? 0 : 1
    CATransaction.commit()
  }

  override func accessibilityPerformPress() -> Bool {
    onToggle?()
    return onToggle != nil
  }
}

/// Small Core Animation helpers shared by the selection-mode transitions.
@MainActor
enum SelectionMotion {
  static let duration: CFTimeInterval = 0.26
  static let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

  /// Moves a layer from `offset` back to where its model already is.
  static func slide(_ layer: CALayer?, fromX offset: CGFloat, key: String = "selectionSlide") {
    guard let layer, offset != 0 else { return }
    let slide = CABasicAnimation(keyPath: "transform.translation.x")
    slide.fromValue = offset
    slide.toValue = 0
    slide.isAdditive = true
    slide.duration = duration
    slide.timingFunction = timing
    layer.add(slide, forKey: key)
  }

  /// Fades a view in, or out and then hides it unless `stillHidden` says it came back meanwhile.
  static func fade(_ view: NSView, in fadeIn: Bool, slideX: CGFloat = 0, slideY: CGFloat = 0,
                   duration: CFTimeInterval = duration, stillHidden: @escaping @MainActor () -> Bool = { true })
  {
    guard let layer = view.layer else {
      view.isHidden = !fadeIn
      return
    }
    layer.removeAnimation(forKey: "selectionFade")
    layer.removeAnimation(forKey: "selectionFadeSlide")
    view.isHidden = false
    CATransaction.begin()
    if !fadeIn {
      CATransaction.setCompletionBlock { [weak view] in
        MainActor.assumeIsolated {
          guard let view else { return }
          if stillHidden() { view.isHidden = true }
          view.layer?.removeAnimation(forKey: "selectionFade")
          view.layer?.removeAnimation(forKey: "selectionFadeSlide")
        }
      }
    }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = fadeIn ? 0 : 1
    fade.toValue = fadeIn ? 1 : 0
    fade.duration = duration
    fade.timingFunction = timing
    if !fadeIn {
      fade.fillMode = .forwards
      fade.isRemovedOnCompletion = false
    }
    layer.add(fade, forKey: "selectionFade")
    if slideX != 0 || slideY != 0 {
      let slide = CABasicAnimation(keyPath: slideX != 0 ? "transform.translation.x" : "transform.translation.y")
      let distance = slideX != 0 ? slideX : slideY
      slide.fromValue = fadeIn ? distance : 0
      slide.toValue = fadeIn ? 0 : distance
      slide.isAdditive = true
      slide.duration = duration
      slide.timingFunction = timing
      if !fadeIn {
        slide.fillMode = .forwards
        slide.isRemovedOnCompletion = false
      }
      layer.add(slide, forKey: "selectionFadeSlide")
    }
    CATransaction.commit()
  }
}
