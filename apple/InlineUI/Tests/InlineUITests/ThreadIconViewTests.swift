import Testing

@testable import InlineUI

@Suite("Thread icon view")
struct ThreadIconViewTests {
  @Test("normalizes empty emoji values to nil")
  func normalizesEmptyEmojiValues() {
    #expect(ThreadIconDescriptor.normalizedEmoji(nil) == nil)
    #expect(ThreadIconDescriptor.normalizedEmoji("") == nil)
    #expect(ThreadIconDescriptor.normalizedEmoji(" \n\t ") == nil)
  }

  @Test("uses the first extended grapheme cluster")
  func usesFirstExtendedGraphemeCluster() {
    #expect(ThreadIconDescriptor.normalizedEmoji(" 🚀🎯 ") == "🚀")
    #expect(ThreadIconDescriptor.normalizedEmoji("👨‍👩‍👧‍👦x") == "👨‍👩‍👧‍👦")
  }

  @Test("stores normalized emoji on descriptor")
  func descriptorStoresNormalizedEmoji() {
    let descriptor = ThreadIconDescriptor(emoji: " 🧠🤖 ", title: "AI")

    #expect(descriptor.emoji == "🧠")
    #expect(descriptor.title == "AI")
  }

  @Test("shared fallback defaults resolve to thread symbols")
  func sharedFallbackDefaultsResolveToThreadSymbols() {
    #expect(ThreadIconDefaults.fallbackSymbolName(isReplyThread: false) == "bubble.middle.bottom.fill")
    #expect(ThreadIconDefaults.fallbackSymbolName(isReplyThread: true) == "arrow.turn.down.right")
  }

  @Test("semantic sizes resolve to shared point sizes")
  func semanticSizesResolveToSharedPointSizes() {
    #expect(ThreadIconSize.compact(20).points == 20)
    #expect(ThreadIconSize.regular(32).points == 32)
    #expect(ThreadIconSize.large(56).points == 56)
    #expect(ThreadIconSize.regular(44).points == 44)
  }

  @MainActor
  @Test("view equality includes size shape symbol color and background")
  func viewEqualityIncludesSizeShapeSymbolColorAndBackground() {
    let descriptor = ThreadIconDescriptor(emoji: nil, title: "Thread")
    let first = ThreadIconView(descriptor, size: .regular(32), shape: .circle, symbolColor: .secondary)
    let second = ThreadIconView(descriptor, size: .regular(32), shape: .circle, symbolColor: .secondary)
    let different = ThreadIconView(
      descriptor,
      size: .regular(32),
      shape: .circle,
      symbolColor: .secondary,
      background: .solid
    )

    #expect(first == second)
    #expect(first != different)
  }
}
