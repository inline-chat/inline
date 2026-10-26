import AppKit
import InlineKit
import InlineProtocol

extension RichBlockRenderContext {
  /// Styled text for an agent block part, with the same projection the
  /// planner measured.
  func text(
    _ range: RichBlockTextRange,
    role: RichBlockTextRole,
    isRTL: Bool,
    maximumWidth: CGFloat? = nil,
    color: NSColor? = nil
  ) -> NSAttributedString {
    let value = NSMutableAttributedString(attributedString: text(
      for: .init(rangeOffset: range.offset, rangeLength: range.length, role: role, literal: nil, isRTL: isRTL),
      maximumWidth: maximumWidth
    ))
    if let color {
      value.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: value.length))
    }
    return value
  }

  func plainString(_ range: RichBlockTextRange) -> String {
    guard range.offset >= 0, range.length >= 0, range.offset <= attributedText.length,
          range.length <= attributedText.length - range.offset
    else { return "" }
    return (attributedText.string as NSString).substring(with: NSRange(location: range.offset, length: range.length))
  }
}

private func makeSymbolView(pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImageView {
  let view = NSImageView(frame: .zero)
  view.imageScaling = .scaleProportionallyDown
  view.symbolConfiguration = .init(pointSize: pointSize, weight: weight)
  view.setAccessibilityElement(false)
  return view
}

/// Keeps a pool of text surfaces for composite nodes and hands them out in
/// order, so streaming edits reuse views instead of rebuilding them.
private struct SurfacePool {
  private(set) var surfaces: [RichBlockTextSurface] = []
  private var used = 0

  mutating func begin() { used = 0 }

  mutating func next(in parent: NSView) -> RichBlockTextSurface {
    defer { used += 1 }
    if used < surfaces.count {
      surfaces[used].isHidden = false
      return surfaces[used]
    }
    let surface = RichBlockTextSurface(frame: .zero)
    parent.addSubview(surface)
    surfaces.append(surface)
    return surface
  }

  mutating func end() {
    for surface in surfaces.dropFirst(used) {
      surface.isHidden = true
    }
  }

  var active: [RichBlockTextSurface] { Array(surfaces.prefix(used)) }

  mutating func reset() {
    surfaces.forEach { $0.removeFromSuperview() }
    surfaces.removeAll()
    used = 0
  }
}

// MARK: - Fields

final class RichBlockFieldsNodeView: RichBlockRenderableView {
  private var pool = SurfacePool()
  private var frames: [CGRect] = []

  override var orderedTextSurfaces: [RichBlockTextSurface] { pool.active }

  init() {
    super.init(reuseKind: .fields)
    setAccessibilityRole(.group)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .fields(fields) = node.kind else { return }
    pool.begin()
    frames = []
    for row in fields.rows {
      let label = pool.next(in: self)
      label.apply(
        text: context.text(row.label, role: .paragraph, isRTL: fields.isRTL, color: context.palette.secondary),
        linkColor: context.palette.link,
        onEntityClick: context.interactions.onTextEntityClick
      )
      frames.append(row.labelFrame)
      let value = pool.next(in: self)
      let valueText = row.monospace
        ? RichBlockLayoutPlanner.monospaceText(context.attributedText, range: row.value, color: context.palette.primary)
        : nil
      value.apply(
        text: valueText ?? context.text(row.value, role: .paragraph, isRTL: fields.isRTL, maximumWidth: row.valueFrame.width),
        linkColor: context.palette.link,
        onEntityClick: context.interactions.onTextEntityClick
      )
      frames.append(row.valueFrame)
    }
    pool.end()
    needsLayout = true
  }

  override func updateLayout(node: RichBlockLayoutPlan.Node) {
    guard case let .fields(fields) = node.kind else { return }
    frames = fields.rows.flatMap { [$0.labelFrame, $0.valueFrame] }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    for (surface, frame) in zip(pool.active, frames) {
      surface.frame = frame
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    pool.reset()
    frames = []
  }
}

// MARK: - Steps

final class RichBlockStepsNodeView: RichBlockRenderableView {
  private var pool = SurfacePool()
  private var markers: [NSImageView] = []
  private var steps: [RichBlockStepsNode.Step] = []

  override var orderedTextSurfaces: [RichBlockTextSurface] { pool.active }

  init() {
    super.init(reuseKind: .steps)
    setAccessibilityRole(.list)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .steps(node) = node.kind else { return }
    steps = node.steps
    while markers.count < steps.count {
      let marker = makeSymbolView(pointSize: 12, weight: .medium)
      addSubview(marker)
      markers.append(marker)
    }
    for (index, marker) in markers.enumerated() {
      guard index < steps.count else {
        marker.isHidden = true
        continue
      }
      let status = steps[index].status ?? .pending
      marker.isHidden = false
      marker.image = NSImage(systemSymbolName: status.symbolName, accessibilityDescription: status.accessibilityName)
      marker.contentTintColor = status.tint(context.palette)
    }
    pool.begin()
    for step in steps {
      let finished = step.status == .done || step.status == .cancelled
      let text = pool.next(in: self)
      text.apply(
        text: context.text(
          step.text,
          role: .paragraph,
          isRTL: node.isRTL,
          maximumWidth: step.textFrame.width,
          color: finished ? context.palette.secondary : nil
        ),
        linkColor: context.palette.link,
        onEntityClick: context.interactions.onTextEntityClick
      )
      if let detail = step.detail {
        pool.next(in: self).apply(
          text: context.text(detail, role: .footer, isRTL: node.isRTL, maximumWidth: step.textFrame.width),
          linkColor: context.palette.link,
          onEntityClick: context.interactions.onTextEntityClick
        )
      }
    }
    pool.end()
    needsLayout = true
  }

  override func updateLayout(node: RichBlockLayoutPlan.Node) {
    guard case let .steps(node) = node.kind else { return }
    steps = node.steps
    needsLayout = true
  }

  override func layout() {
    super.layout()
    var surfaces = pool.active.makeIterator()
    for (index, step) in steps.enumerated() {
      if index < markers.count { markers[index].frame = step.markerFrame }
      surfaces.next()?.frame = step.textFrame
      if let detailFrame = step.detailFrame { surfaces.next()?.frame = detailFrame }
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    pool.reset()
    markers.forEach { $0.removeFromSuperview() }
    markers = []
    steps = []
  }
}

// MARK: - Callout

final class RichBlockCalloutNodeView: RichBlockRenderableView {
  private let icon = makeSymbolView(pointSize: 13, weight: .semibold)
  private let title = RichBlockTextSurface(frame: .zero)
  private var node: RichBlockCalloutNode?

  override var orderedTextSurfaces: [RichBlockTextSurface] { node?.title == nil ? [] : [title] }

  init() {
    super.init(reuseKind: .callout)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    addSubview(icon)
    addSubview(title)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .callout(callout) = node.kind else { return }
    self.node = callout
    let tint = callout.tone.tint
    layer?.backgroundColor = tint.withAlphaComponent(0.08).cgColor
    layer?.borderColor = tint.withAlphaComponent(0.22).cgColor
    icon.image = NSImage(systemSymbolName: callout.tone.symbolName, accessibilityDescription: nil)
    icon.contentTintColor = tint
    if let range = callout.title {
      title.isHidden = false
      title.apply(
        text: context.text(range, role: .heading(level: 4), isRTL: callout.isRTL, maximumWidth: callout.titleFrame?.width),
        linkColor: context.palette.link,
        onEntityClick: context.interactions.onTextEntityClick
      )
    } else {
      title.isHidden = true
    }
    setAccessibilityRole(.group)
    setAccessibilityLabel(callout.tone.rawValue.capitalized)
    needsLayout = true
  }

  override func updateLayout(node: RichBlockLayoutPlan.Node) {
    guard case let .callout(callout) = node.kind else { return }
    self.node = callout
    needsLayout = true
  }

  override func layout() {
    super.layout()
    icon.frame = node?.iconFrame ?? .zero
    title.frame = node?.titleFrame ?? .zero
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    guard let tint = node?.tone.tint else { return }
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = tint.withAlphaComponent(0.08).cgColor
      layer?.borderColor = tint.withAlphaComponent(0.22).cgColor
    }
  }
}

// MARK: - Meter

final class RichBlockMeterNodeView: RichBlockRenderableView {
  private let label = RichBlockTextSurface(frame: .zero)
  private let meta = RichBlockTextSurface(frame: .zero)
  private let track = CALayer()
  private let fill = CALayer()
  private var node: RichBlockMeterNode?

  override var orderedTextSurfaces: [RichBlockTextSurface] { node?.meta == nil ? [label] : [label, meta] }

  init() {
    super.init(reuseKind: .meter)
    wantsLayer = true
    addSubview(label)
    addSubview(meta)
    layer?.addSublayer(track)
    track.addSublayer(fill)
    track.masksToBounds = true
    setAccessibilityElement(true)
    setAccessibilityRole(.levelIndicator)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .meter(meter) = node.kind else { return }
    self.node = meter
    label.apply(
      text: context.text(meter.label, role: .paragraph, isRTL: false, maximumWidth: meter.labelFrame.width),
      linkColor: context.palette.link,
      onEntityClick: context.interactions.onTextEntityClick
    )
    if let range = meter.meta {
      meta.isHidden = false
      meta.apply(
        text: context.text(range, role: .footer, isRTL: false),
        linkColor: context.palette.link,
        singleLine: true,
        onEntityClick: context.interactions.onTextEntityClick
      )
    } else {
      meta.isHidden = true
    }
    let tint: NSColor = switch meter.tone {
    case .normal: .controlAccentColor
    case .warning: .systemOrange
    case .critical: .systemRed
    }
    effectiveAppearance.performAsCurrentDrawingAppearance {
      track.backgroundColor = context.palette.primary.withAlphaComponent(0.1).cgColor
      fill.backgroundColor = tint.cgColor
    }
    setAccessibilityLabel(context.plainString(meter.label))
    setAccessibilityValue("\(Int((meter.fraction * 100).rounded()))%")
    needsLayout = true
  }

  override func updateLayout(node: RichBlockLayoutPlan.Node) {
    guard case let .meter(meter) = node.kind else { return }
    self.node = meter
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard let node else { return }
    label.frame = node.labelFrame
    meta.frame = node.metaFrame ?? .zero
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    track.frame = node.barFrame
    track.cornerRadius = node.barFrame.height / 2
    fill.frame = CGRect(x: 0, y: 0, width: node.barFrame.width * node.fraction, height: node.barFrame.height)
    fill.cornerRadius = node.barFrame.height / 2
    CATransaction.commit()
  }
}

// MARK: - Diff

final class RichBlockDiffNodeView: RichBlockRenderableView {
  private let icon = makeSymbolView(pointSize: 11, weight: .medium)
  private let pathField: NSTextField = {
    let field = NSTextField(labelWithString: "")
    field.lineBreakMode = .byTruncatingMiddle
    field.maximumNumberOfLines = 1
    field.font = RichBlockCodeMetrics.bodyFont
    return field
  }()

  private let countsField = NSTextField(labelWithString: "")
  private let copyButton: NSButton = {
    let button = NSButton(
      image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy diff") ?? NSImage(),
      target: nil,
      action: nil
    )
    button.isBordered = false
    button.symbolConfiguration = .init(pointSize: 11, weight: .regular)
    button.toolTip = String(localized: "Copy diff")
    return button
  }()

  private let bodyCanvas = RichBlockDiffBodyCanvas(frame: .zero)
  private lazy var scrollView: RichBlockHorizontalScrollView = {
    let view = RichBlockHorizontalScrollView()
    view.borderType = .noBorder
    view.drawsBackground = false
    view.hasHorizontalScroller = false
    view.hasVerticalScroller = false
    view.horizontalScrollElasticity = .automatic
    view.verticalScrollElasticity = .none
    view.documentView = bodyCanvas
    return view
  }()

  private var node: RichBlockDiffNode?
  private var bodyText = ""

  init() {
    super.init(reuseKind: .diff)
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    addSubview(icon)
    addSubview(pathField)
    addSubview(countsField)
    addSubview(copyButton)
    addSubview(scrollView)
    copyButton.target = self
    copyButton.action = #selector(copyDiff)
    setAccessibilityRole(.group)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .diff(diff) = node.kind else { return }
    self.node = diff
    layer?.backgroundColor = context.palette.codeFill.cgColor
    icon.image = NSImage(systemSymbolName: diff.change.symbolName, accessibilityDescription: nil)
    icon.contentTintColor = context.palette.secondary
    let path = context.plainString(diff.path)
    pathField.stringValue = path
    pathField.textColor = context.palette.primary
    let previous = diff.previousPath.map(context.plainString)
    pathField.toolTip = previous.map { "\($0) → \(path)" } ?? path

    let counts = NSMutableAttributedString()
    let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    if let additions = diff.additions {
      counts.append(NSAttributedString(string: "+\(additions)", attributes: [.font: countFont, .foregroundColor: NSColor.systemGreen]))
    }
    if let deletions = diff.deletions {
      if counts.length > 0 { counts.append(NSAttributedString(string: " ")) }
      counts.append(NSAttributedString(string: "−\(deletions)", attributes: [.font: countFont, .foregroundColor: NSColor.systemRed]))
    }
    countsField.attributedStringValue = counts
    countsField.isHidden = counts.length == 0

    bodyText = diff.body.map(context.plainString) ?? ""
    copyButton.isHidden = bodyText.isEmpty
    copyButton.contentTintColor = context.palette.secondary
    var footer: String?
    if diff.hiddenLineCount > 0 {
      footer = String(localized: "\(diff.hiddenLineCount) more lines")
    } else if diff.truncated {
      footer = String(localized: "Diff shortened by the agent")
    }
    bodyCanvas.apply(
      text: bodyText,
      lineCount: diff.renderedLineCount,
      footer: footer,
      lineHeight: diff.lineHeight,
      palette: context.palette
    )
    scrollView.isHidden = diff.body == nil
    setAccessibilityLabel(String(localized: "Changes to \(path)"))
    needsLayout = true
  }

  override func updateLayout(node: RichBlockLayoutPlan.Node) {
    guard case let .diff(diff) = node.kind else { return }
    self.node = diff
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard let node else { return }
    let header = node.headerHeight
    let inset: CGFloat = 10
    icon.frame = CGRect(x: inset, y: floor((header - 14) / 2), width: 14, height: 14)
    let copyWidth: CGFloat = copyButton.isHidden ? 0 : 22
    copyButton.frame = CGRect(x: bounds.width - inset - copyWidth + 4, y: floor((header - 20) / 2), width: copyWidth, height: 20)
    let countsWidth = countsField.isHidden ? 0 : ceil(countsField.intrinsicContentSize.width)
    countsField.frame = CGRect(
      x: bounds.width - inset - copyWidth - countsWidth - (copyWidth > 0 ? 4 : 0),
      y: floor((header - countsField.intrinsicContentSize.height) / 2),
      width: countsWidth,
      height: countsField.intrinsicContentSize.height
    )
    let pathX = icon.frame.maxX + 6
    let pathHeight = ceil(pathField.intrinsicContentSize.height)
    pathField.frame = CGRect(
      x: pathX,
      y: floor((header - pathHeight) / 2),
      width: max(0, countsField.frame.minX - 8 - pathX),
      height: pathHeight
    )
    scrollView.frame = CGRect(x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header))
    bodyCanvas.frame = CGRect(
      x: 0,
      y: 0,
      width: max(scrollView.frame.width, node.bodyContentWidth),
      height: scrollView.frame.height
    )
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    node = nil
    bodyText = ""
  }

  @objc private func copyDiff() {
    guard !bodyText.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(bodyText, forType: .string)
    ToastCenter.shared.showSuccess("Copied")
  }
}

/// Draws unified diff lines with full-width added and removed backgrounds.
/// Manual drawing keeps a long diff to one view and one pass per frame.
private final class RichBlockDiffBodyCanvas: NSView {
  private var lines: [Substring] = []
  private var footer: String?
  private var lineHeight: CGFloat = 16
  private var primary = NSColor.labelColor
  private var secondary = NSColor.secondaryLabelColor

  override var isFlipped: Bool { true }

  func apply(text: String, lineCount: Int, footer: String?, lineHeight: CGFloat, palette: RichBlockPalette) {
    lines = Array(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(lineCount))
    self.footer = footer
    self.lineHeight = lineHeight
    primary = palette.primary
    secondary = palette.secondary
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let top = RichBlockAgentMetrics.diffBodyVerticalPadding
    let x = RichBlockAgentMetrics.diffBodyHorizontalPadding
    let font = RichBlockAgentMetrics.diffFont
    let first = max(0, Int(floor((dirtyRect.minY - top) / lineHeight)))
    let last = min(lines.count, Int(ceil((dirtyRect.maxY - top) / lineHeight)) + 1)
    if first < last {
      for index in first ..< last {
        let line = lines[index]
        let y = top + CGFloat(index) * lineHeight
        let color: NSColor
        if line.hasPrefix("+"), !line.hasPrefix("+++") {
          NSColor.systemGreen.withAlphaComponent(0.13).setFill()
          CGRect(x: 0, y: y, width: bounds.width, height: lineHeight).fill()
          color = primary
        } else if line.hasPrefix("-"), !line.hasPrefix("---") {
          NSColor.systemRed.withAlphaComponent(0.13).setFill()
          CGRect(x: 0, y: y, width: bounds.width, height: lineHeight).fill()
          color = primary
        } else if line.hasPrefix("@@") {
          color = secondary
        } else {
          color = primary
        }
        (String(line) as NSString).draw(
          at: CGPoint(x: x, y: y + 1),
          withAttributes: [.font: font, .foregroundColor: color]
        )
      }
    }
    if let footer {
      (footer as NSString).draw(
        at: CGPoint(x: x, y: top + CGFloat(lines.count) * lineHeight + 1),
        withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: secondary]
      )
    }
  }
}
