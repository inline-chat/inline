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
    VStack(spacing: 16) {
      Spacer()

      Image(systemName: "tray.fill")
        .font(.system(size: 48, weight: .light))
        .foregroundColor(.secondary)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.8)
        .animation(.spring(response: 0.3, dampingFraction: 0.8).delay(0.1), value: isVisible)

      Text("No archived chats")
        .font(.title2)
        .fontWeight(.medium)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 20)
        .animation(.easeOut(duration: 0.25).delay(0.15), value: isVisible)

      Text("Archived conversations will appear here")
        .font(.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 20)
        .animation(.easeOut(duration: 0.25).delay(0.2), value: isVisible)

      Spacer()
    }
    .padding(.horizontal, 40)
  }

  @ViewBuilder
  private var mainEmptyState: some View {
    VStack(spacing: 20) {
      Spacer()

      // Icon with subtle animation
      Image(systemName: isArchived ? "tray.fill" : "bubble.left.and.bubble.right.fill")
        .font(.system(size: 56, weight: .light))
        .foregroundColor(.secondary)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.8)
        .animation(.spring(response: 0.3, dampingFraction: 0.8).delay(0.1), value: isVisible)

      VStack(spacing: 12) {
        Text("No Chats Yet")
          .font(.title2)
          .fontWeight(.semibold)
          .opacity(isVisible ? 1 : 0)
          .offset(y: isVisible ? 0 : 20)
          .animation(.easeOut(duration: 0.25).delay(0.15), value: isVisible)

        Text("Message someone or create a space for your team")
          .font(.subheadline)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .opacity(isVisible ? 1 : 0)
          .offset(y: isVisible ? 0 : 20)
          .animation(.easeOut(duration: 0.25).delay(0.2), value: isVisible)
      }

      // Action buttons
      HStack(spacing: 8) {
        // Message dena button
        Button(action: {
          navigateToUser(getDenaOrMoUserId(username: "dena"))
        }) {
          Text("Message @dena")
            .font(.callout)
            .fontWeight(.medium)
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(ScaleButtonStyle())

        // Message mo button
        Button(action: {
          navigateToUser(getDenaOrMoUserId(username: "mo"))
        }) {
          Text("Message @mo")
            .font(.callout)
            .fontWeight(.medium)
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(ScaleButtonStyle())
      }
      .opacity(isVisible ? 1 : 0)
      .offset(y: isVisible ? 0 : 30)
      .animation(.easeOut(duration: 0.3).delay(0.25), value: isVisible)

      Spacer()
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
