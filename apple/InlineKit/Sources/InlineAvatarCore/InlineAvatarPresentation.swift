import Foundation

public struct InlineAvatarColor: Sendable, Hashable {
  public let red: Double
  public let green: Double
  public let blue: Double
  public let alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = Self.clamped(red)
    self.green = Self.clamped(green)
    self.blue = Self.clamped(blue)
    self.alpha = Self.clamped(alpha)
  }

  public func withAlpha(_ alpha: Double) -> Self {
    Self(red: red, green: green, blue: blue, alpha: alpha)
  }

  public func adjustingLuminosity(by amount: Double) -> Self {
    let maximum = max(red, green, blue)
    let minimum = min(red, green, blue)
    let delta = maximum - minimum

    var hue = 0.0
    var saturation = 0.0
    var lightness = (maximum + minimum) / 2

    if delta != 0 {
      saturation = lightness < 0.5
        ? delta / (maximum + minimum)
        : delta / (2 - maximum - minimum)

      if maximum == red {
        hue = (green - blue) / delta + (green < blue ? 6 : 0)
      } else if maximum == green {
        hue = (blue - red) / delta + 2
      } else {
        hue = (red - green) / delta + 4
      }
      hue /= 6
    }

    lightness = Self.clamped(lightness + amount)
    guard saturation != 0 else {
      return Self(red: lightness, green: lightness, blue: lightness, alpha: alpha)
    }

    let q = lightness < 0.5
      ? lightness * (1 + saturation)
      : lightness + saturation - lightness * saturation
    let p = 2 * lightness - q

    return Self(
      red: Self.hueComponent(p: p, q: q, value: hue + 1 / 3),
      green: Self.hueComponent(p: p, q: q, value: hue),
      blue: Self.hueComponent(p: p, q: q, value: hue - 1 / 3),
      alpha: alpha
    )
  }

  public static let white = Self(red: 1, green: 1, blue: 1)

  private static func hueComponent(p: Double, q: Double, value: Double) -> Double {
    var value = value
    if value < 0 { value += 1 }
    if value > 1 { value -= 1 }
    if value < 1 / 6 { return p + (q - p) * 6 * value }
    if value < 1 / 2 { return q }
    if value < 2 / 3 { return p + (q - p) * (2 / 3 - value) * 6 }
    return p
  }

  private static func clamped(_ value: Double) -> Double {
    min(max(value, 0), 1)
  }
}

public struct InlineAvatarGradientStop: Sendable, Hashable {
  public let color: InlineAvatarColor
  public let location: Double

  public init(color: InlineAvatarColor, location: Double) {
    self.color = color
    self.location = min(max(location, 0), 1)
  }
}

public struct InlineAvatarStyle: Sendable, Hashable {
  public let paletteIndex: Int
  public let baseColor: InlineAvatarColor
  public let gradientStops: [InlineAvatarGradientStop]
  public let foregroundColor: InlineAvatarColor
  public let borderColor: InlineAvatarColor
  public let borderWidth: Double

  public static let palette: [InlineAvatarColor] = [
    .init(red: 0.86, green: 0.15, blue: 0.47),
    .init(red: 1.00, green: 0.58, blue: 0.00),
    .init(red: 0.54, green: 0.32, blue: 0.92),
    .init(red: 0.86, green: 0.64, blue: 0.02),
    .init(red: 0.00, green: 0.63, blue: 0.58),
    .init(red: 0.02, green: 0.48, blue: 1.00),
    .init(red: 0.00, green: 0.72, blue: 0.65),
    .init(red: 0.20, green: 0.68, blue: 0.30),
    .init(red: 0.92, green: 0.22, blue: 0.20),
    .init(red: 0.35, green: 0.34, blue: 0.84),
    .init(red: 0.12, green: 0.72, blue: 0.48),
    .init(red: 0.00, green: 0.68, blue: 0.86),
  ]

  public static func resolved(seed: String, backgroundOpacity: Double = 1) -> Self {
    let opacity = min(max(backgroundOpacity, 0), 1)
    let index = paletteIndex(for: seed)
    let baseColor = palette[index]

    return Self(
      paletteIndex: index,
      baseColor: baseColor,
      gradientStops: [
        .init(color: baseColor.adjustingLuminosity(by: 0.2).withAlpha(opacity), location: 0),
        .init(color: baseColor.withAlpha(opacity), location: 1),
      ],
      foregroundColor: .white,
      borderColor: baseColor.adjustingLuminosity(by: -0.4).withAlpha(0.1 * opacity),
      borderWidth: 0.5
    )
  }

  public static func paletteIndex(for seed: String, paletteCount: Int = palette.count) -> Int {
    guard paletteCount > 0 else { return 0 }
    return seed.utf8.reduce(0) { ($0 + Int($1)) % paletteCount }
  }
}

public struct InlineAvatarUserIdentity: Sendable, Hashable {
  public let firstName: String?
  public let lastName: String?
  public let displayName: String?
  public let email: String?
  public let username: String?
  public let stableIdentifier: String

  public init(
    firstName: String?,
    lastName: String?,
    displayName: String?,
    email: String?,
    username: String?,
    stableIdentifier: String
  ) {
    self.firstName = firstName
    self.lastName = lastName
    self.displayName = displayName
    self.email = email
    self.username = username
    self.stableIdentifier = stableIdentifier
  }
}

public struct InlineUserAvatarPresentation: Sendable, Hashable {
  public let seed: String
  public let initials: String?
  public let showsPersonSymbol: Bool
  public let style: InlineAvatarStyle
}

public enum InlineAvatarPresentation {
  public static func user(
    identity: InlineAvatarUserIdentity,
    backgroundOpacity: Double = 1
  ) -> InlineUserAvatarPresentation {
    let normalizedValues = [
      identity.firstName,
      identity.lastName,
      identity.displayName,
      identity.email,
      identity.username,
    ].compactMap(normalized)
    let showsPersonSymbol = normalizedValues.isEmpty
    let seed = userSeed(identity: identity)
    let initials = showsPersonSymbol ? nil : seed.first.map { String($0).uppercased() }

    return InlineUserAvatarPresentation(
      seed: seed,
      initials: initials,
      showsPersonSymbol: showsPersonSymbol,
      style: .resolved(seed: seed, backgroundOpacity: backgroundOpacity)
    )
  }

  public static func nameSeed(firstName: String?, lastName: String?, email: String?) -> String {
    let resolvedFirstName = normalized(firstName) ?? emailLocalPart(email) ?? "User"
    guard let lastName = normalized(lastName) else { return resolvedFirstName }
    return "\(resolvedFirstName) \(lastName)"
  }

  private static func userSeed(identity: InlineAvatarUserIdentity) -> String {
    if normalized(identity.firstName) != nil ||
      normalized(identity.lastName) != nil ||
      emailLocalPart(identity.email) != nil {
      return nameSeed(
        firstName: identity.firstName,
        lastName: identity.lastName,
        email: identity.email
      )
    }
    if let displayName = normalized(identity.displayName) { return displayName }
    if let username = normalizedUsername(identity.username) { return username }
    return "User"
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func normalizedUsername(_ value: String?) -> String? {
    normalized(value)?
      .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
      .nilIfEmpty
  }

  private static func emailLocalPart(_ value: String?) -> String? {
    guard let email = normalized(value) else { return nil }
    return email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
      .first
      .map(String.init)?
      .nilIfEmpty
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
