import AppKit
import Foundation

/// The process-scoped font configuration for chat message content.
///
/// `current` is intentionally resolved once. Settings edits take effect after
/// relaunch, which also gives every message layout and rendering cache one
/// coherent font for its entire lifetime.
public struct ChatTypography {
  public struct Source: Equatable, Sendable {
    public let fontFamilies: String
    public let fontSize: String

    public init(fontFamilies: String = "", fontSize: String = "") {
      self.fontFamilies = fontFamilies
      self.fontSize = fontSize
    }
  }

  public static let fontFamiliesDefaultsKey = "chatTypography.fontFamilies"
  public static let fontSizeDefaultsKey = "chatTypography.fontSize"

  public nonisolated(unsafe) static let current = resolve()

  public let font: NSFont
  public let source: Source
  private let usesPlainSystemFont: Bool

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

  public static var systemPointSize: CGFloat { NSFont.systemFontSize }

  public static func storedSource(userDefaults: UserDefaults = .standard) -> Source {
    Source(
      fontFamilies: userDefaults.string(forKey: fontFamiliesDefaultsKey) ?? "",
      fontSize: userDefaults.string(forKey: fontSizeDefaultsKey) ?? ""
    )
  }

  public static func resolve(userDefaults: UserDefaults = .standard) -> ChatTypography {
    resolve(source: storedSource(userDefaults: userDefaults))
  }

  public static func resolve(source: Source) -> ChatTypography {
    let pointSize = resolvedPointSize(source.fontSize)
    let descriptors = resolvedFontDescriptors(source.fontFamilies)

    guard let primary = descriptors.first else {
      return ChatTypography(
        font: .systemFont(ofSize: pointSize),
        source: source,
        usesPlainSystemFont: true
      )
    }

    let systemDescriptor = NSFont.systemFont(ofSize: systemPointSize).fontDescriptor
    let usesPlainSystemFont = descriptors.count == 1
      && primary.postscriptName == systemDescriptor.postscriptName

    if usesPlainSystemFont {
      return ChatTypography(
        font: .systemFont(ofSize: pointSize),
        source: source,
        usesPlainSystemFont: true
      )
    }

    let descriptor: NSFontDescriptor
    if descriptors.count > 1 {
      descriptor = primary.addingAttributes([
        .cascadeList: Array(descriptors.dropFirst()),
      ])
    } else {
      descriptor = primary
    }

    return ChatTypography(
      font: NSFont(descriptor: descriptor, size: pointSize) ?? .systemFont(ofSize: pointSize),
      source: source,
      usesPlainSystemFont: false
    )
  }

  public func font(sized pointSize: CGFloat) -> NSFont {
    if usesPlainSystemFont {
      return .systemFont(ofSize: pointSize)
    }
    return NSFont(descriptor: font.fontDescriptor, size: pointSize) ?? font.withSize(pointSize)
  }

  public func font(sized pointSize: CGFloat, weight: NSFont.Weight) -> NSFont {
    if usesPlainSystemFont {
      return .systemFont(ofSize: pointSize, weight: weight)
    }

    var traits = (font.fontDescriptor.object(forKey: .traits)
      as? [NSFontDescriptor.TraitKey: Any]) ?? [:]
    traits[.weight] = weight.rawValue
    let descriptor = font.fontDescriptor.addingAttributes([.traits: traits])
    return NSFont(descriptor: descriptor, size: pointSize) ?? font(sized: pointSize)
  }

  private init(font: NSFont, source: Source, usesPlainSystemFont: Bool) {
    self.font = font
    self.source = source
    self.usesPlainSystemFont = usesPlainSystemFont
  }

  private func scaledPointSize(preservingDefault defaultPointSize: CGFloat) -> CGFloat {
    pointSize * defaultPointSize / Self.systemPointSize
  }

  private static func resolvedPointSize(_ rawValue: String) -> CGFloat {
    let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    guard let value, value.isFinite, value > 0 else {
      return systemPointSize
    }
    return CGFloat(value)
  }

  private static func resolvedFontDescriptors(_ rawValue: String) -> [NSFontDescriptor] {
    let candidates = rawValue
      .split(separator: ",", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    guard !candidates.isEmpty else { return [] }

    let fontManager = NSFontManager.shared
    let familiesByLowercasedName = Dictionary(
      fontManager.availableFontFamilies.map { ($0.lowercased(), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let fontsByLowercasedName = Dictionary(
      fontManager.availableFonts.map { ($0.lowercased(), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var seen = Set<String>()

    return candidates.compactMap { candidate in
      let normalized = candidate.lowercased()
      guard seen.insert(normalized).inserted else { return nil }

      if normalized == "system" {
        return NSFont.systemFont(ofSize: systemPointSize).fontDescriptor
      }
      if let family = familiesByLowercasedName[normalized] {
        return NSFontDescriptor(fontAttributes: [.family: family])
      }
      if let fontName = fontsByLowercasedName[normalized] {
        return NSFontDescriptor(name: fontName, size: systemPointSize)
      }
      return nil
    }
  }
}
