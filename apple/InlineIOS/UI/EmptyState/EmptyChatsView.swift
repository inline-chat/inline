import InlineKit
import Logger
import SwiftUI

struct EmptyChatsView: View {
  let isArchived: Bool

  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var dataManager: DataManager
  @State private var isVisible = false

  var body: some View {
    VStack(spacing: 0) {
      if isArchived {
        archivedEmptyState
      } else {
        mainEmptyState
      }
    }
    .onAppear {
      withAnimation(.easeOut(duration: 0.3).delay(0.05)) {
        isVisible = true
      }
    }
  }

  @ViewBuilder
  private var archivedEmptyState: some View {
    VStack(spacing: 8) {
      Spacer()

      Text("No Archived Chats Yet")
        .font(.title2)
        .fontWeight(.medium)
        .themedPrimaryText()
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 20)
        .animation(.easeOut(duration: 0.25).delay(0.15), value: isVisible)

      Text("Your archived chats will appear here")
        .font(.subheadline)
        .themedSecondaryText()
        .multilineTextAlignment(.center)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 20)
        .animation(.easeOut(duration: 0.25).delay(0.2), value: isVisible)

      Spacer()
    }
    .padding(.horizontal, 60)
  }

  @ViewBuilder
  private var mainEmptyState: some View {
    VStack(spacing: 20) {
      Spacer()

      VStack(spacing: 8) {
        Text("Start a chat")
          .font(.title2)
          .fontWeight(.semibold)
          .themedPrimaryText()
          .opacity(isVisible ? 1 : 0)
          .offset(y: isVisible ? 0 : 20)
          .animation(.easeOut(duration: 0.25).delay(0.15), value: isVisible)

        Text("Please search for a username to start a DM or create a space.")
          .font(.subheadline)
          .themedSecondaryText()
          .multilineTextAlignment(.center)
          .opacity(isVisible ? 1 : 0)
          .offset(y: isVisible ? 0 : 20)
          .animation(.easeOut(duration: 0.25).delay(0.2), value: isVisible)
      }

      Spacer()
    }
    .padding(.horizontal, 60)
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
