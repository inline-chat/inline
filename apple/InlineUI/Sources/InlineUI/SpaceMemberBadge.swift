import InlineKit
import SwiftUI

/// A Pro space's photo next to a member's name. With a space in context, only a full member of
/// that space gets its badge; without one, the space the user represents (X-style affiliation).
public struct SpaceMemberBadge: View {
  @StateObject private var model: SpaceMemberBadgeViewModel
  private let size: CGFloat

  public init(userID: Int64, spaceID: Int64?, size: CGFloat = 14) {
    _model = StateObject(wrappedValue: SpaceMemberBadgeViewModel(db: .shared, userID: userID, spaceID: spaceID))
    self.size = size
  }

  public var body: some View {
    if let space = model.space {
      SpaceBadgeTile(space: space, size: size)
        .badgeLabel("Member of \(space.displayName)")
        .accessibilityLabel("Member of \(space.displayName)")
    }
  }
}

/// A space's photo as a small rounded tile that sits on a name's baseline.
struct SpaceBadgeTile: View {
  let space: Space
  let size: CGFloat

  var body: some View {
    SpaceAvatar(space: space, size: size, cornerRadius: size * 0.22)
      .overlay {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
          .strokeBorder(.black.opacity(0.16), lineWidth: 0.5)
      }
      .fixedSize()
      .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
  }
}
