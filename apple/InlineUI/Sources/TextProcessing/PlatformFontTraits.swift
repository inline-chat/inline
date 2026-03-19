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
