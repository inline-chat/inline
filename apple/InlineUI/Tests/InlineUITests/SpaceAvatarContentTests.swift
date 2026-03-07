import Foundation
import InlineKit
import Testing

@testable import InlineUI

@Suite("Space avatar content")
struct SpaceAvatarContentTests {
  @Test("uses the leading emoji when the space name starts with one")
  func usesLeadingEmoji() {
    let space = Space(id: 1, name: "🚀 Product", date: Date())

    #expect(SpaceAvatarContent.text(for: space) == "🚀")
  }

  @Test("falls back to the first letter of the display name")
  func usesDisplayNameInitial() {
    let space = Space(id: 2, name: "Design", date: Date())

    #expect(SpaceAvatarContent.text(for: space) == "D")
  }

  @Test("uses larger font scale for emoji content")
  func emojiFontScaleIsLarger() {
    #expect(SpaceAvatarContent.fontScale(for: "🚀") == 0.6)
    #expect(SpaceAvatarContent.fontScale(for: "D") == 0.55)
  }
}
