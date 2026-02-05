import InlineKit
import RealtimeV2

@MainActor
enum NewThreadAction {
  static func start(dependencies: AppDependencies, spaceId: Int64?) {
    ToastCenter.shared.showLoading("Creating thread")

    Task {
      guard let currentUserId = dependencies.auth.currentUserId else {
        await MainActor.run {
          ToastCenter.shared.dismiss()
          ToastCenter.shared.showError("You're signed out. Please log in again.")
        }
        return
      }

      do {
        let result = try await dependencies.realtimeV2.send(
          .createChat(
            title: "",
            emoji: nil,
            isPublic: false,
            spaceId: spaceId,
            participants: [currentUserId]
          )
        )

        await MainActor.run {
          ToastCenter.shared.dismiss()
          if case let .createChat(response) = result {
            dependencies.nav2?.navigate(to: .chat(peer: .thread(id: response.chat.id)))
          } else {
            ToastCenter.shared.showError("Failed to create thread.")
          }
        }
      } catch {
        await MainActor.run {
          ToastCenter.shared.dismiss()
          ToastCenter.shared.showError("Failed to create thread.")
        }
      }
    }
  }
}
