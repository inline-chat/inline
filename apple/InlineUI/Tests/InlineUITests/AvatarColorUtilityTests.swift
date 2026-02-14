import Testing

@testable import InlineUI

@MainActor
@Suite("Avatar color utility")
struct AvatarColorUtilityTests {
  @Test("formats name using first and last name when available")
  func formatsFullName() {
    let formatted = AvatarColorUtility.formatNameForHashing(
      firstName: "Taylor",
      lastName: "Otwell",
      email: "taylor@example.com"
    )

    #expect(formatted == "Taylor Otwell")
  }

  @Test("falls back to email local part when first name is missing")
  func fallsBackToEmailLocalPart() {
    let formatted = AvatarColorUtility.formatNameForHashing(
      firstName: nil,
      lastName: nil,
      email: "alex@example.com"
    )

    #expect(formatted == "alex")
  }

  @Test("falls back to User when no inputs are provided")
  func fallsBackToDefaultName() {
    let formatted = AvatarColorUtility.formatNameForHashing(
      firstName: nil,
      lastName: nil,
      email: nil
    )

    #expect(formatted == "User")
  }

  @Test("maps names to palette index using UTF-8 sum modulo")
  func mapsNameToExpectedPaletteEntry() {
    let name = "Alice Johnson"
    let paletteCount = 12
    let expectedIndex = abs(name.utf8.reduce(0) { $0 + Int($1) }) % paletteCount
    let actualIndex = AvatarColorUtility.paletteIndex(for: name, paletteCount: paletteCount)

    #expect(actualIndex == expectedIndex)
  }

  @Test("returns a stable color for the same name")
  func returnsStableColorForSameName() {
    let name = "Stable Name"
    let paletteCount = 12
    let first = AvatarColorUtility.paletteIndex(for: name, paletteCount: paletteCount)
    let second = AvatarColorUtility.paletteIndex(for: name, paletteCount: paletteCount)

    #expect(first == second)
  }
}
