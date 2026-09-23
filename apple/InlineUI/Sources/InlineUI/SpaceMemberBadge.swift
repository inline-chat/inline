import InlineKit
import SwiftUI

/// Contextual affiliation: only a full member of the current space gets its badge.
public struct SpaceMemberBadge: View {
  @StateObject private var model: SpaceMemberBadgeViewModel
  private let size: CGFloat

  public init(userID: Int64, spaceID: Int64, size: CGFloat = 14) {
    _model = StateObject(wrappedValue: SpaceMemberBadgeViewModel(db: .shared, userID: userID, spaceID: spaceID))
    self.size = size
  }

  public var body: some View {
    if let space = model.space {
      SpaceAvatar(space: space, size: size, cornerRadius: size * 0.22)
        .overlay {
          tileShape
            .strokeBorder(.black.opacity(0.16), lineWidth: 0.5)
        }
        .fixedSize()
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
        .help("Member of \(space.displayName)")
        .accessibilityLabel("Member of \(space.displayName)")
    }
  }

  private var tileShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
  }
}
