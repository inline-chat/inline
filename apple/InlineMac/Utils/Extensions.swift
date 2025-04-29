import AppKit

public extension NSAttributedString {
  func sizeFittingWidth(_ w: CGFloat) -> CGSize {
    let textStorage = NSTextStorage(attributedString: self)
    let size = CGSize(width: w, height: CGFloat.greatestFiniteMagnitude)
    let boundingRect = CGRect(origin: .zero, size: size)

    let textContainer = NSTextContainer(size: size)
    //        textContainer.lineFragmentPadding = 0

    let layoutManager = NSLayoutManager()
    layoutManager.addTextContainer(textContainer)

    textStorage.addLayoutManager(layoutManager)

    layoutManager.glyphRange(forBoundingRect: boundingRect, in: textContainer)

    let rect = layoutManager.usedRect(for: textContainer)

    return rect.size
  }

  func containsAttribute(attributeName: NSAttributedString.Key) -> Any? {
    let range = NSRange(location: 0, length: length)

    var containsAttribute: Any?

    enumerateAttribute(attributeName, in: range, options: []) { value, _, _ in
      if value != nil {
        containsAttribute = value
      }
    }

    return containsAttribute
  }

  func CTSize(_ width: CGFloat, framesetter: CTFramesetter?) -> (CTFramesetter, NSSize) {
    var fs = framesetter

    if fs == nil {
      fs = CTFramesetterCreateWithAttributedString(self)
    }

    var textSize: CGSize = CTFramesetterSuggestFrameSizeWithConstraints(
      fs!,
      CFRangeMake(0, length),
      nil,
      NSMakeSize(width, CGFloat.greatestFiniteMagnitude),
      nil
    )

    textSize.width = ceil(textSize.width)
    textSize.height = ceil(textSize.height)

    return (fs!, textSize)
  }

  var trimNewLinesToSpace: NSAttributedString {
    replaceNewlinesWithSpaces(in: self)
  }

  func replaceNewlinesWithSpaces(in attributedString: NSAttributedString) -> NSAttributedString {
    // Create a mutable copy of the input attributed string
    let mutableAttributedString = NSMutableAttributedString(attributedString: attributedString)

    // Replace all occurrences of newline characters with space characters
    let range = NSRange(location: 0, length: mutableAttributedString.length)
    let newlineRegex = try! NSRegularExpression(pattern: "\\n")
    newlineRegex.replaceMatches(in: mutableAttributedString.mutableString, options: [], range: range, withTemplate: " ")

    // Return the modified attributed string
    return mutableAttributedString
  }

  var range: NSRange {
    NSMakeRange(0, length)
  }

  func trimRange(_ range: NSRange) -> NSRange {
    let loc: Int = min(range.location, length)
    let length: Int = min(range.length, length - loc)
    return NSMakeRange(loc, length)
  }

  convenience init(
    string: String,
    font: NSFont? = nil,
    textColor: NSColor = NSColor.black,
    paragraphAlignment: NSTextAlignment? = nil
  ) {
    var attributes: [NSAttributedString.Key: AnyObject] = [:]
    if let font {
      attributes[.font] = font
    }
    attributes[.foregroundColor] = textColor
    if let paragraphAlignment {
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.alignment = paragraphAlignment
      attributes[.paragraphStyle] = paragraphStyle
    }
    self.init(string: string, attributes: attributes)
  }
}

public extension NSView {
  /// Capture a NSView as a NSImage
  var snapshot: NSImage {
    guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage() }
    cacheDisplay(in: bounds, to: rep)
    let image = NSImage(size: bounds.size)
    image.addRepresentation(rep)
    return image
  }

  var subviewsSize: NSSize {
    var size: NSSize = NSZeroSize
    for subview in subviews {
      size.width += subview.frame.width
      size.height += subview.frame.height
    }
    return size
  }

  var subviewsWidthSize: NSSize {
    var size: NSSize = NSZeroSize
    for subview in subviews {
      size.width += subview.frame.width
      size.height = max(subview.frame.height, size.height)
    }
    return size
  }

  func removeAllSubviews() {
    var filtered = subviews
    while filtered.count > 0 {
      filtered.removeFirst().removeFromSuperview()
    }
  }

  func setFrameSize(_ width: CGFloat, _ height: CGFloat) {
    setFrameSize(NSMakeSize(width, height))
  }

  func setFrameOrigin(_ x: CGFloat, _ y: CGFloat) {
    setFrameOrigin(NSMakePoint(x, y))
  }
}

public extension NSTableView.AnimationOptions {
  static var none: NSTableView.AnimationOptions {
    NSTableView.AnimationOptions(rawValue: 0)
  }
}

public extension NSScrollView {
  var contentOffset: NSPoint {
    contentView.bounds.origin
  }
}

public extension NSAppearance {
  var isDarkMode: Bool {
    if #available(macOS 10.14, *) {
      return name == .darkAqua ||
      name == .vibrantDark ||
      name == .accessibilityHighContrastDarkAqua ||
      name == .accessibilityHighContrastVibrantDark
    }
    return false
  }
}

public extension NSRange {
  var min: Int {
    location
  }

  var max: Int {
    location + length
  }

  var isEmpty: Bool {
    length == 0
  }

  func indexIn(_ index: Int) -> Bool {
    NSLocationInRange(index, self)
  }

  init(string: String, range: Range<String.Index>) {
    let utf8 = string.utf16

    let location = utf8.distance(from: utf8.startIndex, to: range.lowerBound)
    let length = utf8.distance(from: range.lowerBound, to: range.upperBound)

    self.init(location: location, length: length)
  }
}

public extension Int32 {
  var isFuture: Bool {
    self > Int32(Date().timeIntervalSince1970)
  }
}

public extension NSTextField {
  func setSelectionRange(_ range: NSRange) {
    textView?.setSelectedRange(range)
  }

  var selectedRange: NSRange {
    if let textView {
      return textView.selectedRange
    }
    return NSMakeRange(0, 0)
  }

  func setCursorToStart() {
    setSelectionRange(NSRange(location: 0, length: 0))
  }

  var textView: NSTextView? {
    let textView = (window?.fieldEditor(true, for: self) as? NSTextView)
    textView?.backgroundColor = .clear
    textView?.drawsBackground = true
    return textView
  }
}

public extension NSTextView {
  func appendText(_ text: String) {
    let inputText = attributedString().mutableCopy() as! NSMutableAttributedString

    if selectedRange.upperBound - selectedRange.lowerBound > 0 {
      inputText.replaceCharacters(
        in: NSMakeRange(selectedRange.lowerBound, selectedRange.upperBound - selectedRange.lowerBound),
        with: NSAttributedString(string: text)
      )
    } else {
      inputText.insert(NSAttributedString(string: text), at: selectedRange.lowerBound)
    }
    string = inputText.string
  }
}

public extension String {
  var persistentHashValue: UInt64 {
    var result = UInt64(5_381)
    let buf = [UInt8](utf8)
    for b in buf {
      result = 127 * (result & 0x00FF_FFFF_FFFF_FFFF) + UInt64(b)
    }
    return result
  }
}

extension NSEdgeInsets: @retroactive Equatable {
  public static func == (lhs: NSEdgeInsets, rhs: NSEdgeInsets) -> Bool {
    lhs.left == rhs.left && lhs.right == rhs.right && lhs.bottom == rhs.bottom && lhs.top == rhs.top
  }

  public var isEmpty: Bool {
    left == 0 && right == 0 && top == 0 && bottom == 0
  }
}

public extension NSImage {
  var _cgImage: CGImage? {
    cgImage(forProposedRect: nil, context: nil, hints: nil)
  }

  var jpegCGImage: CGImage? {
    guard let tiffData = tiffRepresentation,
          let bitmapImageRep = NSBitmapImageRep(data: tiffData)
    else {
      return nil
    }

    let compressionFactor: CGFloat = 1.0

    guard let jpegData = bitmapImageRep.representation(
      using: .jpeg,
      properties: [.compressionFactor: compressionFactor]
    ),
      let dataProvider = CGDataProvider(data: jpegData as CFData),
      let cgImage = CGImage(
        jpegDataProviderSource: dataProvider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
      )
    else {
      return nil
    }

    return cgImage
  }
}

public func deg2rad(_ number: Float) -> Float {
  number * .pi / 180
}

public func rad2deg(_ number: Float) -> Float {
  number * 180.0 / .pi
}

extension NSViewController {
  func centerInSuperview() -> [NSLayoutConstraint] {
    guard let superview = view.superview else { return [] }
    return [
      view.centerXAnchor.constraint(equalTo: superview.centerXAnchor),
      view.centerYAnchor.constraint(equalTo: superview.centerYAnchor),
    ]
  }
}

extension NSEdgeInsets {
  static let zero = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
  static func vertical(_ value: CGFloat) -> NSEdgeInsets {
    NSEdgeInsets(top: value, left: 0, bottom: value, right: 0)
  }

  static func horizontal(_ value: CGFloat) -> NSEdgeInsets {
    NSEdgeInsets(top: 0, left: value, bottom: 0, right: value)
  }

  static func top(_ value: CGFloat) -> NSEdgeInsets {
    NSEdgeInsets(top: value, left: 0, bottom: 0, right: 0)
  }

  static func bottom(_ value: CGFloat) -> NSEdgeInsets {
    NSEdgeInsets(top: 0, left: 0, bottom: value, right: 0)
  }

  var verticalTotal: CGFloat {
    top + bottom
  }

  var horizontalTotal: CGFloat {
    left + right
  }
}

extension NSEdgeInsets: Codable, @retroactive Hashable {
  // MARK: - Codable

  enum CodingKeys: String, CodingKey {
    case top, left, bottom, right
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let top = try container.decode(CGFloat.self, forKey: .top)
    let left = try container.decode(CGFloat.self, forKey: .left)
    let bottom = try container.decode(CGFloat.self, forKey: .bottom)
    let right = try container.decode(CGFloat.self, forKey: .right)
    self.init(top: top, left: left, bottom: bottom, right: right)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(top, forKey: .top)
    try container.encode(left, forKey: .left)
    try container.encode(bottom, forKey: .bottom)
    try container.encode(right, forKey: .right)
  }

  // MARK: - Hashable

  public func hash(into hasher: inout Hasher) {
    hasher.combine(top)
    hasher.combine(left)
    hasher.combine(bottom)
    hasher.combine(right)
  }
}


extension NSFont {
  func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
    let descriptor = fontDescriptor.withSymbolicTraits(traits)
    return NSFont(descriptor: descriptor, size: pointSize) ?? self
  }
}
