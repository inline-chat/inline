import InlineKit
import InlineMessageLayout
import InlineSyntaxHighlighting
import InlineUI
import UIKit

/// Draws a planned `RichLayout`: one view per node, kept by path and kind, so an update or a
/// disclosure moves the same views. Geometry is set in `layoutNodes()`, inside the message's
/// animation.
final class MessageRichView: UIView {
  struct Palette: Equatable {
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
  /// Nodes removed by an animated update, fading out on the message's curve. They are out of
  /// `views`, so a node that comes back gets a fresh view and these only ever leave.
  private(set) var leavingNodes: [UIView] = []

  var onDisclosureToggle: ((RichPath, Bool) -> Void)?

  /// Read before the body: the sender and the blocks above it.
  var accessibilityLead: String? {
    didSet { if accessibilityLead != oldValue { accessibilityNodes = nil } }
  }

  /// Read after the body: the message's time.
  var accessibilityTime: String? {
    didSet { if accessibilityTime != oldValue { accessibilityNodes = nil } }
  }

  private var accessibilityNodes: [Any]?

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = false
    // A container: the body reads node by node, so disclosures and copy buttons are reachable.
    isAccessibilityElement = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Creates and configures node views for `layout`; call without animation. New nodes start
  /// at their final frame, faded out when `animated`; removed ones fade out when `animated`
  /// and leave at once otherwise. A row showing another message starts its code, tables and
  /// albums scrolled to the beginning.
  func apply(_ layout: RichLayout, palette: Palette, photos: [String: PhotoInfo], animated: Bool, isNewMessage: Bool = false) {
    self.layout = layout
    self.photos = photos
    if !animated {
      removeLeavingNodes(leavingNodes)
    }
    if isNewMessage {
      for view in views.values {
        (view as? RichScrollResetting)?.resetScrollPosition()
      }
    }
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
      views[key] = nil
      if animated {
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        leavingNodes.append(view)
      } else {
        view.removeFromSuperview()
      }
    }
    order = keys
    accessibilityNodes = nil
    // Decorations behind content: quotes first, in tree order.
    for key in order {
      guard let view = views[key] else { continue }
      if view is RichQuoteView { sendSubviewToBack(view) } else { bringSubviewToFront(view) }
    }
  }

  /// Moves nodes to the layout's frames and fades out removed ones. Call inside the message's
  /// animation.
  func layoutNodes() {
    guard let layout else { return }
    for placed in layout.nodes {
      guard let view = views[Key(path: placed.path, kind: Self.kind(of: placed.node))] else { continue }
      Self.place(view, at: placed.frame)
      view.alpha = 1
      view.layoutIfNeeded()
    }
    for view in leavingNodes {
      view.alpha = 0
    }
  }

  /// Drops nodes that finished fading out; call from the message animation's completion with
  /// the nodes that were leaving when it started.
  func removeLeavingNodes(_ nodes: [UIView]) {
    guard !nodes.isEmpty else { return }
    for node in nodes {
      guard let index = leavingNodes.firstIndex(where: { $0 === node }) else { continue }
      leavingNodes.remove(at: index)
      node.removeFromSuperview()
    }
  }

  /// Draws the frontier text node up to `length` characters of the message's flat text while it
  /// streams; nil draws everything. Only the node the plan marked as the frontier changes; the
  /// host replans when the count passes the plan's `revealLimit`.
  func reveal(_ length: Int?) {
    guard let layout else { return }
    for placed in layout.nodes where placed.revealedLength != nil {
      guard case let .text(text, _) = placed.node, let source = placed.sourceRange,
            let view = views[Key(path: placed.path, kind: Self.kind(of: placed.node))] as? MessageTextView
      else { continue }
      view.revealedLength = length.flatMap { length in
        let local = max(0, length - source.lowerBound)
        return local < text.length ? local : nil
      }
    }
  }

  /// The view drawing the node at `path`, for tests and accessibility. Markers use their item's
  /// path with -1 appended.
  func nodeView(at path: RichPath) -> UIView? {
    views.first { $0.key.path == path }?.value
  }

  /// Text under `point`, for taps on links and mentions: the node's attributed string and the
  /// character index in it. Covers table cells, which scroll inside their table.
  func textHit(at point: CGPoint) -> (NSAttributedString, Int)? {
    for key in order {
      guard let view = views[key] else { continue }
      if let text = view as? MessageTextView, text.frame.insetBy(dx: -4, dy: -2).contains(point) {
        if let index = text.characterIndex(at: convert(point, to: text)), index < text.revealedLength ?? .max {
          return (text.layout.text.attributedString, index)
        }
      } else if let table = view as? RichTableView, table.frame.contains(point),
                let hit = table.textHit(at: convert(point, to: table))
      {
        return hit
      }
    }
    return nil
  }

  // MARK: - Accessibility

  override var accessibilityElements: [Any]? {
    get {
      let elements = accessibilityNodes ?? makeAccessibilityNodes()
      accessibilityNodes = elements
      // The lead and time have no view of their own; they sit at the body's top and bottom.
      let strip = min(bounds.height, 22)
      for case let element as UIAccessibilityElement in elements {
        let isLead = element.accessibilityIdentifier == "lead"
        element.accessibilityFrameInContainerSpace = CGRect(
          x: 0,
          y: isLead ? 0 : max(0, bounds.height - strip),
          width: bounds.width,
          height: strip
        )
      }
      return elements
    }
    set {}
  }

  /// Node views in reading order, with the sender before them and the time after.
  private func makeAccessibilityNodes() -> [Any] {
    var elements: [Any] = []
    if let accessibilityLead {
      let lead = UIAccessibilityElement(accessibilityContainer: self)
      lead.accessibilityIdentifier = "lead"
      lead.accessibilityLabel = accessibilityLead
      elements.append(lead)
    }
    for key in order {
      guard let view = views[key] else { continue }
      if view.isAccessibilityElement || view is RichCodeView {
        elements.append(view)
      }
    }
    if let accessibilityTime {
      let time = UIAccessibilityElement(accessibilityContainer: self)
      time.accessibilityIdentifier = "time"
      time.accessibilityLabel = accessibilityTime
      elements.append(time)
    }
    return elements
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
    case let .marker(_, symbol): symbol == nil ? 1 : 9
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
    case .text: MessageTextView()
    case let .marker(_, symbol): symbol == nil ? MessageTextView() as UIView : RichListSymbolView()
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
    case let .text(text, _):
      guard let view = view as? MessageTextView else { return }
      view.setLayout(text)
      view.revealedLength = placed.revealedLength
      view.isAccessibilityElement = true
      view.accessibilityTraits = .staticText
      view.accessibilityLabel = text.text.string
    case let .marker(text, symbol):
      if let symbol, let view = view as? RichListSymbolView {
        view.configure(symbol, marker: text, color: palette.text)
      } else if let view = view as? MessageTextView {
        view.setLayout(text)
        view.isAccessibilityElement = true
        view.accessibilityTraits = .staticText
        view.accessibilityLabel = text.text.string
      }
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
      view.isAccessibilityElement = true
      view.accessibilityTraits = .image
      view.accessibilityLabel = "Image"
    case let .album(items):
      (view as? RichAlbumView)?.configure(items, photos: photos, palette: palette)
      view.isAccessibilityElement = true
      view.accessibilityTraits = .image
      view.accessibilityLabel = items.count == 1 ? "Image" : "\(items.count) images"
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

/// Node views that scroll sideways and start over for new content.
private protocol RichScrollResetting: UIView {
  var needsScrollReset: Bool { get set }
}

extension RichScrollResetting {
  func resetScrollPosition() {
    needsScrollReset = true
    setNeedsLayout()
  }
}

/// A code block: a filled box with an optional language header and line numbers, and a body
/// that scrolls sideways instead of wrapping.
private final class RichCodeView: UIView, RichScrollResetting {
  private let header = MessageTextView()
  private let scroll = UIScrollView()
  private let numbers = MessageTextView()
  private let body = MessageTextView()
  private let copyButton = UIButton(type: .system)
  private var code: RichLayout.Code?
  private var palette: MessageRichView.Palette?
  private var highlightTask: Task<Void, Never>?
  /// Tokens colored into the body now.
  private var shownTokens: [CodeToken] = []
  var needsScrollReset = true

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
    // Reads the code, then offers the copy button.
    body.isAccessibilityElement = true
    body.accessibilityTraits = .staticText
    accessibilityElements = [body, copyButton]
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
    let previous = self.code
    let raw = code.text.text.string
    let isSameCode = previous.map { $0.text.text == code.text.text && $0.language == code.language } ?? false
    if !isSameCode || self.palette != palette {
      // A block that only grew, as it does while streaming, keeps its place; other code starts
      // scrolled to its beginning.
      let previousText = previous?.text.text.string ?? ""
      let grows = previous.map { $0.language == code.language && (raw as NSString).hasPrefix(previousText) } ?? false
      if !grows {
        needsScrollReset = true
      }
      highlightTask?.cancel()
      if let tokens = CodeSyntaxHighlighter.cachedTokens(for: raw, language: code.language) {
        // Already highlighted somewhere: colored on the first frame.
        color(code, tokens: tokens, palette: palette)
      } else {
        // Until the new tokens arrive, keep the colors of the code that was already shown, so a
        // streamed chunk never flashes back to plain.
        let length = (previousText as NSString).length
        let kept = grows ? shownTokens.filter { NSMaxRange($0.range) <= length } : []
        if kept.isEmpty {
          body.setLayout(code.text)
          shownTokens = []
        } else {
          color(code, tokens: kept, palette: palette)
        }
        highlight(code, palette: palette)
      }
    }
    self.code = code
    self.palette = palette
    let label = code.languageLabel.map { "\($0.text.string) code" } ?? "Code"
    body.accessibilityLabel = "\(label), \(raw)"
    copyButton.tintColor = palette.secondary
    setNeedsLayout()
  }

  /// Colors tokens once the shared highlighter returns them. Only colors change, so the
  /// code keeps its planned geometry.
  private func highlight(_ code: RichLayout.Code, palette: MessageRichView.Palette) {
    guard CodeSyntaxHighlighter.supports(language: code.language) else { return }
    let raw = code.text.text.string
    let language = code.language
    highlightTask = Task { [weak self] in
      guard let tokens = try? await CodeSyntaxHighlighter.shared.tokens(for: raw, language: language),
            !Task.isCancelled, let self, let current = self.code, current.text.text.string == raw
      else { return }
      color(current, tokens: tokens, palette: self.palette ?? palette)
      setNeedsLayout()
    }
  }

  /// Draws `code` with `tokens` colored. Typesets the body again; geometry is unchanged.
  private func color(_ code: RichLayout.Code, tokens: [CodeToken], palette: MessageRichView.Palette) {
    let colored = NSMutableAttributedString(attributedString: code.text.text.attributedString)
    let length = colored.length
    for token in tokens where token.range.location >= 0 && NSMaxRange(token.range) <= length {
      colored.addAttribute(.foregroundColor, value: Self.color(for: token.kind, palette: palette), range: token.range)
    }
    let traits = traitCollection
    let scale = traits.displayScale > 0 ? traits.displayScale : UITraitCollection.current.displayScale
    let text = MessageText(colored.coreTextReady(for: traits))
    body.setLayout(TextLayouter.layout(text, maximumWidth: .greatestFiniteMagnitude, grid: PixelGrid(scale: scale)))
    shownTokens = tokens
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
    if needsScrollReset {
      needsScrollReset = false
      UIView.performWithoutAnimation { scroll.contentOffset = .zero }
    }
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

/// Telegram-style quote: accent tint at 10%, a square rail clipped by the rounded block,
/// and a small closing quote mark in the trailing top corner.
private final class RichQuoteView: UIView {
  private let rail = UIView()
  private let icon = UIImageView(image: UIImage(
    systemName: "quote.closing",
    withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
  ))
  private var isRightToLeft = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 4
    layer.cornerCurve = .continuous
    clipsToBounds = true
    icon.contentMode = .scaleAspectFit
    addSubview(rail)
    addSubview(icon)
    isUserInteractionEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(isRightToLeft: Bool, palette: MessageRichView.Palette) {
    self.isRightToLeft = isRightToLeft
    backgroundColor = palette.accent.withAlphaComponent(0.1)
    rail.backgroundColor = palette.accent
    icon.tintColor = palette.accent
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    rail.frame = CGRect(x: isRightToLeft ? bounds.width - 3 : 0, y: 0, width: 3, height: bounds.height)
    icon.frame = CGRect(x: isRightToLeft ? 4 : bounds.width - 4 - 9, y: 4, width: 9, height: 9)
  }
}

/// A table that scrolls sideways when its columns don't fit; the header row is filled.
private final class RichTableView: UIView, RichScrollResetting {
  private let scroll = UIScrollView()
  private let content = UIView()
  private var cellViews: [MessageTextView] = []
  private var lines: [UIView] = []
  private let headerFill = UIView()
  private var table: RichLayout.Table?
  var needsScrollReset = true

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
    isAccessibilityElement = true
    accessibilityTraits = .staticText
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Text under `point` in this view's coordinates, through the scroll offset.
  func textHit(at point: CGPoint) -> (NSAttributedString, Int)? {
    guard bounds.contains(point) else { return nil }
    for view in cellViews {
      let local = convert(point, to: view)
      guard view.bounds.insetBy(dx: -2, dy: -2).contains(local), let index = view.characterIndex(at: local) else { continue }
      return (view.layout.text.attributedString, index)
    }
    return nil
  }

  func configure(_ table: RichLayout.Table, palette: MessageRichView.Palette) {
    // A table that only grew, as it does while streaming, keeps its place; another one starts
    // at its first column.
    if let previous = self.table, !Self.table(table, extends: previous) {
      needsScrollReset = true
    }
    self.table = table
    accessibilityLabel = Self.accessibilityText(table)
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
    if needsScrollReset, bounds.width > 0 {
      needsScrollReset = false
      // Right-to-left tables start at their trailing edge, where the first column is.
      let start = table.isRightToLeft ? max(0, table.contentSize.width - bounds.width) : 0
      UIView.performWithoutAnimation { scroll.contentOffset = CGPoint(x: start, y: 0) }
    }
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

  /// Whether `table` is `previous` with more text or rows: same columns, and every earlier
  /// cell still starts with what it had.
  private static func table(_ table: RichLayout.Table, extends previous: RichLayout.Table) -> Bool {
    let columns = table.cells.count(where: { $0.row == 0 })
    guard table.isRightToLeft == previous.isRightToLeft, columns > 0,
          columns == previous.cells.count(where: { $0.row == 0 }),
          table.cells.count >= previous.cells.count
    else { return false }
    return zip(previous.cells, table.cells).allSatisfy { old, new in
      old.row == new.row && old.column == new.column
        && (new.text.text.string as NSString).hasPrefix(old.text.text.string)
    }
  }

  /// Rows in reading order, cells separated by commas.
  private static func accessibilityText(_ table: RichLayout.Table) -> String {
    var rows: [[String]] = []
    for cell in table.cells {
      if cell.row >= rows.count { rows.append([]) }
      rows[rows.count - 1].append(cell.text.text.string)
    }
    return "Table, " + rows.map { $0.joined(separator: ", ") }.joined(separator: "; ")
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

private final class RichAlbumView: UIView, RichScrollResetting {
  private let scroll = UIScrollView()
  private var items: [RichImageView] = []
  private var frames: [CGRect] = []
  private var ids: [String] = []
  var needsScrollReset = false

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
    // More images keep the place; a different album starts at its first image.
    let newIDs = album.map(\.id)
    if !newIDs.starts(with: ids) {
      needsScrollReset = true
    }
    ids = newIDs
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    scroll.frame = bounds
    for (view, frame) in zip(items, frames) {
      view.frame = frame
    }
    scroll.contentSize = CGSize(width: frames.last?.maxX ?? 0, height: bounds.height)
    if needsScrollReset {
      needsScrollReset = false
      UIView.performWithoutAnimation { scroll.contentOffset = .zero }
    }
  }
}

/// A disclosure's summary row: activity icon, title and chevron. Tapping toggles it.
private final class RichDisclosureView: UIControl {
  private let title = MessageTextView()
  private let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)))
  private let activity = UIImageView(image: UIImage(systemName: "sparkle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)))
  /// "2m 12s" after a working row's title, ticking once a second.
  private let elapsedLabel = UILabel()
  private var elapsedWidth: CGFloat = 0
  private var isTicking = false
  private var disclosure: RichLayout.Disclosure?
  var onToggle: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    title.isUserInteractionEnabled = false
    title.clipsToBounds = true
    chevron.contentMode = .center
    activity.contentMode = .center
    elapsedLabel.isHidden = true
    elapsedLabel.lineBreakMode = .byClipping
    for view in [title, elapsedLabel, chevron, activity] as [UIView] {
      view.isUserInteractionEnabled = false
      addSubview(view)
    }
    addTarget(self, action: #selector(toggle), for: .touchUpInside)
    isAccessibilityElement = true
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
    accessibilityValue = disclosure.isExpanded ? "Expanded" : "Collapsed"
    if disclosure.isInProgress {
      startShimmer()
    } else {
      title.layer.removeAnimation(forKey: "shimmer")
    }
    if disclosure.elapsedStart != nil {
      let titleFont = disclosure.summary.text.length > 0
        ? disclosure.summary.text.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        : nil
      elapsedLabel.font = .monospacedDigitSystemFont(ofSize: titleFont?.pointSize ?? 17, weight: .regular)
      elapsedLabel.textColor = palette.secondary.withAlphaComponent(0.7)
    }
    updateElapsed()
    updateTicking()
    setNeedsLayout()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateTicking()
  }

  /// Ticks only while on screen and the row is still counting.
  private func updateTicking() {
    let shouldTick = window != nil && disclosure?.elapsedStart != nil && !elapsedLabel.isHidden
    guard shouldTick != isTicking else { return }
    isTicking = shouldTick
    if shouldTick {
      ProgressElapsedTicker.shared.add(self) { [weak self] in self?.updateElapsed() }
    } else {
      ProgressElapsedTicker.shared.remove(self)
    }
  }

  private func updateElapsed() {
    let text = disclosure?.elapsedStart.flatMap { ProgressElapsed.text(since: $0) }
    let summary = disclosure?.fullSummary.string ?? ""
    accessibilityLabel = text.map { "\(summary), \($0)" } ?? summary
    if let text, elapsedLabel.text != text { elapsedLabel.text = text }
    let wasHidden = elapsedLabel.isHidden
    elapsedLabel.isHidden = text == nil
    if text == nil, !wasHidden { updateTicking() }
    // The width changes only at 10s, 1m, 10m and 1h; only then does the chevron move.
    let width = text == nil ? 0 : ceil(elapsedLabel.intrinsicContentSize.width)
    if width != elapsedWidth || wasHidden != elapsedLabel.isHidden {
      elapsedWidth = width
      setNeedsLayout()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let disclosure else { return }
    title.textFrame = disclosure.titleFrame
    // The plan reserves the widest time; the chevron closes up to the time actually shown.
    var chevronFrame = disclosure.chevronFrame
    if let slot = disclosure.elapsedFrame {
      let isRightToLeft = slot.midX < disclosure.titleFrame.midX
      let gap = isRightToLeft ? disclosure.titleFrame.minX - slot.maxX : slot.minX - disclosure.titleFrame.maxX
      let width = min(elapsedWidth, slot.width)
      let unused = elapsedLabel.isHidden ? slot.width + gap : slot.width - width
      elapsedLabel.frame = CGRect(x: isRightToLeft ? slot.maxX - width : slot.minX, y: slot.minY, width: width, height: slot.height)
      chevronFrame.origin.x += isRightToLeft ? unused : -unused
    }
    chevron.frame = chevronFrame
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

/// A bullet or checkbox drawn as a shape, like the macOS renderer. It fills the frame the planner
/// measured for the marker's glyph, so the marker column keeps its width.
private final class RichListSymbolView: UIView {
  private var symbol: RichListSymbol = .bullet
  private var marker: TextLayout = .empty
  private var color: UIColor = .label

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    contentMode = .redraw
    isUserInteractionEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ symbol: RichListSymbol, marker: TextLayout, color: UIColor) {
    self.symbol = symbol
    self.marker = marker
    self.color = color
    switch symbol {
    case .bullet:
      isAccessibilityElement = false
    case let .checkbox(isChecked):
      isAccessibilityElement = true
      accessibilityLabel = isChecked ? "Checked" : "Unchecked"
    }
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    let font = marker.text.length > 0
      ? marker.text.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
      : nil
    let pointSize = font?.pointSize ?? 17
    // Centered on the first line's lowercase middle, where the glyph sat.
    let baseline = marker.lines.first?.baseline ?? bounds.height * 0.75
    switch symbol {
    case .bullet:
      let diameter = max(4.25, pointSize * 0.27)
      let midY = baseline - (font?.xHeight ?? pointSize * 0.5) / 2
      color.setFill()
      UIBezierPath(ovalIn: CGRect(x: bounds.midX - diameter / 2, y: midY - diameter / 2, width: diameter, height: diameter)).fill()
    case let .checkbox(isChecked):
      let side = min(12, max(9, pointSize * 0.72))
      let midY = baseline - (font?.capHeight ?? pointSize * 0.7) / 2
      let box = CGRect(x: bounds.midX - side / 2, y: midY - side / 2, width: side, height: side)
      let outline = UIBezierPath(roundedRect: box, cornerRadius: 2)
      outline.lineWidth = 1.25
      color.withAlphaComponent(0.72).setStroke()
      outline.stroke()
      guard isChecked else { return }
      let check = UIBezierPath()
      check.lineWidth = 1.55
      check.lineCapStyle = .round
      check.lineJoinStyle = .round
      check.move(to: CGPoint(x: box.minX + side * 0.22, y: box.midY))
      check.addLine(to: CGPoint(x: box.minX + side * 0.43, y: box.minY + side * 0.75))
      check.addLine(to: CGPoint(x: box.maxX - side * 0.18, y: box.minY + side * 0.24))
      color.setStroke()
      check.stroke()
    }
  }
}
