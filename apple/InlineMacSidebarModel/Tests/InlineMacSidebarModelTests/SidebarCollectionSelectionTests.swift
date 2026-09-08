@testable import InlineMacSidebarModel
import Testing

@Suite("Sidebar chat selection")
struct SidebarCollectionSelectionTests {
  @Test func commandClickTogglesWithoutLosingOtherChats() {
    var selection = SidebarCollectionSelection(selectedIDs: [1], anchorID: 1)
    selection.click(4, orderedIDs: [1, 2, 3, 4], command: true, shift: false)
    #expect(selection.selectedIDs == [1, 4])
    selection.click(1, orderedIDs: [1, 2, 3, 4], command: true, shift: false)
    #expect(selection.selectedIDs == [4])
    selection.click(4, orderedIDs: [1, 2, 3, 4], command: true, shift: false)
    #expect(selection.selectedIDs.isEmpty)
  }

  @Test func rangeCanShrinkReverseAndExtendAdditively() {
    var selection = SidebarCollectionSelection(selectedIDs: [3], anchorID: 3)
    let rows = [1, 2, 3, 4, 5]
    selection.click(5, orderedIDs: rows, command: false, shift: true)
    #expect(selection.selectedIDs == [3, 4, 5])
    selection.click(4, orderedIDs: rows, command: false, shift: true)
    #expect(selection.selectedIDs == [3, 4])
    selection.click(1, orderedIDs: rows, command: false, shift: true)
    #expect(selection.selectedIDs == [1, 2, 3])
    selection.click(5, orderedIDs: rows, command: true, shift: true)
    #expect(selection.selectedIDs == Set(rows))
    #expect(selection.anchorID == 3)
  }

  @Test func hiddenChatsArePrunedAndRangesFollowCurrentVisibleOrder() {
    var selection = SidebarCollectionSelection(selectedIDs: [1, 3], anchorID: 3)
    selection.retainVisible([4, 1, 2])
    #expect(selection.selectedIDs == [1])
    #expect(selection.anchorID == 1)
    selection.click(4, orderedIDs: [4, 1, 2], command: false, shift: true)
    #expect(selection.selectedIDs == [4, 1])
    selection.click(2, orderedIDs: [4, 1, 2], command: false, shift: false)
    #expect(selection.selectedIDs == [2])
  }
}
