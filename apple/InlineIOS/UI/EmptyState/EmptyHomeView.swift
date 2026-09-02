import InlineKit
import SwiftUI

struct EmptyHomeView: View {
  @EnvironmentObject private var nav: Navigation
  var body: some View {
    VStack(spacing: 8) {
      Text("🫙")
        .font(.largeTitle)
      Text("No chats or spaces yet")
        .font(.title3)
      VStack(spacing: 4) {
        ZStack {
          Text("Please search a username or start a new chat or message                               , or create a new space by clicking the + button")
            .font(.subheadline)
            .foregroundColor(.secondary)

            .multilineTextAlignment(.center)
            .overlay(alignment: .center) {
              HStack(spacing: 4) {
                Text("@dena")
                  .foregroundStyle(Color.accentColor)
                  .onTapGesture {
                    navigateToUser(getDenaOrMoUserId(username: "dena"))
                  }

                Text("or")
                  .font(.subheadline)
                  .foregroundColor(.secondary)

                Text("@mo")
                  .foregroundStyle(Color.accentColor)
                  .onTapGesture {
                    navigateToUser(getDenaOrMoUserId(username: "mo"))
                  }
              }
              .fixedSize()

              .padding(.trailing, 28)
            }
        }
      }
      .frame(width: 320)
    }
  }

  private func navigateToUser(_ userId: Int64) {
    nav.push(.chat(peer: .user(id: userId)))
  }
}
