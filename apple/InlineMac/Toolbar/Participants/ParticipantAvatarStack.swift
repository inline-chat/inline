import InlineKit
import InlineUI
import SwiftUI

public struct ParticipantAvatarStack: View {
  let participants: [UserInfo]
  private let avatarSize: CGFloat = 24
  private let overlap: CGFloat = 6
  
  public init(participants: [UserInfo]) {
    self.participants = participants
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
    .padding(.horizontal, 8)
  }
}