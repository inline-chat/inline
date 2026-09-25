import InlineKit
import InlineUI
import SwiftUI

struct MemberItemRow: View {
  @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 14
  let member: FullMemberItem
  let hasUnread: Bool
  @Environment(Router.self) private var router

  var body: some View {
    HStack(spacing: 5) {
      Button {
        router.openPrimaryDestination(.chat(peer: .user(id: member.userInfo.user.id)))
      } label: {
        HStack(alignment: .center, spacing: 0) {
          HStack(alignment: .center, spacing: 5) {
            Circle()
              .fill(hasUnread ? Color.accentColor : .clear)
              .scaledFrame(width: 6, height: 6)
              .animation(.easeInOut(duration: 0.3), value: hasUnread)
            UserAvatar(user: member.userInfo.user, size: 32)
          }
          Text(member.userInfo.user.displayName)
            .font(.body)
            .padding(.leading, 8)
        }
      }
      .buttonStyle(.plain)

      SpaceMemberBadge(userID: member.userInfo.user.id, spaceID: member.member.spaceId, size: badgeSize)
        .id("\(member.userInfo.user.id):\(member.member.spaceId)")
    }
    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
  }
}
