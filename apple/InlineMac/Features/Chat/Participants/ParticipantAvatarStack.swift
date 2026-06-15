import InlineKit
import InlineUI
import SwiftUI

public struct ParticipantAvatarStack: View {
  let participants: [UserInfo]
  private let avatarSize: CGFloat
  private let overlap: CGFloat
  private let horizontalPadding: CGFloat

  public init(
    participants: [UserInfo],
    avatarSize: CGFloat = 24,
    overlap: CGFloat = 6,
    horizontalPadding: CGFloat = 8
  ) {
    self.participants = participants
    self.avatarSize = avatarSize
    self.overlap = overlap
    self.horizontalPadding = horizontalPadding
  }

  private var overflowCount: Int {
    // This will be used if we need to show +N indicator in the future
    max(0, participants.count - 3)
  }

  public var body: some View {
    HStack(spacing: -overlap) {
      ForEach(Array(participants.enumerated()), id: \.element.id) { index, participant in
        UserAvatar(
          user: participant.user,
          size: avatarSize
        )
        .clipShape(Circle())
        .overlay(
          Circle()
            .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 0.5)
        .zIndex(Double(participants.count - index))
      }
    }
    .padding(.horizontal, horizontalPadding)
  }
}
