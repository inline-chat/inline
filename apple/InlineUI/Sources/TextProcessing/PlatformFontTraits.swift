import Foundation

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

public enum PlatformFontTraits {
  public static func isBold(_ font: PlatformFont) -> Bool {
    #if os(macOS)
    NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    #else
    font.fontDescriptor.symbolicTraits.contains(.traitBold)
    #endif
  }

  public static func settingBold(_ wantsBold: Bool, on font: PlatformFont) -> PlatformFont {
    #if os(macOS)
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
}
