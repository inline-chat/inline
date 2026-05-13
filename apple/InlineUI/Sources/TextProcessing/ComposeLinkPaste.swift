import Foundation

public enum ComposeLinkPaste {
  public static func normalizedURLString(from text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let matches = LinkDetector.shared.detectLinks(in: trimmed)
    guard matches.count == 1, let match = matches.first else { return nil }

    let fullRange = NSRange(location: 0, length: (trimmed as NSString).length)
    guard NSEqualRanges(match.range, fullRange) else { return nil }
    guard let scheme = match.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return nil
    }

    return match.url.absoluteString
  }

  public static func normalizedURLString(from url: URL) -> String? {
    normalizedURLString(from: url.absoluteString)
  }
}
