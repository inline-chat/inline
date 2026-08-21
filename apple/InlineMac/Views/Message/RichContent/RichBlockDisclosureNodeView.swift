import AppKit
import InlineKit

final class RichBlockDisclosureNodeView: RichBlockRenderableView {
  private let surface = RichBlockTextSurface(frame: .zero)
  private let chevron: NSImageView = {
    let view = NSImageView()
    view.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
    return view
  }()
  private let shimmer = RichBlockTextShimmerView(frame: .zero)
  private let toggleButton: NSButton = {
    let button = RichBlockDisclosureButton(title: "", target: nil, action: nil)
    button.isBordered = false
    button.isTransparent = true
    button.focusRingType = .none
    button.setButtonType(.momentaryChange)
    return button
  }()

  private var path = BlockContentPath()
  private var expanded = false
  private var progress = false
  private var isRTL = false
  private var onToggle: ((BlockContentPath, Bool) -> Void)?

  init() {
    super.init(reuseKind: .disclosure)
    toggleButton.target = self
    toggleButton.action = #selector(toggleDisclosure)
    addSubview(toggleButton)
    addSubview(surface)
    addSubview(chevron)
    addSubview(shimmer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .text(text) = node.kind,
          case let .disclosureSummary(progress, expanded) = text.role
    else { return }
    let attributed = NSMutableAttributedString(attributedString: context.text(for: text))
    if progress {
      attributed.addAttribute(
        .foregroundColor,
        value: context.palette.primary.withAlphaComponent(0.78),
        range: NSRange(location: 0, length: attributed.length)
      )
    }
    self.path = node.path
    self.progress = progress
    self.expanded = expanded
    isRTL = text.isRTL
    onToggle = context.interactions.onDisclosureToggle
    chevron.contentTintColor = context.palette.secondary
    updateChevron()
    surface.apply(
      text: attributed,
      linkColor: context.palette.link,
      onEntityClick: context.interactions.onTextEntityClick
    )
    shimmer.apply(color: .white)
    toggleButton.setAccessibilityLabel(attributed.string)
    toggleButton.setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
    setContentVisible(context.isContentVisible)
    needsLayout = true
  }

  override func setContentVisible(_ visible: Bool) {
    super.setContentVisible(visible)
    let shouldAnimate = progress
      && visible
      && window != nil
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    shimmer.setAnimating(shouldAnimate)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    setContentVisible(isContentVisible)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onToggle = nil
  }

  override func layout() {
    super.layout()
    toggleButton.frame = bounds
    let horizontalLayout = RichBlockDisclosureMetrics.horizontalLayout(
      bounds: bounds,
      intrinsicTitleWidth: surface.measuredWidth,
      isRTL: isRTL
    )
    surface.frame = horizontalLayout.titleFrame
    chevron.frame = horizontalLayout.chevronFrame
    shimmer.frame = surface.frame
    surface.layoutSubtreeIfNeeded()
    shimmer.updateMask(from: surface)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard bounds.contains(point) else { return nil }
    let surfacePoint = surface.convert(point, from: self)
    if surface.hasInteractiveEntity(at: surfacePoint) {
      return surface.hitTest(surfacePoint) ?? toggleButton
    }
    return toggleButton
  }

  override func accessibilityPerformPress() -> Bool {
    toggleDisclosure()
    return true
  }

  @objc private func toggleDisclosure() {
    expanded.toggle()
    updateChevron()
    toggleButton.setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
    onToggle?(path, expanded)
  }

  private func updateChevron() {
    let symbolName = expanded ? "chevron.down" : (isRTL ? "chevron.left" : "chevron.right")
    chevron.image = NSImage(
      systemSymbolName: symbolName,
      accessibilityDescription: expanded ? "Collapse" : "Expand"
    )
  }
}

private final class RichBlockDisclosureButton: NSButton {
  override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}
