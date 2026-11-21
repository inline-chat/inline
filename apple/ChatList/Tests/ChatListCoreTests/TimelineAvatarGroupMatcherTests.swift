@testable import ChatListCore
import Testing

struct TimelineAvatarGroupMatcherTests {
  private func group(_ ids: [Int], owner: Int, author: Int64 = 1) -> TimelineAvatarGroup<Int> {
    .init(memberIDs: ids, ownerID: owner, authorID: author)
  }

  @Test func `bubble merge keeps the group containing the new last owner`() {
    let old = [
      group([1, 2], owner: 2),
      group([3], owner: 3, author: 2),
      group([4, 5], owner: 5),
    ]
    let new = [group([1, 2, 4, 5], owner: 5)]
    #expect(TimelineAvatarGroupMatcher.matches(old: old, new: new) == [0: 2])
  }

  @Test func `minimal merge keeps the group containing the new first owner`() {
    let old = [group([1, 2], owner: 1), group([3], owner: 3, author: 2), group([4, 5], owner: 4)]
    let new = [group([1, 2, 4, 5], owner: 1)]
    #expect(TimelineAvatarGroupMatcher.matches(old: old, new: new) == [0: 0])
  }

  @Test func `bubble split carries the old avatar to its last owner child`() {
    let old = [group([1, 2, 3, 4], owner: 4)]
    let new = [group([1, 2], owner: 2), group([3, 4], owner: 4)]
    #expect(TimelineAvatarGroupMatcher.matches(old: old, new: new) == [1: 0])
  }

  @Test func `minimal split carries the old avatar to its first owner child`() {
    let old = [group([1, 2, 3, 4], owner: 1)]
    let new = [group([1, 2], owner: 1), group([3, 4], owner: 3)]
    #expect(TimelineAvatarGroupMatcher.matches(old: old, new: new) == [0: 0])
  }

  @Test func `changed author does not reuse an old avatar`() {
    let old = [group([1, 2], owner: 2)]
    let new = [group([1, 2], owner: 2, author: 3)]
    #expect(TimelineAvatarGroupMatcher.matches(old: old, new: new).isEmpty)
  }
}
