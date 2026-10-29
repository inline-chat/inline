import InlineProtocol
import Testing

@testable import InlineUI

@Suite("Grid room faces")
struct GridRoomFacesTests {
  @Test("a room that fits shows everyone")
  func roomThatFitsShowsEveryone() {
    let avatars = faces(count: 4)
    #expect(GridRoomFaces.visible(avatars, slots: 4).map(\.user.id) == [1, 2, 3, 4])
  }

  @Test("a full room keeps its size and leaves the last slot for +N")
  func fullRoomLeavesLastSlotForOverflow() {
    let visible = GridRoomFaces.visible(faces(count: 9), slots: 4)
    #expect(visible.map(\.user.id) == [1, 2, 3])
  }

  @Test("your face stays in view in a full room")
  func yourFaceStaysInView() {
    let visible = GridRoomFaces.visible(faces(count: 9, youAt: 8), slots: 4)
    #expect(visible.map(\.user.id) == [1, 2, 9])
    // A plain value: `#expect` can't decompose a call that takes a key path.
    let showsYou = visible.contains(where: \.ownedByCurrentSession)
    #expect(showsYou)
  }

  private func faces(count: Int, youAt: Int? = nil) -> [GridAvatar] {
    (0 ..< count).map { index in
      .with {
        $0.user = .with { $0.id = Int64(index + 1) }
        $0.ownedByCurrentSession = index == youAt
      }
    }
  }
}
