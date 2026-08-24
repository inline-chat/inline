import Foundation

public enum EmailAddressValidator {
  private static let maximumUTF8Count = 254
  private static let maximumLocalPartUTF8Count = 64
  private static let maximumDomainUTF8Count = 253
  private static let maximumDomainLabelUTF8Count = 63
  private static let allowedLocalPartSpecialCharacters = Set("!#$%&'*+-/=?^_`{|}~")

  public static func isValid(_ email: String) -> Bool {
    guard !email.isEmpty,
          email.utf8.count <= maximumUTF8Count,
          !email.contains("\0"),
          !email.contains(where: \Character.isWhitespace)
    else { return false }

    let addressParts = email.split(separator: "@", omittingEmptySubsequences: false)
    guard addressParts.count == 2 else { return false }

    return isValidLocalPart(addressParts[0]) && isValidDomain(addressParts[1])
  }

  private static func isValidLocalPart(_ localPart: Substring) -> Bool {
    guard !localPart.isEmpty,
          localPart.utf8.count <= maximumLocalPartUTF8Count,
          localPart.first != ".",
          localPart.last != ".",
          !localPart.contains("..")
    else { return false }

    return localPart.allSatisfy { character in
      guard character.asciiValue != nil else { return false }
      return character.isLetter ||
        character.isNumber ||
        character == "." ||
        allowedLocalPartSpecialCharacters.contains(character)
    }
  }

  private static func isValidDomain(_ domain: Substring) -> Bool {
    guard !domain.isEmpty,
          domain.utf8.count <= maximumDomainUTF8Count
    else { return false }

    let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2,
          labels.allSatisfy(isValidDomainLabel),
          let topLevelDomain = labels.last
    else { return false }

    if topLevelDomain.lowercased().hasPrefix("xn--") {
      return topLevelDomain.count > 4
    }

    return topLevelDomain.count >= 2 && topLevelDomain.allSatisfy { character in
      character.asciiValue != nil && character.isLetter
    }
  }

  private static func isValidDomainLabel(_ label: Substring) -> Bool {
    guard !label.isEmpty,
          label.utf8.count <= maximumDomainLabelUTF8Count,
          label.first != "-",
          label.last != "-"
    else { return false }

    return label.allSatisfy { character in
      character.asciiValue != nil &&
        (character.isLetter || character.isNumber || character == "-")
    }
  }
}
