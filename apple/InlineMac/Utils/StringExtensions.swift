import Foundation

extension String {
  var isRTL: Bool {
    guard let firstChar = first else { return false }
    let earlyRTL = firstChar.unicodeScalars.first?.properties.generalCategory == .otherLetter &&
      firstChar.unicodeScalars.first != nil &&
      firstChar.unicodeScalars.first!.value >= 0x0590 &&
      firstChar.unicodeScalars.first!.value <= 0x08FF

    if earlyRTL { return true }

    let language = CFStringTokenizerCopyBestStringLanguage(self as CFString, CFRange(location: 0, length: count))
    if let language {
      return NSLocale.characterDirection(forLanguage: language as String) == .rightToLeft
    }
    return false
  }
}
