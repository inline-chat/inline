import Foundation

public enum RichMediaURLPolicy {
  public static func safeRemoteMediaURL(from value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let url = URL(string: trimmed),
          url.scheme?.lowercased() == "https",
          url.user == nil,
          url.password == nil,
          let host = url.host?.lowercased(),
          !host.isEmpty,
          !isBlockedHost(host)
    else { return nil }
    return url
  }

  private static func isBlockedHost(_ host: String) -> Bool {
    let normalized = host
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .lowercased()
    if normalized == "localhost" ||
      normalized == "::1" ||
      normalized == "0.0.0.0" ||
      normalized.hasSuffix(".local")
    {
      return true
    }

    let octets = normalized.split(separator: ".").compactMap { value -> Int? in
      guard let octet = Int(value), (0...255).contains(octet) else { return nil }
      return octet
    }
    guard octets.count == 4 else { return false }

    switch (octets[0], octets[1]) {
    case (0, _), (10, _), (127, _), (169, 254), (172, 16...31), (192, 168), (100, 64...127), (198, 18...19):
      return true
    default:
      return false
    }
  }
}
