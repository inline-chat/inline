import Foundation

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
public typealias PlatformFontWeight = NSFont.Weight
#else
public typealias PlatformFontWeight = UIFont.Weight
#endif

public enum PlatformFontTraits {
  /// Apply a block's typography without erasing inline emphasis or code fonts.
  public static func applyBaseFont(_ baseFont: PlatformFont, to text: NSMutableAttributedString) {
    let fullRange = NSRange(location: 0, length: text.length)
    var runs: [(NSRange, PlatformFont)] = []
    var resolvedFonts: [PlatformFont: PlatformFont] = [:]
    text.enumerateAttribute(.font, in: fullRange) { value, range, _ in
      if let font = value as? PlatformFont {
        let resolved = resolvedFonts[font] ?? inheritingInlineTraits(from: font, baseFont: baseFont)
        resolvedFonts[font] = resolved
        runs.append((range, resolved))
      }
    }
    text.addAttribute(.font, value: baseFont, range: fullRange)
    for (range, font) in runs {
      text.addAttribute(.font, value: font, range: range)
    }
  }

  private static func inheritingInlineTraits(from font: PlatformFont, baseFont: PlatformFont) -> PlatformFont {
    #if os(macOS)
    let supported: NSFontDescriptor.SymbolicTraits = [.bold, .italic, .monoSpace, .condensed, .expanded]
    let traits = font.fontDescriptor.symbolicTraits.intersection(supported)
    guard !traits.isEmpty else { return baseFont }
    let baseTraits = baseFont.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
    let baseWeight: CGFloat = (baseTraits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) }
      ?? (isBold(baseFont) ? NSFont.Weight.bold.rawValue : NSFont.Weight.regular.rawValue)
    let weight = traits.contains(.bold) ? max(baseWeight, NSFont.Weight.bold.rawValue) : baseWeight
    let base: NSFont
    if traits.contains(.monoSpace) {
      base = .monospacedSystemFont(ofSize: baseFont.pointSize, weight: .init(rawValue: weight))
    } else {
      base = baseFont
    }
    let descriptor = base.fontDescriptor
    var mergedTraits = (descriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]) ?? [:]
    // Apply symbolic traits and weight together. withSymbolicTraits first can
    // resolve a medium monospaced face back to regular before weight is applied.
    mergedTraits[.symbolic] = descriptor.symbolicTraits.union(traits).rawValue
    mergedTraits[.weight] = weight
    var result = NSFont(descriptor: descriptor.addingAttributes([.traits: mergedTraits]), size: baseFont.pointSize) ?? base
    if traits.contains(.italic), !result.fontDescriptor.symbolicTraits.contains(.italic) {
      result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask)
    }
    return result
    #else
    let supported: UIFontDescriptor.SymbolicTraits = [
      .traitBold, .traitItalic, .traitMonoSpace, .traitCondensed, .traitExpanded,
    ]
    let traits = font.fontDescriptor.symbolicTraits.intersection(supported)
    guard !traits.isEmpty else { return baseFont }
    let baseTraits = baseFont.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
    let baseWeight: CGFloat = (baseTraits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) }
      ?? (isBold(baseFont) ? UIFont.Weight.bold.rawValue : UIFont.Weight.regular.rawValue)
    let weight = traits.contains(.traitBold) ? max(baseWeight, UIFont.Weight.bold.rawValue) : baseWeight
    let base: UIFont
    if traits.contains(.traitMonoSpace) {
      base = .monospacedSystemFont(ofSize: baseFont.pointSize, weight: .init(rawValue: weight))
    } else {
      base = baseFont
    }
    let descriptor = base.fontDescriptor
    var mergedTraits = (descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]) ?? [:]
    mergedTraits[.symbolic] = descriptor.symbolicTraits.union(traits).rawValue
    mergedTraits[.weight] = weight
    let result = UIFont(descriptor: descriptor.addingAttributes([.traits: mergedTraits]), size: baseFont.pointSize)
    let wantedTraits = descriptor.symbolicTraits.union(traits)
    if !result.fontDescriptor.symbolicTraits.isSuperset(of: wantedTraits),
       let fallback = result.fontDescriptor.withSymbolicTraits(wantedTraits)
    {
      return UIFont(descriptor: fallback, size: baseFont.pointSize)
    }
    return result
    #endif
  }

  public static func isBold(_ font: PlatformFont) -> Bool {
    #if os(macOS)
    NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    #else
    font.fontDescriptor.symbolicTraits.contains(.traitBold)
    #endif
  }

  public static func settingBold(
    _ wantsBold: Bool,
    on font: PlatformFont,
    preferredWeight: PlatformFontWeight? = nil
  ) -> PlatformFont {
    #if os(macOS)
    if wantsBold, let preferredWeight, let weightedFont = fontWith(weight: preferredWeight, bold: true, from: font) {
      return weightedFont
    }

    let converted: PlatformFont? = if wantsBold {
      NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) as PlatformFont?
    } else {
      NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask) as PlatformFont?
    }

    if let converted, isBold(converted) == wantsBold {
      return converted
    }

    var symbolicTraits = font.fontDescriptor.symbolicTraits
    if wantsBold {
      symbolicTraits.insert(.bold)
    } else {
      symbolicTraits.remove(.bold)
    }

    if let descriptorFont = NSFont(
      descriptor: font.fontDescriptor.withSymbolicTraits(symbolicTraits),
      size: font.pointSize
    ) {
      return descriptorFont
    }

    let safeSize = max(font.pointSize, 12.0)
    if wantsBold {
      return NSFont.boldSystemFont(ofSize: safeSize)
    }

    return NSFont.systemFont(ofSize: safeSize)
    #else
    if wantsBold, let preferredWeight, let weightedFont = fontWith(weight: preferredWeight, bold: true, from: font) {
      return weightedFont
    }

    var symbolicTraits = font.fontDescriptor.symbolicTraits
    if wantsBold {
      symbolicTraits.insert(.traitBold)
    } else {
      symbolicTraits.remove(.traitBold)
    }

    if let descriptor = font.fontDescriptor.withSymbolicTraits(symbolicTraits) {
      return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    let safeSize = max(font.pointSize, 12.0)
    if wantsBold {
      return UIFont.boldSystemFont(ofSize: safeSize)
    }

    return UIFont.systemFont(ofSize: safeSize)
    #endif
  }

  #if os(macOS)
  private static func fontWith(weight: PlatformFontWeight, bold: Bool, from font: PlatformFont) -> PlatformFont? {
    var symbolicTraits = font.fontDescriptor.symbolicTraits
    if bold {
      symbolicTraits.insert(.bold)
    } else {
      symbolicTraits.remove(.bold)
    }

    let descriptor = font.fontDescriptor.withSymbolicTraits(symbolicTraits)
    var traits = (descriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]) ?? [:]
    traits[.weight] = weight.rawValue
    let weightedDescriptor = descriptor.addingAttributes([.traits: traits])

    if let weightedFont = NSFont(descriptor: weightedDescriptor, size: font.pointSize) {
      return weightedFont
    }

    let safeSize = max(font.pointSize, 12.0)
    if NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask) {
      return NSFont.monospacedSystemFont(ofSize: safeSize, weight: weight)
    }

    return NSFont.systemFont(ofSize: safeSize, weight: weight)
  }
  #else
  private static func fontWith(weight: PlatformFontWeight, bold: Bool, from font: PlatformFont) -> PlatformFont? {
    var symbolicTraits = font.fontDescriptor.symbolicTraits
    if bold {
      symbolicTraits.insert(.traitBold)
    } else {
      symbolicTraits.remove(.traitBold)
    }

    guard let descriptorWithTraits = font.fontDescriptor.withSymbolicTraits(symbolicTraits) else {
      return nil
    }

    var traits = (descriptorWithTraits.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]) ?? [:]
    traits[.weight] = weight.rawValue
    let weightedDescriptor = descriptorWithTraits.addingAttributes([.traits: traits])

    return UIFont(descriptor: weightedDescriptor, size: font.pointSize)
  }
  #endif
}
