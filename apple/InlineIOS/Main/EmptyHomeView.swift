import InlineKit
import Logger
import SwiftUI

struct EmptyHomeView: View {
  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var dataManager: DataManager
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
                  .foregroundStyle(ColorManager.shared.swiftUIColor)
                  .onTapGesture {
                    navigateToUser(getDenaOrMoUserId(username: "dena"))
                  }

                Text("or")
                  .font(.subheadline)
                  .foregroundColor(.secondary)

                Text("@mo")
                  .foregroundStyle(ColorManager.shared.swiftUIColor)
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
    Task {
      do {
        let peer = try await dataManager.createPrivateChat(userId: userId)
        nav.push(.chat(peer: peer))
      } catch {
        Log.shared.error("Failed to create chat", error: error)
      }
    }
  }
}
