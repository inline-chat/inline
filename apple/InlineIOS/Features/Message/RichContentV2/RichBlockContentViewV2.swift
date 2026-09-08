import InlineIOSUI
import InlineKit
import InlineProtocol
import InlineSyntaxHighlighting
import InlineUI
import UIKit
import TextProcessing

@MainActor
func richTextHasInteractiveEntity(at index: Int, in text: NSAttributedString) -> Bool {
  RichBlockEntityAccessibilityActionsV2.hasInteractiveEntity(at: index, in: text)
}

private func richTextCharacterIndex(
  at point: CGPoint,
  in textView: UITextView,
  hitSlop: CGFloat = 2
) -> Int? {
  guard textView.bounds.contains(point),
        let attributedText = textView.attributedText,
        attributedText.length > 0
  else { return nil }

  let textContainer = textView.textContainer
  let layoutManager = textView.layoutManager
  // UIView conversion already returns coordinates in the scroll view's bounds,
  // whose origin is its content offset. Adding the offset again breaks hits in
  // horizontally scrolled code and in RTL text with a nonzero bounds origin.
  let containerPoint = CGPoint(
    x: point.x - textView.textContainerInset.left,
    y: point.y - textView.textContainerInset.top
  )
  layoutManager.ensureLayout(for: textContainer)
  guard layoutManager.usedRect(for: textContainer)
    .insetBy(dx: -hitSlop, dy: -hitSlop)
    .contains(containerPoint)
  else { return nil }

  var fraction: CGFloat = 0
  let glyph = layoutManager.glyphIndex(
    for: containerPoint,
    in: textContainer,
    fractionOfDistanceThroughGlyph: &fraction
  )
  guard glyph < layoutManager.numberOfGlyphs else { return nil }
  let glyphRect = layoutManager.boundingRect(
    forGlyphRange: NSRange(location: glyph, length: 1),
    in: textContainer
  )
  guard glyphRect.insetBy(dx: -hitSlop, dy: -hitSlop).contains(containerPoint) else {
    return nil
  }
  let character = layoutManager.characterIndexForGlyph(at: glyph)
  return character < attributedText.length ? character : nil
}

struct RichBlockPaletteV2 {
  let primary: UIColor
  let secondary: UIColor
  let accent: UIColor
  let subtleFill: UIColor
  let codeFill: UIColor
  let separator: UIColor
  let placeholder: UIColor
}

struct RichBlockImageGallerySelectionV2 {
  let image: BlockImageOccurrence
  let sourceView: UIView
  let sourceImage: UIImage?
}

@MainActor
private final class RichBlockEntityAccessibilityActionsV2: NSObject {
  private struct Binding {
    let characterIndex: Int
  }

  private struct Occurrence {
    let key: NSAttributedString.Key
    let range: NSRange
    let characterIndex: Int
  }

  private var text: NSAttributedString?
  private var actions: [UIAccessibilityCustomAction]?
  private var bindings: [ObjectIdentifier: Binding] = [:]
  private var onActivate: ((NSAttributedString, Int) -> Bool)?

  func update(
    text next: NSAttributedString?,
    onActivate: @escaping (NSAttributedString, Int) -> Bool
  ) -> [UIAccessibilityCustomAction]? {
    self.onActivate = onActivate
    guard let next, next.length > 0 else {
      clear()
      return nil
    }
    if text?.isEqual(to: next) == true { return actions }

    bindings.removeAll(keepingCapacity: true)
    let snapshot = NSAttributedString(attributedString: next)
    let occurrences = Self.occurrences(in: snapshot)
    text = snapshot
    guard !occurrences.isEmpty else {
      actions = nil
      return nil
    }

    let baseNames = occurrences.map { Self.actionName(for: $0, in: snapshot) }
    let totals = Dictionary(grouping: baseNames, by: { $0 }).mapValues(\.count)
    var positions: [String: Int] = [:]
    let rebuilt = zip(occurrences, baseNames).map { occurrence, baseName in
      positions[baseName, default: 0] += 1
      let name: String
      if let total = totals[baseName], total > 1 {
        name = String.localizedStringWithFormat(
          NSLocalizedString("%@ (%lld of %lld)", comment: "Disambiguates repeated VoiceOver rich-text actions"),
          baseName,
          Int64(positions[baseName, default: 1]),
          Int64(total)
        )
      } else {
        name = baseName
      }
      let action = UIAccessibilityCustomAction(
        name: name,
        target: self,
        selector: #selector(performEntityAction(_:))
      )
      bindings[ObjectIdentifier(action)] = Binding(characterIndex: occurrence.characterIndex)
      return action
    }
    actions = rebuilt
    return rebuilt
  }

  func clear() {
    text = nil
    actions = nil
    bindings.removeAll(keepingCapacity: true)
    onActivate = nil
  }

  @objc private func performEntityAction(_ action: UIAccessibilityCustomAction) -> Bool {
    guard let binding = bindings[ObjectIdentifier(action)],
          let text,
          binding.characterIndex >= 0,
          binding.characterIndex < text.length,
          let onActivate
    else { return false }
    return onActivate(text, binding.characterIndex)
  }

  private static func occurrences(in text: NSAttributedString) -> [Occurrence] {
    let fullRange = NSRange(location: 0, length: text.length)
    let keys: [NSAttributedString.Key] = [
      .mentionUserId,
      .mentionGroupId,
      .threadLink,
      .inlineCode,
      .botCommand,
      .emailAddress,
      .phoneNumber,
      .link,
    ]
    var accepted: [Occurrence] = []
    var claimed: [NSRange] = []

    for key in keys {
      var newlyClaimed: [NSRange] = []
      var location = 0
      while location < text.length {
        var range = NSRange(location: 0, length: 0)
        let value = text.attribute(key, at: location, longestEffectiveRange: &range, in: fullRange)
        let next = max(location + 1, NSMaxRange(range))
        defer { location = next }
        guard range.length > 0,
              valid(value, for: key),
              let characterIndex = firstUnclaimedIndex(in: range, claimed: claimed)
        else { continue }
        accepted.append(Occurrence(key: key, range: range, characterIndex: characterIndex))
        newlyClaimed.append(range)
      }
      // Effective ranges for one key never overlap. Merge once per key,
      // rather than sorting the growing claim set for every occurrence.
      var merged: [NSRange] = []
      for range in (claimed + newlyClaimed).sorted(by: { $0.location < $1.location }) {
        if let last = merged.last, range.location <= NSMaxRange(last) {
          merged[merged.count - 1].length = max(NSMaxRange(last), NSMaxRange(range)) - last.location
        } else {
          merged.append(range)
        }
      }
      claimed = merged
    }

    return accepted.sorted {
      if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
      return $0.range.length < $1.range.length
    }
  }

  private static func firstUnclaimedIndex(in range: NSRange, claimed: [NSRange]) -> Int? {
    var location = range.location
    let end = NSMaxRange(range)
    var low = 0, high = claimed.count
    while low < high {
      let middle = (low + high) / 2
      if NSMaxRange(claimed[middle]) <= location { low = middle + 1 } else { high = middle }
    }
    for occupied in claimed.dropFirst(low) {
      if occupied.location >= end { break }
      if occupied.location > location { return location }
      location = max(location, NSMaxRange(occupied))
      if location >= end { return nil }
    }
    return location < end ? location : nil
  }

  static func hasInteractiveEntity(at index: Int, in text: NSAttributedString) -> Bool {
    guard index >= 0, index < text.length else { return false }
    let keys: [NSAttributedString.Key] = [
      .mentionUserId, .mentionGroupId, .threadLink, .inlineCode,
      .botCommand, .emailAddress, .phoneNumber, .link,
    ]
    return keys.contains { valid(text.attribute($0, at: index, effectiveRange: nil), for: $0) }
  }

  private static func valid(_ value: Any?, for key: NSAttributedString.Key) -> Bool {
    if key == .mentionUserId || key == .mentionGroupId {
      return (value as? Int64).map { $0 > 0 } ?? false
    }
    if key == .threadLink { return value is ThreadLinkTarget }
    if key == .inlineCode { return value as? Bool == true }
    if key == .botCommand { return value is String }
    if key == .emailAddress || key == .phoneNumber {
      guard let value = value as? String else { return false }
      return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if key == .link { return resolvedLinkURL(value) != nil }
    return false
  }

  private static func resolvedLinkURL(_ value: Any?) -> URL? {
    if let url = value as? URL, LinkDetector.isSupportedLinkURL(url) { return url }
    guard let string = value as? String, !string.isEmpty else { return nil }
    if let url = URL(string: string), LinkDetector.isSupportedLinkURL(url) { return url }
    guard !string.contains("://"),
          let url = URL(string: "https://\(string)"),
          LinkDetector.isSupportedLinkURL(url)
    else { return nil }
    return url
  }

  private static func actionName(for occurrence: Occurrence, in text: NSAttributedString) -> String {
    let source = RichTextMath.sourceText(text, range: occurrence.range)
      ?? (text.string as NSString).substring(with: occurrence.range)
    let collapsed = source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let snippet = collapsed.count > 60 ? String(collapsed.prefix(59)) + "…" : collapsed

    let name: String
    let format: String
    switch occurrence.key {
    case .mentionUserId:
      name = NSLocalizedString("Open mention", comment: "VoiceOver action for a rich-text user mention")
      format = NSLocalizedString("Open mention: %@", comment: "VoiceOver action for a labeled rich-text user mention")
    case .mentionGroupId:
      name = NSLocalizedString("Open group mention", comment: "VoiceOver action for a rich-text group mention")
      format = NSLocalizedString("Open group mention: %@", comment: "VoiceOver action for a labeled rich-text group mention")
    case .threadLink:
      name = NSLocalizedString("Open thread", comment: "VoiceOver action for a rich-text thread link")
      format = NSLocalizedString("Open thread: %@", comment: "VoiceOver action for a labeled rich-text thread link")
    case .inlineCode:
      name = NSLocalizedString("Copy code", comment: "VoiceOver action for inline code")
      format = NSLocalizedString("Copy code: %@", comment: "VoiceOver action for labeled inline code")
    case .botCommand:
      name = NSLocalizedString("Send command", comment: "VoiceOver action for a bot command")
      format = NSLocalizedString("Send command: %@", comment: "VoiceOver action for a labeled bot command")
    case .emailAddress:
      name = NSLocalizedString("Copy email", comment: "VoiceOver action for an email address")
      format = NSLocalizedString("Copy email: %@", comment: "VoiceOver action for a labeled email address")
    case .phoneNumber:
      name = NSLocalizedString("Copy number", comment: "VoiceOver action for a phone number")
      format = NSLocalizedString("Copy number: %@", comment: "VoiceOver action for a labeled phone number")
    default:
      name = NSLocalizedString("Open link", comment: "VoiceOver action for a rich-text link")
      format = NSLocalizedString("Open link: %@", comment: "VoiceOver action for a labeled rich-text link")
    }
    return snippet.isEmpty ? name : String.localizedStringWithFormat(format, snippet)
  }
}

private struct RichBlockRenderContextV2 {
  let math: RichTextMath.Snapshot
  let attributedText: NSAttributedString
  let baseFontSize: CGFloat
  let palette: RichBlockPaletteV2
  let message: InlineKit.Message
  let onDisclosureToggle: (BlockContentPath, Bool) -> Void
  let onEntityTap: (NSAttributedString, Int) -> Bool
  let onImageTap: (RichBlockImageGallerySelectionV2) -> Void

  @MainActor func text(for node: RichBlockLayoutPlanV2.TextNode, maximumWidth: CGFloat? = nil) -> NSAttributedString {
    if let literal = node.literal {
      return NSAttributedString(
        string: literal,
        attributes: [
          .font: UIFont.systemFont(ofSize: baseFontSize),
          .foregroundColor: palette.primary,
        ]
      )
    }
    return RichBlockLayoutPlannerV2.styledText(
      from: attributedText,
      range: node.range,
      role: node.role,
      baseFontSize: baseFontSize,
      isRTL: node.isRTL,
      math: math,
      maximumWidth: maximumWidth
    ) ?? NSAttributedString(string: "")
  }
}

private class RichBlockRenderableViewV2: UIView {
  let reuseKind: RichBlockRenderKindV2

  init(_ reuseKind: RichBlockRenderKindV2) {
    self.reuseKind = reuseKind
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {}
  func updateLayout(node: RichBlockLayoutPlanV2.Node) {}
  func prepareForReuse() {
    alpha = 1
    transform = .identity
  }
}

private protocol RichBlockEntityHittableV2: AnyObject {
  func entityHit(at point: CGPoint) -> (text: NSAttributedString, characterIndex: Int)?
}

private protocol RichBlockTextSurfaceProvidingV2: AnyObject {
  var textSurface: UITextView { get }
}

private final class RichBlockMathNodeViewV2: RichBlockRenderableViewV2 {
  private var sourceBinding = MessageTextBindingV2()
  private let sourceView = CodeBlockTextView(usingTextLayoutManager: false)
  private let scrollView = UIScrollView()
  private let imageView = UIImageView()
  private let progress = UIActivityIndicatorView(style: .medium)
  private var request: RichTextMath.Request?
  private var imageSize: CGSize?
  private var source = ""

  init() {
    super.init(.math)
    sourceView.backgroundColor = .clear
    sourceView.isEditable = false
    sourceView.isSelectable = true
    sourceView.isScrollEnabled = false
    sourceView.textContainerInset = .zero
    sourceView.textContainer.lineFragmentPadding = 0
    sourceView.dataDetectorTypes = []
    scrollView.showsHorizontalScrollIndicator = true
    scrollView.showsVerticalScrollIndicator = false
    scrollView.alwaysBounceVertical = false
    imageView.contentMode = .scaleToFill
    scrollView.addSubview(imageView)
    addSubview(sourceView)
    addSubview(scrollView)
    addSubview(progress)
    isAccessibilityElement = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .math(math) = node.kind,
          math.range.location >= 0, math.range.length >= 0,
          math.range.location <= context.attributedText.length,
          math.range.length <= context.attributedText.length - math.range.location
    else { prepareForReuse(); return }
    source = (context.attributedText.string as NSString).substring(with: math.range)
    let next = RichTextMath.request(text: context.attributedText, range: math.range, fontSize: context.baseFontSize)
    if request != next {
      imageView.image = nil
      scrollView.contentOffset = .zero
    }
    request = next
    imageSize = math.imageSize
    if let image = context.math.image(for: math.range) {
      imageView.image = UIImage(cgImage: image.image, scale: image.scale, orientation: .up)
    }
    let rendered = math.imageSize != nil
    if !rendered { imageView.image = nil }
    sourceView.isHidden = rendered
    scrollView.isHidden = !rendered
    if rendered, imageView.image == nil { progress.startAnimating() } else { progress.stopAnimating() }
    if !rendered {
      sourceBinding.apply(context.text(for: .init(range: math.range, role: .paragraph, literal: nil, isRTL: false)), to: sourceView)
    } else {
      sourceBinding.apply(nil, to: sourceView)
    }
    isAccessibilityElement = rendered
    if rendered {
      accessibilityTraits = .image
      accessibilityLabel = "Formula: \(source)"
      accessibilityCustomActions = [
        UIAccessibilityCustomAction(
          name: NSLocalizedString("Copy LaTeX", comment: "VoiceOver action for rendered math"),
          target: self,
          selector: #selector(copySource)
        ),
      ]
    } else {
      accessibilityLabel = nil
      accessibilityCustomActions = nil
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    sourceView.frame = bounds
    scrollView.frame = bounds
    let size = imageSize ?? .zero
    imageView.frame = CGRect(x: 0, y: max(0, (bounds.height - size.height) / 2), width: size.width, height: size.height)
    scrollView.contentSize = CGSize(width: max(bounds.width, size.width), height: bounds.height)
    progress.center = CGPoint(x: min(bounds.width / 2, 16), y: bounds.height / 2)
  }

  @objc private func copySource() -> Bool {
    guard !source.isEmpty else { return false }
    UIPasteboard.general.string = source
    return true
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    progress.stopAnimating()
    imageView.image = nil
    sourceBinding.apply(nil, to: sourceView)
    request = nil
    imageSize = nil
    source = ""
    isAccessibilityElement = false
    accessibilityLabel = nil
    accessibilityCustomActions = nil
  }
}

private final class RichBlockTextNodeViewV2: RichBlockRenderableViewV2,
  RichBlockEntityHittableV2,
  RichBlockTextSurfaceProvidingV2,
  UIGestureRecognizerDelegate
{
  // Measurement, entity hit testing, and code decorations all use TextKit 1.
  // Select that engine before the first layout instead of switching after drawing.
  private let textView = CodeBlockTextView(usingTextLayoutManager: false)
  private var textBinding = MessageTextBindingV2()
  private let entityAccessibility = RichBlockEntityAccessibilityActionsV2()
  var textSurface: UITextView {
    textView
  }

  private var onEntityTap: ((NSAttributedString, Int) -> Bool)?

  init(kind: RichBlockRenderKindV2 = .text) {
    super.init(kind)
    textView.backgroundColor = .clear
    textView.isEditable = false
    textView.isSelectable = false
    textView.useManualMessageLayout()
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.dataDetectorTypes = []
    textView.isUserInteractionEnabled = true
    addSubview(textView)
    let entityTap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    entityTap.delegate = self
    textView.addGestureRecognizer(entityTap)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if textView.frame != bounds { textView.frame = bounds }
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .text(text) = node.kind else { return }
    // New nodes already have their planned frame. Bind at that width instead
    // of making UIKit lay out the whole source in an initial zero-width view.
    if textView.bounds.width == 0, bounds.width > 0 { textView.frame = bounds }
    let attributed = context.text(for: text, maximumWidth: node.frame.width)
    textBinding.apply(attributed, to: textView)
    onEntityTap = context.onEntityTap
    isAccessibilityElement = true
    if case .heading = text.role { accessibilityTraits = [.staticText, .header] }
    else { accessibilityTraits = [.staticText] }
    accessibilityLabel = RichTextMath.sourceText(textView.attributedText) ?? textView.attributedText.string
    accessibilityCustomActions = entityAccessibility.update(
      text: textView.attributedText,
      onActivate: context.onEntityTap
    )
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    textBinding.apply(nil, to: textView)
    onEntityTap = nil
    accessibilityLabel = nil
    accessibilityCustomActions = nil
    entityAccessibility.clear()
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let hit = entityHit(at: gestureRecognizer.location(in: self)) else { return false }
    return richTextHasInteractiveEntity(at: hit.characterIndex, in: hit.text)
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard let hit = entityHit(at: gesture.location(in: self)) else { return }
    _ = onEntityTap?(hit.text, hit.characterIndex)
  }

  func entityHit(at point: CGPoint) -> (text: NSAttributedString, characterIndex: Int)? {
    guard let attributedText = textView.attributedText, attributedText.length > 0 else { return nil }
    let point = convert(point, to: textView)
    guard let character = richTextCharacterIndex(at: point, in: textView) else { return nil }
    return (attributedText, character)
  }
}

private final class RichBlockListMarkerNodeViewV2: RichBlockRenderableViewV2 {
  private var marker = ""
  private var isRTL = false
  private var color = UIColor.label
  private var font = UIFont.systemFont(ofSize: 17)

  init() {
    super.init(.listMarker)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    isOpaque = false
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .text(text) = node.kind,
          case .listMarker = text.role,
          let marker = text.literal
    else { return }
    self.marker = marker
    isRTL = text.isRTL
    color = context.palette.primary
    font = .systemFont(ofSize: context.baseFontSize)
    setNeedsDisplay()
    isAccessibilityElement = true
    accessibilityTraits = .staticText
    accessibilityLabel = switch marker {
      case "•": String(localized: "List item")
      case "☑": String(localized: "Checked item")
      case "☐": String(localized: "Unchecked item")
      default: String(localized: "Item \(marker)")
    }
  }

  override func draw(_ rect: CGRect) {
    super.draw(rect)
    guard !marker.isEmpty else { return }
    if marker == "•" {
      let diameter = max(4.25, font.pointSize * 0.27)
      let x = isRTL ? bounds.width - diameter : 0
      let lineHeight = ceil(font.lineHeight)
      let markerRect = CGRect(
        x: floor(x),
        y: floor((min(bounds.height, lineHeight) - diameter) / 2) + 1,
        width: diameter,
        height: diameter
      )
      color.setFill()
      UIBezierPath(ovalIn: markerRect).fill()
      return
    }

    if marker == "☐" || marker == "☑" {
      let side = min(12, max(9, font.pointSize * 0.72))
      let x = isRTL ? bounds.width - side : 0
      let markerRect = CGRect(
        x: floor(x) + 0.5,
        y: floor((min(bounds.height, font.lineHeight) - side) / 2) + 1.5,
        width: side,
        height: side
      )
      let box = UIBezierPath(roundedRect: markerRect, cornerRadius: 2)
      box.lineWidth = 1.25
      color.withAlphaComponent(0.72).setStroke()
      box.stroke()
      if marker == "☑" {
        let check = UIBezierPath()
        check.lineWidth = 1.55
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.move(to: CGPoint(x: markerRect.minX + side * 0.22, y: markerRect.midY))
        check.addLine(to: CGPoint(x: markerRect.minX + side * 0.43, y: markerRect.maxY - side * 0.25))
        check.addLine(to: CGPoint(x: markerRect.maxX - side * 0.18, y: markerRect.minY + side * 0.24))
        color.setStroke()
        check.stroke()
      }
      return
    }

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = isRTL ? .right : .left
    paragraph.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
    (marker as NSString).draw(
      in: bounds,
      withAttributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
      ]
    )
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    marker = ""
    accessibilityLabel = nil
    isAccessibilityElement = false
  }
}

private final class RichBlockTextShimmerViewV2: UIView {
  private let gradient = CAGradientLayer()
  private let glyphMask = CALayer()
  private var maskNeedsUpdate = true
  private var maskSize = CGSize.zero
  private var maskScale: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    gradient.colors = [
      UIColor.clear.cgColor,
      UIColor.white.cgColor,
      UIColor.clear.cgColor,
    ]
    gradient.startPoint = CGPoint(x: 0, y: 0.5)
    gradient.endPoint = CGPoint(x: 1, y: 0.5)
    gradient.locations = [0, 0.12, 0.24]
    layer.addSublayer(gradient)
    layer.mask = glyphMask
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    gradient.frame = bounds.insetBy(dx: -bounds.width, dy: 0)
    glyphMask.frame = bounds
  }

  func updateMask(from textView: UITextView) {
    guard !isHidden, bounds.width > 0, bounds.height > 0 else { return }
    let scale = max(window?.screen.scale ?? UIScreen.main.scale, 1)
    guard maskNeedsUpdate || maskSize != bounds.size || maskScale != scale else { return }
    maskNeedsUpdate = false
    maskSize = bounds.size
    maskScale = scale
    textView.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = scale
    let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
    let image = renderer.image { context in
      textView.layer.render(in: context.cgContext)
    }
    glyphMask.contents = image.cgImage
    glyphMask.contentsScale = format.scale
  }

  func invalidateMask() {
    maskNeedsUpdate = true
  }

  func setAnimating(_ animating: Bool) {
    if animating {
      guard gradient.animation(forKey: "rich-disclosure-shimmer") == nil else { return }
      let animation = CABasicAnimation(keyPath: "locations")
      animation.fromValue = [-0.2, -0.1, 0]
      animation.toValue = [1, 1.1, 1.2]
      animation.duration = 1.55
      animation.repeatCount = .infinity
      animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      gradient.add(animation, forKey: "rich-disclosure-shimmer")
    } else {
      gradient.removeAnimation(forKey: "rich-disclosure-shimmer")
    }
  }
}

private final class RichBlockDisclosureNodeViewV2: RichBlockRenderableViewV2,
  RichBlockEntityHittableV2
{
  private let title = CodeBlockTextView(usingTextLayoutManager: false)
  private var titleBinding = MessageTextBindingV2()
  private let entityAccessibility = RichBlockEntityAccessibilityActionsV2()
  private let chevron = UIImageView()
  private let activityIcon = UIImageView()
  private let shimmer = RichBlockTextShimmerViewV2()
  private var path = BlockContentPath()
  private var expanded = false
  private var progress = false
  private var isRTL = false
  private var onToggle: ((BlockContentPath, Bool) -> Void)?
  private var onEntityTap: ((NSAttributedString, Int) -> Bool)?

  init() {
    super.init(.disclosure)
    title.backgroundColor = .clear
    title.isEditable = false
    title.isSelectable = false
    title.useManualMessageLayout()
    title.textContainerInset = .zero
    title.textContainer.lineFragmentPadding = 0
    title.isUserInteractionEnabled = false
    chevron.contentMode = .scaleAspectFit
    activityIcon.contentMode = .scaleAspectFit
    activityIcon.isAccessibilityElement = false
    addSubview(title)
    addSubview(chevron)
    addSubview(activityIcon)
    addSubview(shimmer)
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    isAccessibilityElement = true
    accessibilityTraits = [.button]
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(reduceMotionStatusDidChange),
      name: UIAccessibility.reduceMotionStatusDidChangeNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .text(text) = node.kind,
          case let .disclosure(progress, isExpanded, activity) = text.role
    else { return }
    path = node.path
    expanded = isExpanded
    self.progress = progress
    isRTL = text.isRTL
    onToggle = context.onDisclosureToggle
    onEntityTap = context.onEntityTap
    activityIcon.image = activity.flatMap { UIImage(systemName: $0.symbolName) }
    activityIcon.isHidden = activity == nil
    activityIcon.tintColor = context.palette.secondary
    let attributed = NSMutableAttributedString(attributedString: context.text(
      for: text,
      maximumWidth: RichBlockDisclosureMetricsV2.titleViewportWidth(
        containerWidth: node.frame.width, hasActivity: activity != nil
      )
    ))
    attributed.addAttribute(
      .foregroundColor,
      value: context.palette.secondary,
      range: NSRange(location: 0, length: attributed.length)
    )
    if titleBinding.apply(attributed, to: title) {
      shimmer.invalidateMask()
    }
    updateChevron()
    chevron.tintColor = context.palette.secondary
    backgroundColor = .clear
    shimmer.isHidden = !progress
    accessibilityLabel = RichTextMath.sourceText(attributed) ?? attributed.string
    accessibilityValue = isExpanded
      ? NSLocalizedString("Expanded", comment: "Expanded disclosure accessibility state")
      : NSLocalizedString("Collapsed", comment: "Collapsed disclosure accessibility state")
    accessibilityCustomActions = entityAccessibility.update(
      text: title.attributedText,
      onActivate: context.onEntityTap
    )
    updateShimmerAnimation()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let geometry = RichBlockDisclosureMetricsV2.layout(
      bounds: bounds, isRTL: isRTL, hasActivity: !activityIcon.isHidden
    )
    title.frame = geometry.title
    chevron.frame = geometry.chevron
    activityIcon.frame = geometry.activity ?? .zero
    shimmer.frame = title.frame
    title.layoutIfNeeded()
    shimmer.updateMask(from: title)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateShimmerAnimation()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onToggle = nil
    onEntityTap = nil
    titleBinding.apply(nil, to: title)
    activityIcon.image = nil
    activityIcon.isHidden = true
    shimmer.invalidateMask()
    accessibilityLabel = nil
    accessibilityValue = nil
    accessibilityCustomActions = nil
    entityAccessibility.clear()
    shimmer.setAnimating(false)
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    let point = gesture.location(in: self)
    if let hit = entityHit(at: point),
       isInteractiveEntity(in: hit.text, at: hit.characterIndex),
       onEntityTap?(hit.text, hit.characterIndex) == true
    {
      return
    }
    expanded.toggle()
    updateChevron()
    accessibilityValue = expanded
      ? NSLocalizedString("Expanded", comment: "Expanded disclosure accessibility state")
      : NSLocalizedString("Collapsed", comment: "Collapsed disclosure accessibility state")
    onToggle?(path, expanded)
  }

  override func accessibilityActivate() -> Bool {
    expanded.toggle()
    updateChevron()
    accessibilityValue = expanded
      ? NSLocalizedString("Expanded", comment: "Expanded disclosure accessibility state")
      : NSLocalizedString("Collapsed", comment: "Collapsed disclosure accessibility state")
    onToggle?(path, expanded)
    return true
  }

  @objc private func reduceMotionStatusDidChange() {
    updateShimmerAnimation()
  }

  func entityHit(at point: CGPoint) -> (text: NSAttributedString, characterIndex: Int)? {
    guard let text = title.attributedText, text.length > 0 else { return nil }
    let titlePoint = convert(point, to: title)
    guard title.bounds.contains(titlePoint) else { return nil }
    guard let character = richTextCharacterIndex(at: titlePoint, in: title) else { return nil }
    return (text, character)
  }

  private func isInteractiveEntity(in text: NSAttributedString, at index: Int) -> Bool {
    let attributes = text.attributes(at: index, effectiveRange: nil)
    return attributes[.link] != nil
      || attributes[.mentionUserId] != nil
      || attributes[.mentionGroupId] != nil
      || attributes[.threadLink] != nil
      || attributes[.inlineCode] != nil
      || attributes[.botCommand] != nil
      || attributes[.emailAddress] != nil
      || attributes[.phoneNumber] != nil
  }

  private func updateChevron() {
    let symbol = expanded ? "chevron.down" : (isRTL ? "chevron.left" : "chevron.right")
    chevron.image = UIImage(systemName: symbol)
  }

  private func updateShimmerAnimation() {
    let shouldAnimate = progress
      && window != nil
      && !UIAccessibility.isReduceMotionEnabled
    shimmer.setAnimating(shouldAnimate)
  }
}

private final class RichBlockCodeNodeViewV2: RichBlockRenderableViewV2, RichBlockTextSurfaceProvidingV2 {
  private struct HighlightSignature: Equatable {
    let code: String
    let language: String?
    let font: UIFont
    let primary: UIColor
    let secondary: UIColor
    let accent: UIColor

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.code.utf8.elementsEqual(rhs.code.utf8)
        && lhs.language == rhs.language
        && lhs.font == rhs.font
        && lhs.primary.isEqual(rhs.primary)
        && lhs.secondary.isEqual(rhs.secondary)
        && lhs.accent.isEqual(rhs.accent)
    }
  }

  private static let highlighter = CodeSyntaxHighlighter()

  private let languageLabel = UILabel()
  private let copyButton = UIButton(type: .system)
  private let gutterLabel = UILabel()
  private let scrollView = UIScrollView()
  private let textView = UITextView(usingTextLayoutManager: false)
  var textSurface: UITextView {
    textView
  }

  private var code = ""
  private var language: String?
  private var gutterWidth: CGFloat = 0
  private var codeContentWidth: CGFloat = 0
  private var highlightGeneration: UInt64 = 0
  private var highlightTask: Task<Void, Never>?
  private var highlightSignature: HighlightSignature?
  private var completedHighlightSignature: HighlightSignature?
  private var copyFeedbackTask: Task<Void, Never>?

  init() {
    super.init(.code)
    layer.cornerRadius = 8
    layer.cornerCurve = .continuous
    layer.borderWidth = 0
    clipsToBounds = true
    languageLabel.font = .systemFont(ofSize: 10, weight: .medium)
    gutterLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    gutterLabel.numberOfLines = 0
    gutterLabel.textAlignment = .right
    textView.backgroundColor = .clear
    textView.isEditable = false
    textView.isSelectable = true
    textView.isScrollEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainer.lineBreakMode = .byClipping
    scrollView.alwaysBounceVertical = false
    scrollView.isDirectionalLockEnabled = true
    scrollView.showsHorizontalScrollIndicator = true
    scrollView.showsVerticalScrollIndicator = false
    scrollView.addSubview(textView)
    copyButton.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
    copyButton.setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 13, weight: .medium),
      forImageIn: .normal
    )
    copyButton.imageView?.contentMode = .scaleAspectFit
    copyButton.accessibilityLabel = "Copy code"
    copyButton.addTarget(self, action: #selector(copyCode), for: .touchUpInside)
    addSubview(gutterLabel)
    addSubview(scrollView)
    addSubview(languageLabel)
    addSubview(copyButton)
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .code(codeNode) = node.kind,
          codeNode.range.location >= 0,
          NSMaxRange(codeNode.range) <= context.attributedText.length
    else { return }
    code = context.attributedText.attributedSubstring(from: codeNode.range).string
    language = codeNode.language
    gutterWidth = codeNode.gutterWidth
    codeContentWidth = codeNode.contentWidth
    languageLabel.text = codeNode.language.map(Self.displayLanguage)
    languageLabel.textColor = context.palette.secondary
    copyButton.tintColor = context.palette.secondary
    backgroundColor = context.palette.codeFill
    gutterLabel.font = .monospacedDigitSystemFont(
      ofSize: context.baseFontSize * 0.9,
      weight: .regular
    )
    let font = UIFont.monospacedSystemFont(ofSize: context.baseFontSize * 0.9, weight: .regular)
    let signature = HighlightSignature(
      code: code,
      language: language,
      font: font,
      primary: context.palette.primary,
      secondary: context.palette.secondary,
      accent: context.palette.accent
    )
    if highlightSignature != signature {
      highlightSignature = signature
      completedHighlightSignature = nil
      setCodeText(NSAttributedString(
        string: code,
        attributes: [.font: font, .foregroundColor: context.palette.primary]
      ))
      startHighlight(for: signature)
    } else if highlightTask == nil, completedHighlightSignature != signature {
      startHighlight(for: signature)
    }
    gutterLabel.text = codeNode.gutterWidth > 0
      ? (1 ... codeNode.lineCount).map(String.init).joined(separator: "\n")
      : nil
    gutterLabel.textColor = context.palette.secondary.withAlphaComponent(0.7)
    gutterLabel.isHidden = codeNode.gutterWidth == 0
    setNeedsLayout()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      highlightGeneration &+= 1
      highlightTask?.cancel()
      highlightTask = nil
      copyFeedbackTask?.cancel()
      copyFeedbackTask = nil
    } else if let signature = highlightSignature,
              highlightTask == nil,
              completedHighlightSignature != signature
    {
      startHighlight(for: signature)
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    highlightGeneration &+= 1
    highlightTask?.cancel()
    highlightTask = nil
    highlightSignature = nil
    completedHighlightSignature = nil
    copyFeedbackTask?.cancel()
    copyFeedbackTask = nil
    setCopyFeedback(copied: false)
    code = ""
    language = nil
    gutterWidth = 0
    codeContentWidth = 0
    scrollView.contentOffset = .zero
  }

  override func updateLayout(node _: RichBlockLayoutPlanV2.Node) {
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let hasLanguage = languageLabel.text?.isEmpty == false
    let headerHeight: CGFloat = hasLanguage ? 21 : 0
    let bodyTopInset: CGFloat = hasLanguage ? 3 : 8
    languageLabel.frame = CGRect(x: 8, y: 5, width: max(0, bounds.width - 44), height: 14)
    copyButton.frame = CGRect(x: bounds.width - 26, y: hasLanguage ? 3 : 4, width: 18, height: 18)
    let gutterWidth = gutterLabel.isHidden ? CGFloat.zero : gutterWidth
    gutterLabel.frame = CGRect(
      x: 8,
      y: headerHeight + bodyTopInset,
      width: gutterWidth,
      height: bounds.height - headerHeight - bodyTopInset - 9
    )
    let gutterGap: CGFloat = gutterWidth > 0 ? 15 : 0
    let viewportFrame = CGRect(
      x: 8 + gutterWidth + gutterGap,
      y: headerHeight + bodyTopInset,
      width: max(0, bounds.width - 16 - gutterWidth - gutterGap),
      height: max(0, bounds.height - headerHeight - bodyTopInset - 9)
    )
    scrollView.frame = viewportFrame
    let textWidth = max(viewportFrame.width, codeContentWidth)
    textView.frame = CGRect(origin: .zero, size: CGSize(width: textWidth, height: viewportFrame.height))
    scrollView.contentSize = textView.bounds.size
    scrollView.alwaysBounceHorizontal = textWidth > viewportFrame.width + 1
    bringSubviewToFront(languageLabel)
    bringSubviewToFront(copyButton)
  }

  @objc private func copyCode() {
    UIPasteboard.general.string = code
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    copyFeedbackTask?.cancel()
    setCopyFeedback(copied: true)
    copyFeedbackTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1.2))
      guard !Task.isCancelled else { return }
      self?.setCopyFeedback(copied: false)
    }
  }

  private func setCopyFeedback(copied: Bool) {
    let symbol = copied ? "checkmark" : "doc.on.doc"
    copyButton.setImage(UIImage(systemName: symbol), for: .normal)
    copyButton.accessibilityLabel = copied ? "Copied" : "Copy code"
  }

  private static func displayLanguage(_ language: String) -> String {
    let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
    return switch trimmed.lowercased() {
      case "bash", "sh", "shell", "zsh": "Shell"
      case "c": "C"
      case "c#", "csharp", "cs": "C#"
      case "c++", "cpp": "C++"
      case "css": "CSS"
      case "go", "golang": "Go"
      case "html": "HTML"
      case "javascript", "js": "JavaScript"
      case "json", "jsonc": "JSON"
      case "jsx": "JSX"
      case "kotlin": "Kotlin"
      case "objective-c", "objc": "Objective-C"
      case "python", "py", "python3": "Python"
      case "ruby", "rb": "Ruby"
      case "rust", "rs": "Rust"
      case "sql", "postgres", "postgresql": "SQL"
      case "swift": "Swift"
      case "tsx": "TSX"
      case "typescript", "ts": "TypeScript"
      case "xml": "XML"
      case "yaml", "yml": "YAML"
      default: trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
  }

  private func startHighlight(for signature: HighlightSignature) {
    highlightGeneration &+= 1
    let generation = highlightGeneration
    highlightTask?.cancel()
    guard CodeSyntaxHighlighter.supports(language: signature.language),
          !signature.code.isEmpty
    else {
      highlightTask = nil
      completedHighlightSignature = signature
      return
    }
    guard window != nil else {
      highlightTask = nil
      return
    }

    let code = signature.code
    let language = signature.language
    highlightTask = Task { @MainActor [weak self] in
      let tokens = (try? await Self.highlighter.tokens(for: code, language: language)) ?? []
      guard !Task.isCancelled,
            let self,
            highlightGeneration == generation,
            self.highlightSignature == signature,
            self.code.utf8.elementsEqual(code.utf8)
      else { return }

      let highlighted = NSMutableAttributedString(
        string: code,
        attributes: [.font: signature.font, .foregroundColor: signature.primary]
      )
      for token in tokens where token.range.location >= 0
        && token.range.location <= highlighted.length
        && token.range.length <= highlighted.length - token.range.location
      {
        highlighted.addAttribute(
          .foregroundColor,
          value: Self.tokenColor(
            token.kind,
            primary: signature.primary,
            secondary: signature.secondary,
            accent: signature.accent
          ),
          range: token.range
        )
      }
      setCodeText(highlighted)
      completedHighlightSignature = signature
      highlightTask = nil
    }
  }

  private func setCodeText(_ text: NSAttributedString) {
    let preservesSelection = textView.attributedText?.string.utf8.elementsEqual(text.string.utf8) == true
    let selection = preservesSelection ? textView.selectedRange : nil
    textView.attributedText = text
    if let selection,
       selection.location >= 0, selection.length >= 0,
       selection.location <= text.length,
       selection.length <= text.length - selection.location {
      textView.selectedRange = selection
    }
  }

  private static func tokenColor(
    _ kind: CodeTokenKind,
    primary: UIColor,
    secondary: UIColor,
    accent: UIColor
  ) -> UIColor {
    switch kind {
      case .keyword, .number, .constant:
        accent
      case .type:
        accent
      case .function, .property, .operatorSymbol:
        primary
      case .string:
        secondary
      case .comment:
        secondary.withAlphaComponent(0.72)
      case .punctuation:
        secondary
    }
  }
}

@MainActor
private final class RichBlockImageNodeViewV2: RichBlockRenderableViewV2 {
  private let photoView = PlatformPhotoView()
  private let unavailable = UIImageView(image: UIImage(systemName: "photo"))
  private var currentImage: BlockImageOccurrence?
  private var onImageTap: ((RichBlockImageGallerySelectionV2) -> Void)?

  init() {
    super.init(.image)
    layer.cornerRadius = 7
    clipsToBounds = true
    photoView.translatesAutoresizingMaskIntoConstraints = true
    photoView.photoContentMode = .aspectFill
    photoView.showsTinyThumbnailBackground = true
    unavailable.contentMode = .scaleAspectFit
    addSubview(photoView)
    addSubview(unavailable)
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openImage)))
    isAccessibilityElement = true
  }

  func apply(
    image: RichBlockLayoutPlanV2.ImageNode,
    palette: RichBlockPaletteV2,
    message: InlineKit.Message,
    onImageTap: @escaping (RichBlockImageGallerySelectionV2) -> Void
  ) {
    backgroundColor = palette.placeholder
    unavailable.tintColor = palette.secondary
    accessibilityValue = nil
    switch image.state {
      case .pending:
        currentImage = nil
        self.onImageTap = nil
        photoView.setPhoto(nil)
        unavailable.isHidden = true
        accessibilityLabel = image.alt ?? "Image"
        accessibilityValue = NSLocalizedString("Loading", comment: "Image accessibility loading state")
        accessibilityTraits = [.image]
      case let .ready(photo):
        guard photo.hasDisplayablePreview else {
          currentImage = nil
          self.onImageTap = nil
          photoView.setPhoto(nil)
          unavailable.isHidden = false
          accessibilityLabel = image.alt ?? "Image"
          accessibilityValue = NSLocalizedString("Unavailable", comment: "Image accessibility unavailable state")
          accessibilityTraits = [.image]
          return
        }
        currentImage = BlockImageOccurrence(path: image.path, photo: photo)
        self.onImageTap = onImageTap
        photoView.setPhoto(photo, reloadMessageOnFinish: message)
        unavailable.isHidden = true
        accessibilityLabel = image.alt ?? "Image"
        accessibilityTraits = [.image, .button]
      case .unavailable:
        currentImage = nil
        self.onImageTap = nil
        photoView.setPhoto(nil)
        unavailable.isHidden = false
        accessibilityLabel = image.alt ?? "Image"
        accessibilityValue = NSLocalizedString("Unavailable", comment: "Image accessibility unavailable state")
        accessibilityTraits = [.image]
    }
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .image(image) = node.kind else { return }
    apply(
      image: image,
      palette: context.palette,
      message: context.message,
      onImageTap: context.onImageTap
    )
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    currentImage = nil
    onImageTap = nil
    // The viewer may still hold a weak reference to a suppressed source while
    // this node is pooled. That visibility must not leak into the next image.
    photoView.alpha = 1
    photoView.setPhoto(nil)
    accessibilityLabel = nil
    accessibilityValue = nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    photoView.frame = bounds
    unavailable.frame = CGRect(x: (bounds.width - 24) / 2, y: (bounds.height - 24) / 2, width: 24, height: 24)
  }

  @objc private func openImage() {
    guard let currentImage else { return }
    onImageTap?(.init(
      image: currentImage,
      sourceView: photoView,
      sourceImage: photoView.displayedImage
    ))
  }

  override func accessibilityActivate() -> Bool {
    guard currentImage != nil else { return false }
    openImage()
    return true
  }

  func sourceView(forPhotoID photoID: Int64) -> UIView? {
    currentImage?.photo.id == photoID ? photoView : nil
  }
}

private final class RichBlockAlbumNodeViewV2: RichBlockRenderableViewV2 {
  private let scrollView = UIScrollView()
  private var itemViews: [RichBlockImageNodeViewV2] = []
  private var items: [RichBlockLayoutPlanV2.ImageNode] = []

  init() {
    super.init(.album)
    scrollView.alwaysBounceHorizontal = true
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.isDirectionalLockEnabled = true
    addSubview(scrollView)
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .album(album) = node.kind else { return }
    items = album.items
    // The parent reconciler only retains albums with the same ordered photo
    // prefix. Index reuse here survives a change to the album's structural path.
    while itemViews.count > items.count {
      let removed = itemViews.removeLast()
      removed.prepareForReuse()
      removed.removeFromSuperview()
    }
    for (index, item) in items.enumerated() {
      if index == itemViews.count {
        let view = RichBlockImageNodeViewV2()
        itemViews.append(view)
        scrollView.addSubview(view)
      }
      let view = itemViews[index]
      view.apply(
        image: item,
        palette: context.palette,
        message: context.message,
        onImageTap: context.onImageTap
      )
      view.frame = item.frame
    }
    scrollView.contentSize = CGSize(width: album.contentWidth, height: bounds.height)
    scrollView.alwaysBounceHorizontal = album.contentWidth > bounds.width + 1
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    scrollView.frame = bounds
    scrollView.contentSize.height = bounds.height
    scrollView.alwaysBounceHorizontal = scrollView.contentSize.width > bounds.width + 1
    for (item, view) in zip(items, itemViews) {
      view.frame = item.frame
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    for view in itemViews {
      view.prepareForReuse()
      view.removeFromSuperview()
    }
    itemViews.removeAll(keepingCapacity: true)
    items.removeAll(keepingCapacity: true)
    scrollView.contentSize = .zero
    scrollView.setContentOffset(.zero, animated: false)
  }

  func sourceView(forImagePath path: BlockContentPath, photoID: Int64) -> UIView? {
    guard let index = items.firstIndex(where: { $0.path == path }), itemViews.indices.contains(index) else { return nil }
    return itemViews[index].sourceView(forPhotoID: photoID)
  }
}

private final class RichBlockQuoteNodeViewV2: RichBlockRenderableViewV2 {
  private let rail = UIView()
  private var isRTL = false

  init() {
    super.init(.quote)
    isUserInteractionEnabled = false
    addSubview(rail)
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .quote(quote) = node.kind else { return }
    isRTL = quote.isRTL
    backgroundColor = context.palette.subtleFill
    rail.backgroundColor = context.palette.accent
    layer.cornerRadius = 7
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    rail.frame = CGRect(x: isRTL ? bounds.width - 3 : 0, y: 0, width: 3, height: bounds.height)
    rail.layer.cornerRadius = 1.5
  }
}

private final class RichBlockSeparatorNodeViewV2: RichBlockRenderableViewV2 {
  init() {
    super.init(.separator)
    isUserInteractionEnabled = false
  }

  override func apply(node _: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    backgroundColor = context.palette.separator
  }
}

private final class RichBlockTableCellViewV2: UIView, RichBlockEntityHittableV2, UIGestureRecognizerDelegate {
  private let textView = CodeBlockTextView(usingTextLayoutManager: false)
  private var textBinding = MessageTextBindingV2()
  private let entityAccessibility = RichBlockEntityAccessibilityActionsV2()
  private var onEntityTap: ((NSAttributedString, Int) -> Bool)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    textView.backgroundColor = .clear
    textView.isEditable = false
    textView.isSelectable = false
    textView.useManualMessageLayout()
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.isUserInteractionEnabled = true
    addSubview(textView)
    let entityTap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    entityTap.delegate = self
    textView.addGestureRecognizer(entityTap)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(
    text: NSAttributedString?,
    alignment: NSTextAlignment,
    isHeader: Bool,
    palette: RichBlockPaletteV2,
    onEntityTap: @escaping (NSAttributedString, Int) -> Bool
  ) {
    if textView.bounds.width == 0, bounds.width > 20 {
      textView.frame = bounds.insetBy(dx: 10, dy: 7)
    }
    textBinding.apply(text, to: textView)
    if textView.textAlignment != alignment { textView.textAlignment = alignment }
    self.onEntityTap = onEntityTap
    backgroundColor = .clear
    layer.borderWidth = 0
    isAccessibilityElement = true
    accessibilityLabel = text.flatMap { RichTextMath.sourceText($0) } ?? text?.string
    accessibilityTraits = isHeader ? [.header] : [.staticText]
    accessibilityCustomActions = entityAccessibility.update(
      text: textView.attributedText,
      onActivate: onEntityTap
    )
  }

  func prepareForReuse() {
    textBinding.apply(nil, to: textView)
    onEntityTap = nil
    accessibilityLabel = nil
    accessibilityValue = nil
    accessibilityCustomActions = nil
    entityAccessibility.clear()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let frame = bounds.insetBy(dx: 10, dy: 7)
    if textView.frame != frame { textView.frame = frame }
  }

  func entityHit(at point: CGPoint) -> (text: NSAttributedString, characterIndex: Int)? {
    guard let attributedText = textView.attributedText, attributedText.length > 0 else { return nil }
    let location = convert(point, to: textView)
    guard let character = richTextCharacterIndex(at: location, in: textView) else { return nil }
    return (attributedText, character)
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let hit = entityHit(at: gestureRecognizer.location(in: self)) else { return false }
    return richTextHasInteractiveEntity(at: hit.characterIndex, in: hit.text)
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard let hit = entityHit(at: gesture.location(in: self)) else { return }
    _ = onEntityTap?(hit.text, hit.characterIndex)
  }
}

private final class RichBlockTableCanvasViewV2: UIView {
  private var rowEdges: [CGFloat] = []
  private var separatorColor = UIColor.separator

  func apply(cells: [RichBlockLayoutPlanV2.TableNode.Cell], separatorColor: UIColor) {
    self.separatorColor = separatorColor
    rowEdges = Array(Set(cells.map(\.frame.maxY))).sorted()
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    super.draw(rect)
    guard !rowEdges.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
    context.saveGState()
    context.setStrokeColor(separatorColor.cgColor)
    context.setLineWidth(1 / max(window?.screen.scale ?? UIScreen.main.scale, 1))
    for edge in rowEdges where edge < bounds.height - 0.5 {
      let y = floor(edge) + 0.5 / max(window?.screen.scale ?? UIScreen.main.scale, 1)
      context.move(to: CGPoint(x: 0, y: y))
      context.addLine(to: CGPoint(x: bounds.width, y: y))
    }
    context.strokePath()
    context.restoreGState()
  }
}

private final class RichBlockTableNodeViewV2: RichBlockRenderableViewV2 {
  private let scrollView = UIScrollView()
  private let canvas = RichBlockTableCanvasViewV2()
  private var cellViews: [RichBlockTableCellViewV2] = []
  private var table: RichBlockLayoutPlanV2.TableNode?
  private var didSetInitialOffset = false
  private var lastIsRTL = false

  init() {
    super.init(.table)
    layer.cornerRadius = 7
    layer.cornerCurve = .continuous
    layer.borderWidth = 0
    clipsToBounds = true
    scrollView.backgroundColor = .clear
    scrollView.alwaysBounceHorizontal = true
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.addSubview(canvas)
    addSubview(scrollView)
  }

  override func apply(node: RichBlockLayoutPlanV2.Node, context: RichBlockRenderContextV2) {
    guard case let .table(table) = node.kind else { return }
    if lastIsRTL != table.isRTL {
      didSetInitialOffset = false
      lastIsRTL = table.isRTL
    }
    self.table = table
    backgroundColor = .clear
    canvas.backgroundColor = .clear
    while cellViews.count < table.cells.count {
      let cellView = RichBlockTableCellViewV2()
      canvas.addSubview(cellView)
      cellViews.append(cellView)
    }
    // A shrinking table must release its old text stacks. Retaining the peak
    // size at every block path defeats the planner's total cell budget.
    while cellViews.count > table.cells.count {
      let cellView = cellViews.removeLast()
      cellView.prepareForReuse()
      cellView.removeFromSuperview()
    }
    let firstRowY = table.cells.first?.frame.minY
    let columnCount = max(1, table.cells.prefix { $0.frame.minY == firstRowY }.count)
    for (index, cellView) in cellViews.enumerated() {
      let cell = table.cells[index]
      if cellView.frame != cell.frame { cellView.frame = cell.frame }
      let text = RichBlockLayoutPlannerV2.styledTableText(
        from: context.attributedText,
        range: cell.range,
        baseFontSize: context.baseFontSize,
        isRTL: table.isRTL,
        alignment: cell.alignment,
        isHeader: cell.isHeader,
        math: context.math
      )?.mutableCopy() as? NSMutableAttributedString
      if let text {
        text.addAttribute(
          .foregroundColor,
          value: context.palette.primary,
          range: NSRange(location: 0, length: text.length)
        )
      }
      let alignment: NSTextAlignment = switch cell.alignment {
        case .leading: table.isRTL ? .right : .left
        case .center: .center
        case .trailing: table.isRTL ? .left : .right
      }
      cellView.apply(
        text: text,
        alignment: alignment,
        isHeader: cell.isHeader,
        palette: context.palette,
        onEntityTap: context.onEntityTap
      )
      let position = String(localized: "Row \(index / columnCount + 1), column \(index % columnCount + 1)")
      if !cell.isHeader, table.cells[index % columnCount].isHeader,
         let heading = cellViews[index % columnCount].accessibilityLabel, !heading.isEmpty {
        cellView.accessibilityValue = "\(heading), \(position)"
      } else {
        cellView.accessibilityValue = position
      }
    }
    canvas.apply(cells: table.cells, separatorColor: context.palette.separator)
    accessibilityElements = cellViews.prefix(table.cells.count).map { $0 as Any }
    canvas.frame = CGRect(x: 0, y: 0, width: table.contentWidth, height: bounds.height)
    scrollView.contentSize = canvas.bounds.size
    scrollView.alwaysBounceHorizontal = table.contentWidth > bounds.width + 1
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    scrollView.frame = bounds
    guard let table else { return }
    canvas.frame = CGRect(x: 0, y: 0, width: table.contentWidth, height: bounds.height)
    scrollView.contentSize = canvas.bounds.size
    scrollView.alwaysBounceHorizontal = table.contentWidth > bounds.width + 1
    if !didSetInitialOffset, bounds.width > 0 {
      scrollView.contentOffset.x = table.isRTL
        ? max(0, table.contentWidth - bounds.width)
        : 0
      didSetInitialOffset = true
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    table = nil
    for cell in cellViews {
      cell.prepareForReuse()
      cell.removeFromSuperview()
    }
    cellViews.removeAll(keepingCapacity: true)
    didSetInitialOffset = false
    lastIsRTL = false
    scrollView.contentOffset = .zero
    accessibilityElements = nil
  }
}

final class RichBlockContentViewV2: UIView {
  private struct DisappearingSnapshot {
    let generation: UInt
    let view: UIView
  }

  var onDisclosureToggle: ((BlockContentPath, Bool) -> Void)?
  var onEntityTap: ((NSAttributedString, Int) -> Bool)?
  var onImageTap: ((RichBlockImageGallerySelectionV2) -> Void)?
  var onMathPrepared: (() -> Void)?

  func mathSource(at point: CGPoint) -> String? {
    guard bounds.contains(point), let currentPlan, let source = previousSource else { return nil }
    for node in currentPlan.nodes {
      guard case let .math(math) = node.kind,
            let view = nodeViews[node.path], !view.isHidden, view.alpha > 0.01,
            view.bounds.contains(convert(point, to: view)),
            let range = Range(math.range, in: source)
      else { continue }
      let value = String(source[range])
      if !value.isEmpty { return value }
    }
    return nil
  }

  private var nodeViews: [BlockContentPath: RichBlockRenderableViewV2] = [:]
  private var reusePool: [RichBlockRenderKindV2: [RichBlockRenderableViewV2]] = [:]
  private var previousSource: String?
  private var messageIdentity: BlockContentMessageIdentity?
  private var previousContent: InlineProtocol.BlockContent?
  private var currentPlan: RichBlockLayoutPlanV2?
  private var mathSnapshot: RichTextMath.Snapshot?
  private var mathLayoutSignature: Int = 0
  private var mathPreparationTask: Task<Void, Never>?
  private var mathGeneration: UInt64 = 0
  private var mathPrepared = false
  private var disappearingSnapshots: [DisappearingSnapshot] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(
    plan: RichBlockLayoutPlanV2,
    content: InlineProtocol.BlockContent,
    attributedText: NSAttributedString,
    baseFontSize: CGFloat,
    palette: RichBlockPaletteV2,
    message: InlineKit.Message,
    mathPreparationEnabled: Bool = true,
    deferLayout: Bool,
    transitionGeneration: UInt
  ) {
    // Cache readiness may change after sizing. Bind only the projection that
    // produced this geometry, then commit readiness through onMathPrepared.
    guard let math = plan.mathSnapshot, math.signature == plan.mathSignature else {
      assertionFailure("Rich block geometry must be prepared before binding")
      return
    }
    let identity = BlockContentMessageIdentity(message: message)
    if messageIdentity != identity {
      prepareForReuse()
      messageIdentity = identity
    }
    let reconciliation = BlockContentReconciler.reconcile(
      previous: previousContent, current: content,
      previousSource: previousSource, currentSource: message.text ?? ""
    )
    previousContent = content
    previousSource = message.text

    // Resolve all moves from the old dictionary, including swaps and occupied
    // destinations, before putting unmatched views into the reuse pool.
    var remainingViews = nodeViews
    nodeViews.removeAll(keepingCapacity: true)
    for node in plan.nodes {
      guard let oldPath = reconciliation.previousPathByCurrentPath[node.path],
            let view = remainingViews[oldPath], view.reuseKind == node.reuseKind
      else { continue }
      nodeViews[node.path] = remainingViews.removeValue(forKey: oldPath)
    }
    for removed in remainingViews.values {
      if deferLayout { retainRemovalSnapshot(of: removed, generation: transitionGeneration) }
      enqueue(removed)
    }

    let context = RichBlockRenderContextV2(
      math: math,
      attributedText: attributedText,
      baseFontSize: baseFontSize,
      palette: palette,
      message: message,
      onDisclosureToggle: { [weak self] path, expanded in
        self?.onDisclosureToggle?(path, expanded)
      },
      onEntityTap: { [weak self] text, character in
        self?.onEntityTap?(text, character) ?? false
      },
      onImageTap: { [weak self] selection in
        self?.onImageTap?(selection)
      }
    )

    for node in plan.nodes {
      let view: RichBlockRenderableViewV2
      let animatesInsertion: Bool
      if let existing = nodeViews[node.path],
         existing.reuseKind == node.reuseKind
      {
        view = existing
        animatesInsertion = false
      } else {
        view = dequeue(kind: node.reuseKind)
        nodeViews[node.path] = view
        insertNodeView(view, for: node)
        animatesInsertion = true
      }
      if animatesInsertion {
        view.frame = node.frame
        if deferLayout {
          view.alpha = 0
          view.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        }
      }
      view.apply(node: node, context: context)
      if !deferLayout {
        if view.frame != node.frame { view.frame = node.frame }
        view.alpha = 1
        view.transform = .identity
      }
    }
    currentPlan = plan
    updateAccessibilityOrder()
    updateMathPreparation(mathPreparationEnabled ? math : nil, layoutSignature: plan.mathSignature)
  }

  func applyLayout(_ plan: RichBlockLayoutPlanV2) {
    currentPlan = plan
    for node in plan.nodes {
      guard let view = nodeViews[node.path], view.reuseKind == node.reuseKind else { continue }
      view.updateLayout(node: node)
      if view.frame != node.frame { view.frame = node.frame }
      view.alpha = 1
      view.transform = .identity
    }
    for snapshot in disappearingSnapshots {
      snapshot.view.alpha = 0
      snapshot.view.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
    }
    updateAccessibilityOrder()
  }

  func restorePresentationGeometry() {
    for view in nodeViews.values {
      guard let presentation = view.layer.presentation() else { continue }
      view.bounds = presentation.bounds
      view.center = presentation.position
      view.transform = CATransform3DGetAffineTransform(presentation.transform)
      view.alpha = CGFloat(presentation.opacity)
    }
    for snapshot in disappearingSnapshots {
      guard let presentation = snapshot.view.layer.presentation() else { continue }
      snapshot.view.bounds = presentation.bounds
      snapshot.view.center = presentation.position
      snapshot.view.transform = CATransform3DGetAffineTransform(presentation.transform)
      snapshot.view.alpha = CGFloat(presentation.opacity)
    }
  }

  var hasPendingTransitionSnapshots: Bool {
    !disappearingSnapshots.isEmpty
  }

  func finishTransition(generation: UInt) {
    for snapshot in disappearingSnapshots where snapshot.generation == generation {
      snapshot.view.removeFromSuperview()
    }
    disappearingSnapshots.removeAll { $0.generation == generation }
  }

  func cancelTransitions() {
    layer.removeAllAnimations()
    for view in nodeViews.values {
      view.layer.removeAllAnimations()
      view.alpha = 1
      view.transform = .identity
    }
    for snapshot in disappearingSnapshots {
      snapshot.view.removeFromSuperview()
    }
    disappearingSnapshots.removeAll(keepingCapacity: true)
  }

  func prepareForReuse() {
    cancelMathPreparation()
    mathSnapshot = nil
    for view in nodeViews.values {
      enqueue(view)
    }
    nodeViews.removeAll(keepingCapacity: true)
    for snapshot in disappearingSnapshots {
      snapshot.view.removeFromSuperview()
    }
    disappearingSnapshots.removeAll(keepingCapacity: true)
    previousContent = nil
    previousSource = nil
    messageIdentity = nil
    currentPlan = nil
    accessibilityElements = nil
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil { cancelMathPreparation() } else { startMathPreparation() }
  }

  func entityHit(at point: CGPoint) -> (text: NSAttributedString, characterIndex: Int)? {
    guard bounds.contains(point), var view = hitTest(point, with: nil) else { return nil }
    while view !== self {
      if let entityView = view as? RichBlockEntityHittableV2 {
        return entityView.entityHit(at: convert(point, to: view))
      }
      guard let parent = view.superview else { return nil }
      view = parent
    }
    return nil
  }

  private func updateMathPreparation(_ snapshot: RichTextMath.Snapshot?, layoutSignature: Int) {
    if mathSnapshot?.requests != snapshot?.requests || mathSnapshot?.signature != snapshot?.signature
      || mathLayoutSignature != layoutSignature {
      cancelMathPreparation()
    }
    mathSnapshot = snapshot
    mathLayoutSignature = layoutSignature
    startMathPreparation()
  }

  private func cancelMathPreparation() {
    mathGeneration &+= 1
    mathPreparationTask?.cancel()
    mathPreparationTask = nil
    mathPrepared = false
  }

  private func startMathPreparation() {
    guard window != nil, !mathPrepared, mathPreparationTask == nil,
          let snapshot = mathSnapshot?.refreshed(), !snapshot.requests.isEmpty else { return }
    guard snapshot.hasPending || snapshot.signature != mathLayoutSignature
      || snapshot.signature != mathSnapshot?.signature else {
      mathPrepared = true
      return
    }
    let generation = mathGeneration
    mathPreparationTask = Task { @MainActor [weak self] in
      _ = await RichTextMath.prepare(snapshot.requests)
      guard !Task.isCancelled, let self, self.window != nil,
            self.mathGeneration == generation else { return }
      self.mathPreparationTask = nil
      self.mathPrepared = true
      // Cached success alone is not a change. In particular, rebinding a ready
      // row must never trigger a notification/reload/rebind loop.
      let ready = snapshot.refreshed()
      guard ready.signature != self.mathLayoutSignature || ready.signature != self.mathSnapshot?.signature else { return }
      self.onMathPrepared?()
    }
  }

  deinit { mathPreparationTask?.cancel() }

  var primaryTextSurface: UITextView? {
    guard let currentPlan else { return nil }
    for node in currentPlan.nodes {
      if let provider = nodeViews[node.path] as? RichBlockTextSurfaceProvidingV2 {
        return provider.textSurface
      }
    }
    return nil
  }

  var readyImageOccurrences: [BlockImageOccurrence] {
    currentPlan?.nodes.flatMap { node -> [BlockImageOccurrence] in
      switch node.kind {
      case let .image(image):
        guard case let .ready(photo) = image.state, photo.hasDisplayablePreview else { return [] }
        return [.init(path: image.path, photo: photo)]
      case let .album(album):
        return album.items.compactMap { item in
          guard case let .ready(photo) = item.state, photo.hasDisplayablePreview else { return nil }
          return .init(path: item.path, photo: photo)
        }
      default: return []
      }
    } ?? []
  }

  func sourceView(forImagePath path: BlockContentPath, photoID: Int64) -> UIView? {
    let source: UIView?
    if let image = nodeViews[path] as? RichBlockImageNodeViewV2 {
      source = image.sourceView(forPhotoID: photoID)
    } else if case .albumImage? = path.components.last {
      let parent = BlockContentPath(Array(path.components.dropLast()))
      source = (nodeViews[parent] as? RichBlockAlbumNodeViewV2)?.sourceView(forImagePath: path, photoID: photoID)
    } else {
      source = nil
    }
    guard let source, isVisibleImageSource(source) else { return nil }
    return source
  }

  private func isVisibleImageSource(_ source: UIView) -> Bool {
    guard source.window != nil, !source.isHidden,
          source.bounds.width > 0, source.bounds.height > 0
    else { return false }
    var current = source
    var visibleRect = source.bounds
    while let parent = current.superview {
      visibleRect = current.convert(visibleRect, to: parent)
      guard !parent.isHidden else { return false }
      if parent.clipsToBounds {
        visibleRect = visibleRect.intersection(parent.bounds)
        guard !visibleRect.isNull, visibleRect.width > 0, visibleRect.height > 0 else { return false }
      }
      current = parent
    }
    return true
  }

  private func insertNodeView(_ view: RichBlockRenderableViewV2, for node: RichBlockLayoutPlanV2.Node) {
    if node.reuseKind == .quote {
      insertSubview(view, at: 0)
    } else {
      addSubview(view)
    }
  }

  private func updateAccessibilityOrder() {
    guard let currentPlan else {
      accessibilityElements = nil
      return
    }
    func accessibleDescendants(of view: UIView) -> [Any] {
      guard !view.isHidden, view.alpha > 0.01 else { return [] }
      if view.isAccessibilityElement { return [view] }
      if let explicit = view.accessibilityElements, !explicit.isEmpty { return explicit }
      return view.subviews.flatMap(accessibleDescendants(of:))
    }
    accessibilityElements = currentPlan.nodes.flatMap { node -> [Any] in
      guard let view = nodeViews[node.path] else { return [] }
      return accessibleDescendants(of: view)
    }
  }

  private func retainRemovalSnapshot(of view: UIView, generation: UInt) {
    guard let snapshot = view.snapshotView(afterScreenUpdates: false),
          view.frame.width > 0,
          view.frame.height > 0
    else { return }
    snapshot.frame = view.layer.presentation()?.frame ?? view.frame
    snapshot.isUserInteractionEnabled = false
    addSubview(snapshot)
    disappearingSnapshots.append(.init(generation: generation, view: snapshot))
  }

  private func dequeue(kind: RichBlockRenderKindV2) -> RichBlockRenderableViewV2 {
    if var views = reusePool[kind], let view = views.popLast() {
      reusePool[kind] = views
      return view
    }
    return switch kind {
      case .math: RichBlockMathNodeViewV2()
      case .text: RichBlockTextNodeViewV2()
      case .listMarker: RichBlockListMarkerNodeViewV2()
      case .disclosure: RichBlockDisclosureNodeViewV2()
      case .code: RichBlockCodeNodeViewV2()
      case .separator: RichBlockSeparatorNodeViewV2()
      case .image: RichBlockImageNodeViewV2()
      case .album: RichBlockAlbumNodeViewV2()
      case .quote: RichBlockQuoteNodeViewV2()
      case .table: RichBlockTableNodeViewV2()
    }
  }

  private func enqueue(_ view: RichBlockRenderableViewV2) {
    view.prepareForReuse()
    view.removeFromSuperview()
    var views = reusePool[view.reuseKind, default: []]
    if views.count < 16 { views.append(view) }
    reusePool[view.reuseKind] = views
  }
}
