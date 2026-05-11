import InlineKit
import RealtimeV2

@MainActor
enum NewThreadAction {
  static func start(dependencies: AppDependencies, spaceId: Int64?, title: String = "") {
    ToastCenter.shared.showLoading("Creating thread")

    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTitle = trimmedTitle.isEmpty ? "" : trimmedTitle

    Task {
      guard let currentUserId = dependencies.auth.currentUserId else {
        await MainActor.run {
          ToastCenter.shared.dismiss()
          ToastCenter.shared.showError("You're signed out. Please log in again.")
        }
        return
      }

      do {
        let chatId = try await dependencies.realtimeV2.createThreadLocally(
          title: resolvedTitle,
          emoji: nil,
          isPublic: false,
          spaceId: spaceId,
          participants: [currentUserId]
        )

        await MainActor.run {
          ToastCenter.shared.dismiss()
          dependencies.requestOpenChat(peer: .thread(id: chatId))
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
