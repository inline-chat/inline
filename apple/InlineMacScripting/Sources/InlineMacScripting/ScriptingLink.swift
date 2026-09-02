import Foundation

/// A single link carries the name and URL from the same selection snapshot.
public enum ScriptingLink {
  public static func markdown(title: String, url: URL) -> String {
    var label = ""
    for character in title {
      if character.isNewline {
        label.append(" ")
        continue
      }
      if character.unicodeScalars.count == 1, let value = character.unicodeScalars.first?.value,
         (33...47).contains(value) || (58...64).contains(value)
           || (91...96).contains(value) || (123...126).contains(value) {
        label.append("\\")
      }
      label.append(character)
    }
    // Inline chat URLs contain a configured scheme and a positive decimal ID.
    return "[\(label)](\(url.absoluteString))"
  }
}
