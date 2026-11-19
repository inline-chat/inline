import AppKit
import Foundation
import Synchronization

/// The font configuration for chat message content.
///
/// A value is an immutable snapshot. `current` is the live snapshot every message
/// layout reads; `apply(_:)` swaps it on the main thread and posts
/// `didChangeNotification` so message lists drop their caches and re-measure.
/// `revision` changes with every swap, so caches and view props that include it
/// can never mix fonts from two snapshots.
public struct ChatTypography: @unchecked Sendable {
  public struct Source: Equatable, Sendable {
    /// Comma-separated families or faces in fallback order. `system`, `ui-serif`,
    /// `ui-rounded` and `ui-monospace` select the system font designs.
    public var fontFamilies: String
    /// Point size; empty uses `defaultPointSize`.
    public var fontSize: String
    /// Line height as a multiple of the font size; empty uses `defaultLineHeight`.
    public var lineHeight: String
    /// Family for inline code and code blocks; empty uses SF Mono.
    public var codeFontFamily: String

    public init(fontFamilies: String = "", fontSize: String = "", lineHeight: String = "", codeFontFamily: String = "") {
      self.fontFamilies = fontFamilies
      self.fontSize = fontSize
      self.lineHeight = lineHeight
      self.codeFontFamily = codeFontFamily
    }
  }

  /// The built-in system font designs offered as named choices.
  public enum SystemDesign: String, CaseIterable, Sendable {
    case standard = "system"
    case serif = "ui-serif"
    case rounded = "ui-rounded"
    case monospaced = "ui-monospace"

    public var token: String { rawValue }

    public var title: String {
      switch self {
      case .standard: "System"
      case .serif: "New York"
      case .rounded: "SF Rounded"
      case .monospaced: "SF Mono"
      }
    }

    var fontDesign: NSFontDescriptor.SystemDesign {
      switch self {
      case .standard: .default
      case .serif: .serif
      case .rounded: .rounded
      case .monospaced: .monospaced
      }
    }
  }

  public static let fontFamiliesDefaultsKey = "chatTypography.fontFamilies"
  public static let fontSizeDefaultsKey = "chatTypography.fontSize"
  public static let lineHeightDefaultsKey = "chatTypography.lineHeight"
  public static let codeFontFamilyDefaultsKey = "chatTypography.codeFontFamily"

  /// Posted on the main thread after `current` changes.
  public static let didChangeNotification = Notification.Name("ChatTypographyDidChange")

  /// Sizes Make Text Bigger / Smaller step through: 1 pt around body sizes,
  /// 2 pt above 18 pt, so each step is a similar 6–11% change.
  public static let sizeSteps: [CGFloat] = [10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 26, 28, 32]
  public static var minimumPointSize: CGFloat { sizeSteps[0] }
  public static var maximumPointSize: CGFloat { sizeSteps[sizeSteps.count - 1] }

  /// Message text size when the user hasn't chosen one: the macOS system size.
  public static let defaultPointSize: CGFloat = 13

  /// Line heights offered in settings, as multiples of the font size. 1.2 is the
  /// system font's natural line; 1.28 adds a point at 13 and 14 pt.
  public static let lineHeightSteps: [CGFloat] = [1.2, 1.28, 1.4, 1.55]
  public static let defaultLineHeight: CGFloat = 1.28
  public static let minimumLineHeight: CGFloat = 1
  public static let maximumLineHeight: CGFloat = 2

  private struct LiveState: @unchecked Sendable {
    var typography: ChatTypography
    var nextRevision: Int
  }

  private static let live = Mutex(LiveState(typography: resolve(), nextRevision: 1))

  /// The snapshot message layout and rendering use right now.
  public static var current: ChatTypography {
    live.withLock { $0.typography }
  }

  public let font: NSFont
  public let source: Source
  /// Line height as a multiple of the font size (em). Lines never get tighter
  /// than the font's natural line.
  public let lineHeight: CGFloat
  /// Distinguishes live snapshots; 0 for values that never became `current`.
  public let revision: Int
  /// The main font's system design, or nil when it is a named family.
  private let systemDesign: SystemDesign?
  /// Fonts used for characters the main font lacks, in order.
  private let fallbackDescriptors: [NSFontDescriptor]
  /// Installed family for code, or nil for SF Mono.
  public let codeFontFamilyName: String?

  public var pointSize: CGFloat { font.pointSize }

  public var singleEmojiPointSize: CGFloat {
    scaledPointSize(preservingDefault: 64)
  }

  public var threeEmojisPointSize: CGFloat {
    scaledPointSize(preservingDefault: 42)
  }

  public var manyEmojisPointSize: CGFloat {
    scaledPointSize(preservingDefault: 18)
  }

  public var isDefaultSize: Bool { pointSize == Self.defaultPointSize }
  public var isDefaultLineHeight: Bool { lineHeight == Self.defaultLineHeight }

  /// The selected system design, or nil for a named family.
  public var selectedSystemDesign: SystemDesign? { systemDesign }

  /// Extra space between lines for text at `pointSize`.
  public var lineSpacing: CGFloat { lineSpacing(forPointSize: pointSize) }

  public static var systemPointSize: CGFloat { NSFont.systemFontSize }

  // MARK: - Live updates

  /// Makes `source` current. Returns false, and posts nothing, when it resolves
  /// to the typography already in use. Observers are notified on the main thread.
  @discardableResult
  public static func apply(_ source: Source) -> Bool {
    let candidate = resolve(source: source)
    let changed = live.withLock { state -> Bool in
      guard !state.typography.rendersIdentically(to: candidate) else {
        if state.typography.source != source {
          state.typography = candidate.withRevision(state.typography.revision)
        }
        return false
      }
      state.typography = candidate.withRevision(state.nextRevision)
      state.nextRevision += 1
      return true
    }
    if changed {
      if Thread.isMainThread {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
      } else {
        DispatchQueue.main.async {
          NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
      }
    }
    return changed
  }

  // MARK: - Resolution

  public static func storedSource(userDefaults: UserDefaults = .standard) -> Source {
    Source(
      fontFamilies: userDefaults.string(forKey: fontFamiliesDefaultsKey) ?? "",
      fontSize: userDefaults.string(forKey: fontSizeDefaultsKey) ?? "",
      lineHeight: userDefaults.string(forKey: lineHeightDefaultsKey) ?? "",
      codeFontFamily: userDefaults.string(forKey: codeFontFamilyDefaultsKey) ?? ""
    )
  }

  public static func resolve(userDefaults: UserDefaults = .standard) -> ChatTypography {
    resolve(source: storedSource(userDefaults: userDefaults))
  }

  public static func resolve(source: Source) -> ChatTypography {
    let pointSize = resolvedPointSize(source.fontSize)
    let lineHeight = resolvedLineHeight(source.lineHeight)
    let candidates = resolvedCandidates(source.fontFamilies)
    let codeFamily = resolvedCandidates(source.codeFontFamily).lazy.compactMap(\.familyName).first

    let primary = candidates.first ?? .system(.standard)
    let fallbacks = candidates.dropFirst().map { $0.descriptor(size: pointSize) }

    func make(_ font: NSFont, design: SystemDesign?) -> ChatTypography {
      ChatTypography(
        font: font,
        source: source,
        lineHeight: lineHeight,
        systemDesign: design,
        fallbackDescriptors: fallbacks,
        codeFontFamilyName: codeFamily
      )
    }

    if case let .system(design) = primary {
      let font = withFallbacks(fallbacks, systemFont(design, size: pointSize, weight: .regular))
      return make(font, design: design)
    }

    var descriptor = primary.descriptor(size: pointSize)
    if !fallbacks.isEmpty {
      descriptor = descriptor.addingAttributes([.cascadeList: fallbacks])
    }
    guard let font = NSFont(descriptor: descriptor, size: pointSize) else {
      return make(withFallbacks(fallbacks, .systemFont(ofSize: pointSize)), design: .standard)
    }
    return make(font, design: nil)
  }

  /// Splits a stored family list into its names, in fallback order.
  public static func familyList(_ rawValue: String) -> [String] {
    rawValue
      .split(separator: ",", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  public static func familyString(_ families: [String]) -> String {
    families.joined(separator: ", ")
  }

  /// Installed fixed-pitch families, for the code font menu.
  public static func installedMonospacedFamilies() -> [String] {
    let manager = NSFontManager.shared
    let families = Set((manager.availableFontNames(with: .fixedPitchFontMask) ?? []).compactMap { name in
      NSFont(name: name, size: systemPointSize)?.familyName
    })
    return families.filter { !$0.hasPrefix(".") }.sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
  }

  // MARK: - Fonts

  public func font(sized pointSize: CGFloat) -> NSFont {
    if let systemDesign {
      return Self.withFallbacks(
        fallbackDescriptors,
        Self.systemFont(systemDesign, size: pointSize, weight: .regular)
      )
    }
    return NSFont(descriptor: font.fontDescriptor, size: pointSize) ?? font.withSize(pointSize)
  }

  public func font(sized pointSize: CGFloat, weight: NSFont.Weight) -> NSFont {
    if let systemDesign {
      return Self.withFallbacks(
        fallbackDescriptors,
        Self.systemFont(systemDesign, size: pointSize, weight: weight)
      )
    }

    var traits = (font.fontDescriptor.object(forKey: .traits)
      as? [NSFontDescriptor.TraitKey: Any]) ?? [:]
    traits[.weight] = weight.rawValue
    let descriptor = font.fontDescriptor.addingAttributes([.traits: traits])
    return NSFont(descriptor: descriptor, size: pointSize) ?? font(sized: pointSize)
  }

  /// Font for inline code and code blocks: the chosen code family, else SF Mono.
  public func codeFont(sized pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    let system = NSFont.monospacedSystemFont(ofSize: pointSize, weight: weight)
    guard let codeFontFamilyName else { return system }
    let descriptor = NSFontDescriptor(fontAttributes: [
      .family: codeFontFamilyName,
      .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
    ])
    return NSFont(descriptor: descriptor, size: pointSize) ?? system
  }

  /// Monospaced base for inline code and code blocks, sized like the message text.
  public func monospaceBaseFont(sized pointSize: CGFloat) -> NSFont {
    codeFont(sized: pointSize)
  }

  // MARK: - Line height

  /// Space added between lines so each line advances by `lineHeight` times the
  /// font size. Whole points, so Core Text measurement and TextKit rendering agree
  /// and baselines stay on the pixel grid.
  public func lineSpacing(forPointSize pointSize: CGFloat) -> CGFloat {
    Self.lineSpacing(for: font(sized: pointSize), lineHeight: lineHeight)
  }

  public static func lineSpacing(for font: NSFont, lineHeight: CGFloat) -> CGFloat {
    max(0, (lineHeight * font.pointSize).rounded() - naturalLineHeight(of: font))
  }

  public static func naturalLineHeight(of font: NSFont) -> CGFloat {
    ceil(font.ascender - font.descender + font.leading)
  }

  /// Adds `lineSpacing` to every paragraph that does not already set one.
  /// Existing paragraph attributes (indents, direction, spacing) are kept.
  public static func applyLineSpacing(
    _ lineSpacing: CGFloat,
    to text: NSMutableAttributedString,
    skipping shouldSkip: ((NSRange) -> Bool)? = nil
  ) {
    guard lineSpacing > 0, text.length > 0 else { return }
    let fullRange = NSRange(location: 0, length: text.length)
    var updates: [(NSRange, NSParagraphStyle)] = []
    text.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
      if shouldSkip?(range) == true { return }
      let existing = value as? NSParagraphStyle
      guard (existing?.lineSpacing ?? 0) == 0 else { return }
      let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
      style.lineSpacing = lineSpacing
      updates.append((range, style))
    }
    for (range, style) in updates {
      text.addAttribute(.paragraphStyle, value: style, range: range)
    }
  }

  // MARK: - Size steps

  /// The next size step above `pointSize`, or nil at the maximum.
  public static func nextLargerSize(than pointSize: CGFloat) -> CGFloat? {
    sizeSteps.first { $0 > pointSize + 0.01 }
  }

  /// The next size step below `pointSize`, or nil at the minimum.
  public static func nextSmallerSize(than pointSize: CGFloat) -> CGFloat? {
    sizeSteps.last { $0 < pointSize - 0.01 }
  }

  /// Display form of a size or line height for storage and labels.
  public static func format(_ value: CGFloat) -> String {
    let rounded = (value * 100).rounded() / 100
    if rounded == rounded.rounded() {
      return String(Int(rounded))
    }
    return String(format: "%g", Double(rounded))
  }

  // MARK: - Private

  private init(
    font: NSFont,
    source: Source,
    lineHeight: CGFloat,
    systemDesign: SystemDesign?,
    fallbackDescriptors: [NSFontDescriptor],
    codeFontFamilyName: String?,
    revision: Int = 0
  ) {
    self.font = font
    self.source = source
    self.lineHeight = lineHeight
    self.systemDesign = systemDesign
    self.fallbackDescriptors = fallbackDescriptors
    self.codeFontFamilyName = codeFontFamilyName
    self.revision = revision
  }

  private func withRevision(_ revision: Int) -> ChatTypography {
    ChatTypography(
      font: font,
      source: source,
      lineHeight: lineHeight,
      systemDesign: systemDesign,
      fallbackDescriptors: fallbackDescriptors,
      codeFontFamilyName: codeFontFamilyName,
      revision: revision
    )
  }

  /// Same glyphs and metrics, regardless of how the source spelled them.
  func rendersIdentically(to other: ChatTypography) -> Bool {
    systemDesign == other.systemDesign
      && lineHeight == other.lineHeight
      && codeFontFamilyName == other.codeFontFamilyName
      && font.pointSize == other.font.pointSize
      && font.fontDescriptor.isEqual(other.font.fontDescriptor)
  }

  private static func withFallbacks(_ fallbacks: [NSFontDescriptor], _ font: NSFont) -> NSFont {
    guard !fallbacks.isEmpty else { return font }
    let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: fallbacks])
    return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
  }

  private func scaledPointSize(preservingDefault defaultPointSize: CGFloat) -> CGFloat {
    pointSize * defaultPointSize / Self.defaultPointSize
  }

  private static func systemFont(_ design: SystemDesign, size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard design != .standard,
          let descriptor = base.fontDescriptor.withDesign(design.fontDesign),
          let font = NSFont(descriptor: descriptor, size: size)
    else { return base }
    return font
  }

  private static func resolvedPointSize(_ rawValue: String) -> CGFloat {
    let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    guard let value, value.isFinite, value > 0 else {
      return defaultPointSize
    }
    return CGFloat(value)
  }

  private static func resolvedLineHeight(_ rawValue: String) -> CGFloat {
    let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    guard let value, value.isFinite, value > 0 else { return defaultLineHeight }
    return min(max(CGFloat(value), minimumLineHeight), maximumLineHeight)
  }

  private enum Candidate {
    case system(SystemDesign)
    case family(String)
    case face(String)

    func descriptor(size: CGFloat) -> NSFontDescriptor {
      switch self {
      case let .system(design):
        ChatTypography.systemFont(design, size: size, weight: .regular).fontDescriptor
      case let .family(family):
        NSFontDescriptor(fontAttributes: [.family: family])
      case let .face(name):
        NSFontDescriptor(name: name, size: size)
      }
    }

    var familyName: String? {
      switch self {
      case .system: nil
      case let .family(family): family
      case let .face(name): NSFont(name: name, size: ChatTypography.systemPointSize)?.familyName
      }
    }
  }

  private static func resolvedCandidates(_ rawValue: String) -> [Candidate] {
    let names = familyList(rawValue)

    guard !names.isEmpty else { return [] }

    var seen = Set<String>()
    var familiesByLowercasedName: [String: String]?
    var facesByLowercasedName: [String: String]?

    return names.compactMap { name in
      let normalized = name.lowercased()
      guard seen.insert(normalized).inserted else { return nil }

      if let design = SystemDesign(rawValue: normalized) {
        return .system(design)
      }
      if familiesByLowercasedName == nil {
        familiesByLowercasedName = Dictionary(
          NSFontManager.shared.availableFontFamilies.map { ($0.lowercased(), $0) },
          uniquingKeysWith: { first, _ in first }
        )
      }
      if let family = familiesByLowercasedName?[normalized] {
        return .family(family)
      }
      if facesByLowercasedName == nil {
        facesByLowercasedName = Dictionary(
          NSFontManager.shared.availableFonts.map { ($0.lowercased(), $0) },
          uniquingKeysWith: { first, _ in first }
        )
      }
      if let face = facesByLowercasedName?[normalized] {
        return .face(face)
      }
      return nil
    }
  }
}
