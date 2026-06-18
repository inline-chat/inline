import Testing

@testable import InlineUI

@Suite("MessageSelectionState")
struct MessageSelectionStateTests {
  @Test("begin activates selection with one anchored message")
  func beginActivatesSelection() {
    var state = MessageSelectionState()

    let changed = state.begin(with: 42)

    #expect(state.isActive)
    #expect(state.count == 1)
    #expect(state.isSelected(42))
    #expect(state.anchorStableId == 42)
    #expect(changed == Set([42]))
  }

  @Test("toggle adds and removes messages while keeping a valid anchor")
  func toggleUpdatesSelectionAndAnchor() {
    var state = MessageSelectionState()
    let orderedIds: [Int64] = [1, 2, 3]

    #expect(state.toggle(2, orderedIds: orderedIds) == Set([2]))
    #expect(state.anchorStableId == 2)
    #expect(state.selectedStableIds == Set([2]))

    #expect(state.toggle(3, orderedIds: orderedIds) == Set([3]))
    #expect(state.anchorStableId == 2)
    #expect(state.selectedStableIds == Set([2, 3]))

    #expect(state.toggle(2, orderedIds: orderedIds) == Set([2]))
    #expect(state.anchorStableId == 3)
    #expect(state.selectedStableIds == Set([3]))

    #expect(state.toggle(3, orderedIds: orderedIds) == Set([3]))
    #expect(!state.isActive)
    #expect(state.anchorStableId == nil)
    #expect(state.selectedStableIds.isEmpty)
  }

  @Test("range selection replaces selection between anchor and target")
  func rangeSelectionUsesAnchor() {
    var state = MessageSelectionState()
    let orderedIds: [Int64] = [1, 2, 3, 4, 5]

    state.begin(with: 2)

    #expect(state.selectRange(to: 5, orderedIds: orderedIds) == Set([3, 4, 5]))
    #expect(state.anchorStableId == 2)
    #expect(state.selectedStableIds == Set([2, 3, 4, 5]))

    #expect(state.selectRange(to: 1, orderedIds: orderedIds) == Set([1, 3, 4, 5]))
    #expect(state.anchorStableId == 2)
    #expect(state.selectedStableIds == Set([1, 2]))
  }

  @Test("range selection without a valid anchor falls back to the target")
  func rangeSelectionWithoutAnchorSelectsTarget() {
    var state = MessageSelectionState()

    let changed = state.selectRange(to: 3, orderedIds: [1, 2, 3, 4])

    #expect(state.isActive)
    #expect(state.anchorStableId == 3)
    #expect(state.selectedStableIds == Set([3]))
    #expect(changed == Set([3]))
  }

  @Test("select all follows the current loaded order and clears on empty input")
  func selectAllUsesLoadedIds() {
    var state = MessageSelectionState()

    state.begin(with: 3)
    #expect(state.selectAll([1, 2, 3]) == Set([1, 2]))
    #expect(state.anchorStableId == 3)
    #expect(state.selectedStableIds == Set([1, 2, 3]))

    #expect(state.selectAll([]) == Set([1, 2, 3]))
    #expect(!state.isActive)
    #expect(state.anchorStableId == nil)
    #expect(state.selectedStableIds.isEmpty)
  }

  @Test("prune removes unloaded messages and repairs the anchor")
  func pruneRemovesInvalidIds() {
    var state = MessageSelectionState()
    let orderedIds: [Int64] = [1, 2, 3, 4]

    state.selectAll(orderedIds)

    #expect(state.prune(validIds: Set([2, 4]), orderedIds: orderedIds) == Set([1, 3]))
    #expect(state.isActive)
    #expect(state.anchorStableId == 2)
    #expect(state.selectedStableIds == Set([2, 4]))

    #expect(state.prune(validIds: [], orderedIds: orderedIds) == Set([2, 4]))
    #expect(!state.isActive)
    #expect(state.anchorStableId == nil)
    #expect(state.selectedStableIds.isEmpty)
  }

  @Test("ordered selection returns selected ids in caller supplied order")
  func orderedSelectionUsesInputOrder() {
    var state = MessageSelectionState()

    state.selectAll([3, 1, 2])

    #expect(state.orderedSelection(in: [1, 2, 3, 4]) == [1, 2, 3])
  }
}
