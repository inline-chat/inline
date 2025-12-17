#if os(macOS)
import AppKit

// MARK: - RichTextSanitizer

/// Sanitizes pasted rich text content to preserve only supported formatting.
///
/// Supported formatting:
/// - Bold text (via font traits)
/// - Italic text (via font traits or custom attribute)
/// - Links (validated http/https/mailto schemes)
/// - Headings (converted to bold)
/// - List markers (tab-delimited bullets normalized)
/// - Code blocks (wrapped with ``` markdown markers)
///
/// TODO: Second batch implementation
/// - Inline code
///
/// TODO: Bold/italic rendering issue
/// Detection works correctly (isBoldFont/isItalicFont), but NSTextView doesn't render the
/// bold fonts from fontWithTraits(). The font is stored correctly in textStorage but doesn't
/// display visually. Investigate NSTextView font rendering configuration.
public struct RichTextSanitizer {
  // MARK: - Configuration

  public struct Configuration {
    /// Base font to use for all sanitized content.
    public var baseFont: NSFont

    /// Base text color for non-link text.
    public var baseColor: NSColor

    /// Whether to preserve bold formatting.
    public var preserveBold: Bool

    /// Whether to preserve italic formatting.
    public var preserveItalic: Bool

    /// Whether to preserve links.
    public var preserveLinks: Bool

    /// Whether to convert headings to bold.
    public var convertHeadingsToBold: Bool

    /// Allowed URL schemes for links.
    public var allowedLinkSchemes: Set<String>

    /// Maximum allowed link text length.
    public var maxLinkLength: Int

    /// Font size multiplier threshold to detect headings.
    /// Text with font size >= baseFont.pointSize * headingThreshold is considered a heading.
    public var headingFontSizeThreshold: CGFloat

    /// Whether to normalize tab-delimited list markers (e.g., `\t-\t` → `- `).
    public var normalizeListMarkers: Bool

    /// Whether to wrap code blocks with markdown ``` markers.
    public var wrapCodeBlocks: Bool

    public init(
      baseFont: NSFont,
      baseColor: NSColor,
      preserveBold: Bool = true,
      preserveItalic: Bool = true,
      preserveLinks: Bool = true,
      convertHeadingsToBold: Bool = true,
      allowedLinkSchemes: Set<String> = ["http", "https", "mailto"],
      maxLinkLength: Int = 512,
      headingFontSizeThreshold: CGFloat = 1.3,
      normalizeListMarkers: Bool = true,
      wrapCodeBlocks: Bool = true
    ) {
      self.baseFont = baseFont
      self.baseColor = baseColor
      self.preserveBold = preserveBold
      self.preserveItalic = preserveItalic
      self.preserveLinks = preserveLinks
      self.convertHeadingsToBold = convertHeadingsToBold
      self.allowedLinkSchemes = allowedLinkSchemes
      self.maxLinkLength = maxLinkLength
      self.headingFontSizeThreshold = headingFontSizeThreshold
      self.normalizeListMarkers = normalizeListMarkers
      self.wrapCodeBlocks = wrapCodeBlocks
    }

    public static func `default`(baseFont: NSFont, baseColor: NSColor) -> Configuration {
      Configuration(baseFont: baseFont, baseColor: baseColor)
    }
  }

  // MARK: - Output

  public struct Result {
    /// The sanitized attributed string.
    public let attributedString: NSAttributedString

    /// Statistics about what was processed.
    public let stats: Stats
  }

  public struct Stats {
    public var boldRanges: Int = 0
    public var italicRanges: Int = 0
    public var linksPreserved: Int = 0
    public var linksDropped: Int = 0
    public var headingsConverted: Int = 0
    public var listMarkersNormalized: Int = 0
    public var codeBlocksWrapped: Int = 0

    public init() {}
  }

  // MARK: - Properties

  public let configuration: Configuration

  // MARK: - Initialization

  public init(configuration: Configuration) {
    self.configuration = configuration
  }

  // MARK: - Public API

  /// Sanitizes the input attributed string according to configuration.
  public func sanitize(_ input: NSAttributedString) -> Result {
    var stats = Stats()

    // Step 1: Detect code blocks BEFORE modifying text (need original font info)
    let codeBlockRanges = configuration.wrapCodeBlocks ? detectCodeBlocks(in: input) : []

    // Step 2: Create base output with plain text and default attributes
    let output = NSMutableAttributedString(
      string: input.string,
      attributes: baseAttributes()
    )

    var fullRange = NSRange(location: 0, length: output.length)
    guard fullRange.length > 0 else {
      return Result(attributedString: output, stats: stats)
    }

    // Step 3: Detect and mark headings (before processing bold, as headings become bold)
    let headingRanges = detectHeadings(in: input)
    stats.headingsConverted = headingRanges.count

    // Step 4: Process bold formatting
    if configuration.preserveBold {
      stats.boldRanges = applyBold(from: input, to: output, headingRanges: headingRanges)
    }

    // Step 5: Process italic formatting
    if configuration.preserveItalic {
      stats.italicRanges = applyItalic(from: input, to: output)
    }

    // Step 6: Process links
    if configuration.preserveLinks {
      let linkStats = applyLinks(from: input, to: output)
      stats.linksPreserved = linkStats.preserved
      stats.linksDropped = linkStats.dropped
    }

    // Step 7: Wrap code blocks with markdown ``` (modifies string, so do after attribute processing)
    if configuration.wrapCodeBlocks {
      stats.codeBlocksWrapped = wrapCodeBlocks(in: output, ranges: codeBlockRanges)
    }

    // Step 8: Normalize list markers (modifies string, do last)
    if configuration.normalizeListMarkers {
      stats.listMarkersNormalized = normalizeListMarkers(in: output)
    }

    return Result(attributedString: output, stats: stats)
  }

  // MARK: - Private: Base Attributes

  private func baseAttributes() -> [NSAttributedString.Key: Any] {
    [
      .font: configuration.baseFont,
      .foregroundColor: configuration.baseColor,
    ]
  }

  // MARK: - Private: Heading Detection

  private func detectHeadings(in input: NSAttributedString) -> [NSRange] {
    guard configuration.convertHeadingsToBold else { return [] }

    var headingRanges: [NSRange] = []
    let fullRange = NSRange(location: 0, length: input.length)
    let threshold = configuration.baseFont.pointSize * configuration.headingFontSizeThreshold

    // Method 1: Detect by font size
    input.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
      guard let font = value as? NSFont else { return }
      if font.pointSize >= threshold {
        headingRanges.append(range)
      }
    }

    // Method 2: Detect markdown-style headings (# at start of line)
    let string = input.string as NSString
    let pattern = "^#{1,6}\\s+"
    if let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) {
      let matches = regex.matches(in: input.string, options: [], range: fullRange)
      for match in matches {
        // Find the end of this line to mark the whole heading
        let lineRange = string.lineRange(for: match.range)
        if !headingRanges.contains(where: { NSIntersectionRange($0, lineRange).length > 0 }) {
          headingRanges.append(lineRange)
        }
      }
    }

    return headingRanges
  }

  // MARK: - Private: Bold Processing

  private func applyBold(
    from input: NSAttributedString,
    to output: NSMutableAttributedString,
    headingRanges: [NSRange]
  ) -> Int {
    var count = 0
    let fullRange = NSRange(location: 0, length: input.length)

    // First, apply bold to all heading ranges
    for range in headingRanges {
      let boldFont = fontWithTraits(bold: true, italic: false)
      output.addAttribute(.font, value: boldFont, range: range)
      count += 1
    }

    // Then, detect bold from source font
    input.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
      guard let sourceFont = value as? NSFont else { return }

      guard isBoldFont(sourceFont) else { return }

      // Check if this range is already part of a heading
      let isHeading = headingRanges.contains { NSIntersectionRange($0, range).length > 0 }
      if isHeading { return }

      // Check if italic is also present to apply both traits
      let currentFont = output.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
      let isItalic = currentFont.map { isItalicFont($0) } ?? false

      let boldFont = fontWithTraits(bold: true, italic: isItalic)
      output.addAttribute(.font, value: boldFont, range: range)
      count += 1
    }

    return count
  }

  /// Detects if a font is bold using multiple methods.
  /// HTML/RTF sources may encode bold via traits, weight, or font name.
  private func isBoldFont(_ font: NSFont) -> Bool {
    // Method 1: Check NSFontManager traits (traditional approach)
    let traits = NSFontManager.shared.traits(of: font)
    if traits.contains(.boldFontMask) {
      return true
    }

    // Method 2: Check font weight (HTML often uses font-weight: bold → weight >= 600)
    let weight = NSFontManager.shared.weight(of: font)
    if weight >= 9 { // NSFontManager weight 9+ is typically bold (semibold/bold/heavy)
      return true
    }

    // Method 3: Check font descriptor weight attribute
    if let weightTrait = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any],
       let weightValue = weightTrait[.weight] as? CGFloat,
       weightValue >= NSFont.Weight.semibold.rawValue
    {
      return true
    }

    // Method 4: Check font name contains "bold" (fallback for some fonts)
    let fontName = font.fontName.lowercased()
    if fontName.contains("bold") || fontName.contains("-bd") {
      return true
    }

    return false
  }

  // MARK: - Private: Italic Processing

  private func applyItalic(
    from input: NSAttributedString,
    to output: NSMutableAttributedString
  ) -> Int {
    var count = 0
    let fullRange = NSRange(location: 0, length: input.length)

    // Detect italic from font
    input.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
      guard let sourceFont = value as? NSFont else { return }

      guard isItalicFont(sourceFont) else { return }

      // Check if bold is also present to preserve it
      let currentFont = output.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
      let isBold = currentFont.map { isBoldFont($0) } ?? false

      let italicFont = fontWithTraits(bold: isBold, italic: true)
      output.addAttribute(.font, value: italicFont, range: range)
      output.addAttribute(.italic, value: true, range: range)
      count += 1
    }

    // Also check custom .italic attribute (some apps use this instead of font traits)
    input.enumerateAttribute(.italic, in: fullRange, options: []) { value, range, _ in
      guard value != nil else { return }

      // Skip if already processed via font
      if let font = output.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
        if isItalicFont(font) { return }
      }

      let currentFont = output.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
      let isBold = currentFont.map { isBoldFont($0) } ?? false

      let italicFont = fontWithTraits(bold: isBold, italic: true)
      output.addAttribute(.font, value: italicFont, range: range)
      output.addAttribute(.italic, value: true, range: range)
      count += 1
    }

    return count
  }

  /// Detects if a font is italic using multiple methods.
  private func isItalicFont(_ font: NSFont) -> Bool {
    // Method 1: Check NSFontManager traits
    let traits = NSFontManager.shared.traits(of: font)
    if traits.contains(.italicFontMask) {
      return true
    }

    // Method 2: Check font descriptor symbolic traits
    let symbolicTraits = font.fontDescriptor.symbolicTraits
    if symbolicTraits.contains(.italic) {
      return true
    }

    // Method 3: Check font name contains italic/oblique
    let fontName = font.fontName.lowercased()
    if fontName.contains("italic") || fontName.contains("oblique") || fontName.contains("-it") {
      return true
    }

    return false
  }

  // MARK: - Private: Link Processing

  private func applyLinks(
    from input: NSAttributedString,
    to output: NSMutableAttributedString
  ) -> (preserved: Int, dropped: Int) {
    var preserved = 0
    var dropped = 0
    let fullRange = NSRange(location: 0, length: input.length)

    input.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
      // Skip ranges without a link attribute
      guard let value, range.location != NSNotFound, range.length > 0 else { return }

      // Extract URL string
      let urlString: String? = {
        if let url = value as? URL { return url.absoluteString }
        if let str = value as? String { return str }
        return nil
      }()

      // Validate link
      guard let urlString,
            let url = URL(string: urlString),
            let scheme = url.scheme?.lowercased(),
            configuration.allowedLinkSchemes.contains(scheme)
      else {
        dropped += 1
        return
      }

      // Skip multi-line links (common HTML export bug)
      let rangeText = (input.string as NSString).substring(with: range)
      guard !rangeText.contains("\n") else {
        dropped += 1
        return
      }

      // Skip overly long links
      guard range.length <= configuration.maxLinkLength else {
        dropped += 1
        return
      }

      // Apply link attributes
      output.addAttributes([
        .link: urlString,
        .foregroundColor: NSColor.linkColor,
        .underlineStyle: 0,
        .cursor: NSCursor.pointingHand,
      ], range: range)

      preserved += 1
    }

    return (preserved, dropped)
  }

  // MARK: - Private: Font Helpers

  private func fontWithTraits(bold: Bool, italic: Bool) -> NSFont {
    guard bold || italic else { return configuration.baseFont }

    let size = configuration.baseFont.pointSize

    // Use explicit system fonts for more reliable bold rendering
    if bold && italic {
      // Try to get bold-italic
      let descriptor = NSFontDescriptor.preferredFontDescriptor(forTextStyle: .body)
        .withSymbolicTraits([.bold, .italic])
      if let font = NSFont(descriptor: descriptor, size: size) {
        return font
      }
      // Fallback: just bold
      return NSFont.boldSystemFont(ofSize: size)
    }

    if bold {
      // Use boldSystemFont for guaranteed bold appearance
      return NSFont.boldSystemFont(ofSize: size)
    }

    if italic {
      // Try to get italic via descriptor
      let descriptor = configuration.baseFont.fontDescriptor.withSymbolicTraits(.italic)
      if let font = NSFont(descriptor: descriptor, size: size) {
        return font
      }
      // Try NSFontManager
      if let converted = NSFontManager.shared.convert(configuration.baseFont, toHaveTrait: .italicFontMask) as NSFont? {
        return converted
      }
    }

    return configuration.baseFont
  }

  // MARK: - Private: List Marker Normalization

  /// Common monospace font family names used to detect code blocks.
  private static let monospaceFontFamilies: Set<String> = [
    "courier", "menlo", "monaco", "consolas", "source code",
    "sf mono", "andale mono", "dejavu sans mono", "liberation mono",
    "ubuntu mono", "fira code", "jetbrains mono", "hack",
  ]

  /// Normalizes tab-delimited list markers that arrive from rich text sources.
  /// Patterns like `\t-\t` or `\t*\t` become `- ` or `* `.
  /// Nested lists (`\t\t-\t`) become `\t- `.
  private func normalizeListMarkers(in output: NSMutableAttributedString) -> Int {
    // Simple pattern: line starts with tabs, then a bullet/dash/asterisk/number, then a tab
    // We normalize to: (nestingLevel - 1) tabs + marker + space
    //
    // Examples:
    //   \t-\t  → "- "      (single level, no indent)
    //   \t\t-\t → "\t- "   (nested, one indent)
    //   \t1\t  → "1. "     (numbered)
    //   \t•\t  → "- "      (bullet becomes dash for markdown)

    guard output.length > 0 else { return 0 }

    let string = output.mutableString
    var replacementCount = 0

    // Process patterns in reverse order of match location to preserve indices

    // Pattern 1: Bulleted lists - \t+[•\-*]\t at line start
    // Captures: (tabs)(marker)
    let bulletPattern = "(?m)^(\\t+)([•\\-*])\\t"
    if let regex = try? NSRegularExpression(pattern: bulletPattern, options: []) {
      let matches = regex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length))

      // Process in reverse to preserve indices
      for match in matches.reversed() {
        guard match.numberOfRanges >= 3 else { continue }

        let tabsRange = match.range(at: 1)
        let markerRange = match.range(at: 2)
        let fullRange = match.range(at: 0)

        let tabCount = tabsRange.length
        let marker = string.substring(with: markerRange)

        // Normalize bullet to dash for markdown compatibility
        let normalizedMarker = (marker == "•") ? "-" : marker

        // Nesting: 1 tab = no indent, 2+ tabs = (n-1) indent
        let indentCount = max(0, tabCount - 1)
        let indent = String(repeating: "\t", count: indentCount)
        let replacement = "\(indent)\(normalizedMarker) "

        output.replaceCharacters(in: fullRange, with: replacement)
        replacementCount += 1
      }
    }

    // Pattern 2: Numbered lists - \t+[0-9]+\.?\t at line start
    let numberPattern = "(?m)^(\\t+)(\\d+)\\.?\\t"
    if let regex = try? NSRegularExpression(pattern: numberPattern, options: []) {
      let matches = regex.matches(in: string as String, options: [], range: NSRange(location: 0, length: string.length))

      for match in matches.reversed() {
        guard match.numberOfRanges >= 3 else { continue }

        let tabsRange = match.range(at: 1)
        let numberRange = match.range(at: 2)
        let fullRange = match.range(at: 0)

        let tabCount = tabsRange.length
        let number = string.substring(with: numberRange)

        let indentCount = max(0, tabCount - 1)
        let indent = String(repeating: "\t", count: indentCount)
        let replacement = "\(indent)\(number). "

        output.replaceCharacters(in: fullRange, with: replacement)
        replacementCount += 1
      }
    }

    return replacementCount
  }

  // MARK: - Private: Code Block Detection and Wrapping

  /// Detects ranges that appear to be code blocks (monospace font).
  private func detectCodeBlocks(in input: NSAttributedString) -> [NSRange] {
    var codeRanges: [NSRange] = []
    let fullRange = NSRange(location: 0, length: input.length)

    input.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
      guard let font = value as? NSFont else { return }

      if isMonospaceFont(font) {
        codeRanges.append(range)
      }
    }

    // Merge adjacent/overlapping ranges into contiguous blocks
    return mergeAdjacentRanges(codeRanges)
  }

  /// Checks if a font is monospace based on font family name.
  private func isMonospaceFont(_ font: NSFont) -> Bool {
    let familyName = font.familyName?.lowercased() ?? ""
    let fontName = font.fontName.lowercased()

    // Check against known monospace font families
    for mono in Self.monospaceFontFamilies {
      if familyName.contains(mono) || fontName.contains(mono) {
        return true
      }
    }

    // Also check if font descriptor indicates fixed-pitch
    let traits = font.fontDescriptor.symbolicTraits
    if traits.contains(.monoSpace) {
      return true
    }

    return false
  }

  /// Merges adjacent or overlapping ranges into contiguous blocks.
  private func mergeAdjacentRanges(_ ranges: [NSRange]) -> [NSRange] {
    guard !ranges.isEmpty else { return [] }

    let sorted = ranges.sorted { $0.location < $1.location }
    var merged: [NSRange] = []

    var current = sorted[0]
    for range in sorted.dropFirst() {
      // Check if ranges are adjacent or overlapping
      if range.location <= current.location + current.length {
        // Merge
        let newEnd = max(current.location + current.length, range.location + range.length)
        current = NSRange(location: current.location, length: newEnd - current.location)
      } else {
        merged.append(current)
        current = range
      }
    }
    merged.append(current)

    return merged
  }

  /// Wraps detected code block ranges with markdown ``` markers.
  /// Works backwards to preserve range indices.
  private func wrapCodeBlocks(in output: NSMutableAttributedString, ranges: [NSRange]) -> Int {
    guard !ranges.isEmpty else { return 0 }

    let baseAttrs = baseAttributes()

    // Process in reverse order to preserve indices
    for range in ranges.reversed() {
      // Validate range is still within bounds
      guard range.location >= 0, range.location + range.length <= output.length else { continue }

      // Get the code content
      let codeContent = (output.string as NSString).substring(with: range)

      // Skip if it's just whitespace
      guard !codeContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

      // Determine if this is inline (single line) or block (multiline)
      let isMultiline = codeContent.contains("\n")

      if isMultiline {
        // Block code: wrap with ```\n...\n```
        // Ensure proper newlines around the markers
        var wrapped = "```\n"
        wrapped += codeContent.hasSuffix("\n") ? codeContent : codeContent + "\n"
        wrapped += "```"

        let replacement = NSAttributedString(string: wrapped, attributes: baseAttrs)
        output.replaceCharacters(in: range, with: replacement)
      } else {
        // Single line code - could be inline or a short block
        // If it looks like a standalone line, treat as block
        // For now, wrap as block to be safe
        let wrapped = "```\n\(codeContent)\n```"
        let replacement = NSAttributedString(string: wrapped, attributes: baseAttrs)
        output.replaceCharacters(in: range, with: replacement)
      }
    }

    return ranges.count
  }
}

// MARK: - Custom Attribute Key

public extension NSAttributedString.Key {
  /// Custom attribute to mark italic text (some apps don't use italic font traits).
  static let italic = NSAttributedString.Key("InlineItalic")
}

#endif
