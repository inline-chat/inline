import Foundation

public extension Character {
   var isEmoji: Bool {
    // Check if it's a single emoji presentation character
    if unicodeScalars.count == 1, let scalar = unicodeScalars.first {
      return scalar.properties.isEmojiPresentation
    }
    
    // For multi-scalar characters, check if any scalar has emoji modifier or presentation
    // This handles cases like 1️⃣ (digit + variation selector + combining enclosing keycap)
    let hasEmojiModifier = unicodeScalars.contains { scalar in
      scalar.properties.isEmojiModifier || 
      scalar.properties.isEmojiModifierBase ||
      scalar.value == 0xFE0F || // VARIATION SELECTOR-16 (emoji presentation)
      scalar.value == 0x20E3    // COMBINING ENCLOSING KEYCAP
    }
    
    let hasEmojiPresentation = unicodeScalars.contains { scalar in
      scalar.properties.isEmojiPresentation
    }
    
    // Must have either emoji presentation or emoji modifiers, but exclude plain ASCII
    return (hasEmojiPresentation || hasEmojiModifier) 
  }
}

public extension String {
  var isAllEmojis: Bool {
    !isEmpty && allSatisfy { character in
      character.isEmoji
    }
  }

  var emojiInfo: (count: Int, isAllEmojis: Bool) {
    guard !isEmpty else { return (0, false) }

    var emojiCount = 0
    let totalCount = count

    for character in self {
      if character.isEmoji {
        emojiCount += 1
      }
    }

    return (emojiCount, emojiCount == totalCount)
  }
}
