import CoreGraphics
import Testing

@testable import InlineIOSUI

@Suite("SuggestionListHeight")
struct SuggestionListHeightTests {
  @Test("returns zero height when there are no suggestions")
  func returnsZeroHeightWhenThereAreNoSuggestions() {
    #expect(
      suggestionListHeight(
        itemCount: 0,
        itemHeight: 56,
        maxVisibleItems: 4,
        maxHeight: 216
      ) == 0
    )
  }

  @Test("uses the exact row height while under the visible cap")
  func usesExactRowHeightWhileUnderVisibleCap() {
    #expect(
      suggestionListHeight(
        itemCount: 2,
        itemHeight: 56,
        maxVisibleItems: 4,
        maxHeight: 216
      ) == 112
    )
  }

  @Test("caps the suggestion list at the configured max height")
  func capsTheSuggestionListAtConfiguredMaxHeight() {
    #expect(
      suggestionListHeight(
        itemCount: 8,
        itemHeight: 56,
        maxVisibleItems: 4,
        maxHeight: 216
      ) == 216
    )
  }
}
