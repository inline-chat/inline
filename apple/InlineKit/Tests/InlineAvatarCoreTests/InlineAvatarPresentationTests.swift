import Testing

@testable import InlineAvatarCore

@Suite("Inline avatar presentation")
struct InlineAvatarPresentationTests {
  @Test("resolves the SwiftUI name seed and one-character initials")
  func resolvesNamedUser() {
    let presentation = InlineAvatarPresentation.user(identity: .init(
      firstName: "Ada",
      lastName: "Lovelace",
      displayName: "Ada L.",
      email: "ada@example.com",
      username: "ada",
      stableIdentifier: "user:1"
    ))

    #expect(presentation.seed == "Ada Lovelace")
    #expect(presentation.initials == "A")
    #expect(presentation.showsPersonSymbol == false)
    #expect(presentation.style.paletteIndex == InlineAvatarStyle.paletteIndex(for: "Ada Lovelace"))
  }

  @Test("uses the email local part when a first name is absent")
  func resolvesEmailFallback() {
    let presentation = InlineAvatarPresentation.user(identity: .init(
      firstName: nil,
      lastName: nil,
      displayName: nil,
      email: "alex@example.com",
      username: nil,
      stableIdentifier: "user:2"
    ))

    #expect(presentation.seed == "alex")
    #expect(presentation.initials == "A")
  }

  @Test("uses a username when names and email are absent")
  func resolvesUsernameFallback() {
    let presentation = InlineAvatarPresentation.user(identity: .init(
      firstName: nil,
      lastName: nil,
      displayName: nil,
      email: nil,
      username: "@inline-user",
      stableIdentifier: "user:4"
    ))

    #expect(presentation.seed == "inline-user")
    #expect(presentation.initials == "I")
    #expect(presentation.showsPersonSymbol == false)
  }

  @Test("uses a generic person symbol only when identity text is absent")
  func resolvesGenericFallback() {
    let presentation = InlineAvatarPresentation.user(identity: .init(
      firstName: " ",
      lastName: nil,
      displayName: nil,
      email: nil,
      username: nil,
      stableIdentifier: "user:3"
    ))

    #expect(presentation.seed == "User")
    #expect(presentation.initials == nil)
    #expect(presentation.showsPersonSymbol)
  }

  @Test("returns two deterministic gradient stops and applies opacity")
  func resolvesGradient() {
    let style = InlineAvatarStyle.resolved(seed: "Stable Name", backgroundOpacity: 0.6)
    let baseColor = InlineAvatarStyle.palette[style.paletteIndex]

    #expect(style.gradientStops.count == 2)
    #expect(style.gradientStops[0].location == 0)
    #expect(style.gradientStops[0].color == baseColor.adjustingLuminosity(by: 0.2).withAlpha(0.6))
    #expect(style.gradientStops[1] == .init(color: baseColor.withAlpha(0.6), location: 1))
    #expect(style.foregroundColor == .white)
    #expect(style.borderColor.alpha == 0.06)
    #expect(style.borderWidth == 0.5)
  }

  @Test("maps UTF-8 input to a stable palette index")
  func resolvesPaletteIndex() {
    let seed = "محمد رجبی"
    let expected = seed.utf8.reduce(0) { $0 + Int($1) } % InlineAvatarStyle.palette.count

    #expect(InlineAvatarStyle.paletteIndex(for: seed) == expected)
    #expect(InlineAvatarStyle.paletteIndex(for: seed) == InlineAvatarStyle.paletteIndex(for: seed))
  }
}
