import InlineKit
import InlineMessageLayout
import InlineSyntaxHighlighting
import InlineUI
import UIKit

/// Draws a planned `RichLayout`: one view per node, kept by path and kind, so an update or a
/// disclosure moves the same views. Geometry is set in `layoutNodes()`, inside the message's
/// animation.
final class MessageRichView: UIView {
  struct Palette {
    var text: UIColor
    var secondary: UIColor
    var accent: UIColor

    var subtleFill: UIColor { text.withAlphaComponent(0.05) }
    var codeFill: UIColor { text.withAlphaComponent(0.07) }
    var separator: UIColor { text.withAlphaComponent(0.14) }
  }

  private struct Key: Hashable {
    var path: RichPath
    var kind: Int
  }

  private(set) var layout: RichLayout?
  private var views: [Key: UIView] = [:]
  private var order: [Key] = []
  private var photos: [String: PhotoInfo] = [:]

  var onDisclosureToggle: ((RichPath, Bool) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Creates and configures node views for `layout`; call without animation. New nodes start
  /// at their final frame, faded out when `animated`.
  func apply(_ layout: RichLayout, palette: Palette, photos: [String: PhotoInfo], animated: Bool) {
    self.layout = layout
    self.photos = photos
    var keys: [Key] = []
    for placed in layout.nodes {
      let key = Key(path: placed.path, kind: Self.kind(of: placed.node))
      keys.append(key)
      let view = views[key] ?? makeView(for: placed.node)
      if views[key] == nil {
        views[key] = view
        Self.place(view, at: placed.frame)
        if animated { view.alpha = 0 }
      }
      configure(view, with: placed, palette: palette)
    }
    let live = Set(keys)
    for (key, view) in views where !live.contains(key) {
      view.removeFromSuperview()
      views[key] = nil
    }
    order = keys
    // Decorations behind content: quotes first, in tree order.
    for key in order {
      guard let view = views[key] else { continue }
      if view is RichQuoteView { sendSubviewToBack(view) } else { bringSubviewToFront(view) }
    }
  }

  /// Moves nodes to the layout's frames. Call inside the message's animation.
  func layoutNodes() {
    guard let layout else { return }
    for placed in layout.nodes {
      guard let view = views[Key(path: placed.path, kind: Self.kind(of: placed.node))] else { continue }
      Self.place(view, at: placed.frame)
      view.alpha = 1
      view.layoutIfNeeded()
    }
  }

  /// The view drawing the node at `path`, for tests and accessibility. Markers use their item's
  /// path with -1 appended.
  func nodeView(at path: RichPath) -> UIView? {
    views.first { $0.key.path == path }?.value
  }

  /// Text under `point`, for taps on links and mentions: the node's attributed string and the
  /// character index in it.
  func textHit(at point: CGPoint) -> (NSAttributedString, Int)? {
    for case let view as MessageTextView in subviews where view.frame.insetBy(dx: -4, dy: -2).contains(point) {
      if let index = view.characterIndex(at: convert(point, to: view)) {
        return (view.layout.text.attributedString, index)
      }
    }
    return nil
  }

  // MARK: - Nodes

  /// Text views carry bleed for marks past their lines, so they take the frame as text frame.
  private static func place(_ view: UIView, at frame: CGRect) {
    if let text = view as? MessageTextView {
      text.textFrame = frame
    } else {
      view.untransformedFrame = frame
    }
  }

  private static func kind(of node: RichLayout.Node) -> Int {
    switch node {
    case .text: 0
    case .marker: 1
    case .code: 2
    case .quote: 3
    case .separator: 4
    case .table: 5
    case .image: 6
    case .album: 7
    case .disclosure: 8
    }
  }

  private func makeView(for node: RichLayout.Node) -> UIView {
    let view: UIView = switch node {
    case .text, .marker: MessageTextView()
    case .code: RichCodeView()
    case .quote: RichQuoteView()
    case .separator: UIView()
    case .table: RichTableView()
    case .image: RichImageView()
    case .album: RichAlbumView()
    case .disclosure: RichDisclosureView()
    }
    addSubview(view)
    return view
  }

  private func configure(_ view: UIView, with placed: RichLayout.Placed, palette: Palette) {
    switch placed.node {
    case let .text(text, _), let .marker(text):
      (view as? MessageTextView)?.setLayout(text)
    case let .code(code):
      (view as? RichCodeView)?.configure(code, palette: palette)
    case let .quote(isRightToLeft):
      (view as? RichQuoteView)?.configure(isRightToLeft: isRightToLeft, palette: palette)
    case .separator:
      view.backgroundColor = palette.separator
    case let .table(table):
      (view as? RichTableView)?.configure(table, palette: palette)
    case let .image(id):
      (view as? RichImageView)?.configure(photos[id], palette: palette)
    case let .album(items):
      (view as? RichAlbumView)?.configure(items, photos: photos, palette: palette)
    case let .disclosure(disclosure):
      let disclosureView = view as? RichDisclosureView
      disclosureView?.configure(disclosure, palette: palette)
      let path = placed.path
      disclosureView?.onToggle = { [weak self] in
        self?.onDisclosureToggle?(path, !disclosure.isExpanded)
      }
    }
  }
}

// MARK: - Node views

/// A code block: a filled box with an optional language header and line numbers, and a body
/// that scrolls sideways instead of wrapping.
private final class RichCodeView: UIView {
  private let header = MessageTextView()
  private let scroll = UIScrollView()
  private let numbers = MessageTextView()
  private let body = MessageTextView()
  private let copyButton = UIButton(type: .system)
  private var code: RichLayout.Code?
  private var highlightTask: Task<Void, Never>?
  private static let highlighter = CodeSyntaxHighlighter()

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 8
    layer.cornerCurve = .continuous
    clipsToBounds = true
    scroll.showsHorizontalScrollIndicator = false
    scroll.alwaysBounceHorizontal = false
    scroll.clipsToBounds = true
    addSubview(scroll)
    addSubview(header)
    scroll.addSubview(numbers)
    scroll.addSubview(body)
    copyButton.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)), for: .normal)
    copyButton.addTarget(self, action: #selector(copyCode), for: .touchUpInside)
    copyButton.accessibilityLabel = "Copy code"
    addSubview(copyButton)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ code: RichLayout.Code, palette: MessageRichView.Palette) {
    backgroundColor = palette.codeFill
    header.setLayout(code.languageLabel ?? .empty)
    header.isHidden = code.languageLabel == nil
    numbers.setLayout(code.lineNumbers ?? .empty)
    numbers.isHidden = code.lineNumbers == nil
    let isSameCode = self.code.map { $0.text.text == code.text.text && $0.language == code.language } ?? false
    if !isSameCode || body.layout.text.string != code.text.text.string {
      body.setLayout(code.text)
      highlight(code, palette: palette)
    }
    self.code = code
    copyButton.tintColor = palette.secondary
    setNeedsLayout()
  }

  /// Colors tokens once the shared highlighter returns them. Only colors change, so the
  /// code keeps its planned geometry.
  private func highlight(_ code: RichLayout.Code, palette: MessageRichView.Palette) {
    highlightTask?.cancel()
    guard CodeSyntaxHighlighter.supports(language: code.language) else { return }
    let base = code.text.text.attributedString
    let raw = base.string
    let language = code.language
    let traits = traitCollection
    let scale = traits.displayScale > 0 ? traits.displayScale : UITraitCollection.current.displayScale
    highlightTask = Task { [weak self] in
      guard let tokens = try? await Self.highlighter.tokens(for: raw, language: language),
            !Task.isCancelled, let self, self.code?.text.text.string == raw
      else { return }
      let colored = NSMutableAttributedString(attributedString: base)
      let length = colored.length
      for token in tokens where token.range.location >= 0 && NSMaxRange(token.range) <= length {
        colored.addAttribute(.foregroundColor, value: Self.color(for: token.kind, palette: palette), range: token.range)
      }
      let text = MessageText(colored.coreTextReady(for: traits))
      body.setLayout(TextLayouter.layout(text, maximumWidth: .greatestFiniteMagnitude, grid: PixelGrid(scale: scale)))
      setNeedsLayout()
    }
  }

  private static func color(for kind: CodeTokenKind, palette: MessageRichView.Palette) -> UIColor {
    switch kind {
    case .keyword, .number, .constant: palette.accent
    case .type: palette.accent.withAlphaComponent(0.8)
    case .function, .property, .operatorSymbol: palette.text
    case .string: palette.secondary
    case .comment: palette.secondary.withAlphaComponent(0.72)
    case .punctuation: palette.secondary
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let code else { return }
    let top = code.textOrigin.y
    scroll.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
    scroll.contentSize = CGSize(width: code.contentWidth, height: scroll.bounds.height)
    if let numbers = code.lineNumbers {
      self.numbers.textFrame = CGRect(origin: CGPoint(x: code.lineNumbersOrigin.x, y: 0), size: numbers.size)
    }
    body.textFrame = CGRect(origin: CGPoint(x: code.textOrigin.x, y: 0), size: code.text.size)
    if let label = code.languageLabel {
      header.textFrame = CGRect(origin: code.languageLabelOrigin, size: label.size)
    }
    let side: CGFloat = 26
    copyButton.frame = CGRect(x: bounds.width - side - 2, y: 0, width: side, height: max(side, code.languageLabel == nil ? side : top))
  }

  @objc private func copyCode() {
    guard let code else { return }
    UIPasteboard.general.string = code.text.text.string
    ToastManager.shared.showToast("Copied", type: .success, systemImage: "doc.on.doc")
  }
}

private final class RichQuoteView: UIView {
  private let rail = UIView()
  private var isRightToLeft = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 7
    layer.cornerCurve = .continuous
    clipsToBounds = true
    rail.layer.cornerRadius = 1.5
    addSubview(rail)
    isUserInteractionEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(isRightToLeft: Bool, palette: MessageRichView.Palette) {
    self.isRightToLeft = isRightToLeft
    backgroundColor = palette.subtleFill
    rail.backgroundColor = palette.accent
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    rail.frame = CGRect(x: isRightToLeft ? bounds.width - 3 : 0, y: 0, width: 3, height: bounds.height)
  }
}

/// A table that scrolls sideways when its columns don't fit; the header row is filled.
private final class RichTableView: UIView {
  private let scroll = UIScrollView()
  private let content = UIView()
  private var cellViews: [MessageTextView] = []
  private var lines: [UIView] = []
  private let headerFill = UIView()
  private var table: RichLayout.Table?

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 8
    layer.cornerCurve = .continuous
    layer.borderWidth = 1 / UIScreen.main.scale
    clipsToBounds = true
    scroll.showsHorizontalScrollIndicator = false
    addSubview(scroll)
    scroll.addSubview(content)
    content.addSubview(headerFill)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ table: RichLayout.Table, palette: MessageRichView.Palette) {
    self.table = table
    layer.borderColor = palette.separator.cgColor
    headerFill.backgroundColor = palette.subtleFill
    while cellViews.count < table.cells.count {
      let view = MessageTextView()
      content.addSubview(view)
      cellViews.append(view)
    }
    while cellViews.count > table.cells.count {
      cellViews.removeLast().removeFromSuperview()
    }
    for (view, cell) in zip(cellViews, table.cells) {
      view.setLayout(cell.text)
    }
    let rowTops = Set(table.cells.map(\.frame.minY)).sorted().dropFirst()
    let columnEdges = Set(table.cells.filter { $0.row == 0 }.map { table.isRightToLeft ? $0.frame.minX : $0.frame.maxX })
      .filter { $0 > 0.5 && $0 < table.contentSize.width - 0.5 }.sorted()
    let needed = rowTops.count + columnEdges.count
    while lines.count < needed {
      let line = UIView()
      content.addSubview(line)
      lines.append(line)
    }
    while lines.count > needed {
      lines.removeLast().removeFromSuperview()
    }
    for line in lines {
      line.backgroundColor = palette.separator
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let table else { return }
    scroll.frame = bounds
    content.frame = CGRect(origin: .zero, size: table.contentSize)
    scroll.contentSize = table.contentSize
    for (view, cell) in zip(cellViews, table.cells) {
      view.textFrame = cell.textFrame
    }
    let headerHeight = table.cells.first { $0.row == 0 }?.frame.height ?? 0
    headerFill.frame = CGRect(x: 0, y: 0, width: table.contentSize.width, height: headerHeight)
    let hairline = 1 / max(1, window?.screen.scale ?? 2)
    let rowTops = Set(table.cells.map(\.frame.minY)).sorted().dropFirst()
    let columnEdges = Set(table.cells.filter { $0.row == 0 }.map { table.isRightToLeft ? $0.frame.minX : $0.frame.maxX })
      .filter { $0 > 0.5 && $0 < table.contentSize.width - 0.5 }.sorted()
    var index = 0
    for top in rowTops where index < lines.count {
      lines[index].frame = CGRect(x: 0, y: top, width: table.contentSize.width, height: hairline)
      index += 1
    }
    for edge in columnEdges where index < lines.count {
      lines[index].frame = CGRect(x: edge, y: 0, width: hairline, height: table.contentSize.height)
      index += 1
    }
  }
}

/// An image slot: a placeholder fill until the photo loads; never changes size.
private final class RichImageView: UIView {
  private let photo = PlatformPhotoView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 8
    layer.cornerCurve = .continuous
    clipsToBounds = true
    photo.photoContentMode = .aspectFill
    photo.showsTinyThumbnailBackground = true
    addSubview(photo)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ info: PhotoInfo?, palette: MessageRichView.Palette) {
    backgroundColor = palette.codeFill
    photo.isHidden = info == nil
    photo.setPhoto(info)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    photo.frame = bounds
  }
}

private final class RichAlbumView: UIView {
  private let scroll = UIScrollView()
  private var items: [RichImageView] = []
  private var frames: [CGRect] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    scroll.showsHorizontalScrollIndicator = false
    addSubview(scroll)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ album: [RichLayout.AlbumItem], photos: [String: PhotoInfo], palette: MessageRichView.Palette) {
    while items.count < album.count {
      let view = RichImageView()
      scroll.addSubview(view)
      items.append(view)
    }
    while items.count > album.count {
      items.removeLast().removeFromSuperview()
    }
    for (view, item) in zip(items, album) {
      view.configure(photos[item.id], palette: palette)
    }
    frames = album.map(\.frame)
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    scroll.frame = bounds
    for (view, frame) in zip(items, frames) {
      view.frame = frame
    }
    scroll.contentSize = CGSize(width: frames.last?.maxX ?? 0, height: bounds.height)
  }
}

/// A disclosure's summary row: activity icon, title and chevron. Tapping toggles it.
private final class RichDisclosureView: UIControl {
  private let title = MessageTextView()
  private let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)))
  private let activity = UIImageView(image: UIImage(systemName: "sparkle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)))
  private var disclosure: RichLayout.Disclosure?
  var onToggle: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    title.isUserInteractionEnabled = false
    title.clipsToBounds = true
    chevron.contentMode = .center
    activity.contentMode = .center
    for view in [title, chevron, activity] as [UIView] {
      view.isUserInteractionEnabled = false
      addSubview(view)
    }
    addTarget(self, action: #selector(toggle), for: .touchUpInside)
    accessibilityTraits = .button
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ disclosure: RichLayout.Disclosure, palette: MessageRichView.Palette) {
    self.disclosure = disclosure
    title.setLayout(disclosure.summary)
    chevron.tintColor = palette.secondary
    activity.tintColor = palette.secondary
    activity.isHidden = disclosure.activityFrame == nil
    accessibilityLabel = disclosure.summary.text.string
    accessibilityValue = disclosure.isExpanded ? "Expanded" : "Collapsed"
    if disclosure.isInProgress {
      startShimmer()
    } else {
      title.layer.removeAnimation(forKey: "shimmer")
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let disclosure else { return }
    title.textFrame = disclosure.titleFrame
    chevron.frame = disclosure.chevronFrame
    chevron.transform = disclosure.isExpanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
    if let frame = disclosure.activityFrame { activity.frame = frame }
  }

  private func startShimmer() {
    guard title.layer.animation(forKey: "shimmer") == nil, !UIAccessibility.isReduceMotionEnabled else { return }
    let pulse = CABasicAnimation(keyPath: "opacity")
    pulse.fromValue = 1
    pulse.toValue = 0.45
    pulse.duration = 0.9
    pulse.autoreverses = true
    pulse.repeatCount = .infinity
    title.layer.add(pulse, forKey: "shimmer")
  }

  @objc private func toggle() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    onToggle?()
  }
}
