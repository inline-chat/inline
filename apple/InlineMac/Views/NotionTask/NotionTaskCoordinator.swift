import AppKit
import SwiftUI
import Auth
import InlineKit
import Logger

@MainActor
class NotionTaskCoordinator: ObservableObject {
  static let shared = NotionTaskCoordinator()

  @Published var isCreatingTask = false

  private init() {}

  func handleWillDo(message: Message, spaceId: Int64?, window: NSWindow) async {
    guard !isCreatingTask else { return }

    if message.peerId.isThread, let spaceId = spaceId {
      await createTask(message: message, spaceId: spaceId, window: window)
      return
    }

    do {
      let spaces = try await NotionTaskService.shared.getAvailableSpaces(for: message)

      if let selectedSpaceId = await selectSpace(from: spaces, window: window) {
        await createTask(message: message, spaceId: selectedSpaceId, window: window)
      }
    } catch {
      showErrorToast(error: error)
    }
  }

  private func selectSpace(from spaces: [NotionSpace], window: NSWindow) async -> Int64? {
    await withCheckedContinuation { continuation in
      let alert = NSAlert()
      alert.messageText = "Select Space"
      alert.informativeText = "Choose which space to create the Notion task in:"
      alert.alertStyle = .informational

      for space in spaces {
        alert.addButton(withTitle: space.spaceName)
      }
      alert.addButton(withTitle: "Cancel")

      alert.beginSheetModal(for: window) { response in
        let index = Int(response.rawValue) - 1000
        if index >= 0 && index < spaces.count {
          continuation.resume(returning: spaces[index].spaceId)
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  private func createTask(message: Message, spaceId: Int64, window: NSWindow) async {
    showLoadingToast()

    do {
      let url = try await NotionTaskService.shared.createTask(message: message, spaceId: spaceId)
      hideLoadingToast()
      showSuccessToast(url: url)
    } catch {
      hideLoadingToast()
      showErrorToast(error: error)
    }
  }

  private func showLoadingToast() {
    isCreatingTask = true
    ToastCenter.shared.showLoading("Creating Notion task…")
  }

  private func hideLoadingToast() {
    isCreatingTask = false
    ToastCenter.shared.dismiss()
  }

  private func showSuccessToast(url: String) {
    if let notionURL = URL(string: url) {
      ToastCenter.shared.showSuccess("Notion task created", actionTitle: "Open") {
        NSWorkspace.shared.open(notionURL)
      }
    } else {
      ToastCenter.shared.showSuccess("Notion task created")
    }
  }

  private func showErrorToast(error: Error) {
    ToastCenter.shared.showError("Failed to create Notion task")
  }
}

@MainActor
final class LinearIssueCoordinator: ObservableObject {
  static let shared = LinearIssueCoordinator()

  @Published private(set) var isCreatingIssue = false

  private init() {}

  func handleCreateLinearIssue(message: Message, window: NSWindow) async {
    guard !isCreatingIssue else { return }
    guard let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }

    if message.peerId.isThread,
       let spaceId = (try? Chat.getByPeerId(peerId: message.peerId)?.spaceId)
    {
      await createIssue(text: text, message: message, spaceId: spaceId)
      return
    }

    do {
      let userId = Auth.shared.getCurrentUserId() ?? 0
      let integrations = try await ApiClient.shared.getIntegrations(userId: userId, spaceId: nil)

      guard integrations.hasLinearConnected else {
        ToastCenter.shared.showError("No Linear integration found. Connect Linear in one of your spaces.")
        return
      }

      guard let linearSpaces = integrations.linearSpaces, !linearSpaces.isEmpty else {
        ToastCenter.shared.showError("No accessible Linear integrations found")
        return
      }

      guard let selectedSpaceId = await selectSpace(
        from: linearSpaces.map { (id: $0.spaceId, name: $0.spaceName) },
        window: window
      ) else { return }

      await createIssue(text: text, message: message, spaceId: selectedSpaceId)
    } catch {
      ToastCenter.shared.showError("Failed to create Linear issue")
      Log.shared.error("Failed to create Linear issue", error: error)
    }
  }

  private func selectSpace(from spaces: [(id: Int64, name: String)], window: NSWindow) async -> Int64? {
    await withCheckedContinuation { continuation in
      let alert = NSAlert()
      alert.messageText = "Select Space"
      alert.informativeText = "Choose which space to create the Linear issue in:"
      alert.alertStyle = .informational

      for space in spaces {
        alert.addButton(withTitle: space.name)
      }
      alert.addButton(withTitle: "Cancel")

      alert.beginSheetModal(for: window) { response in
        let index = Int(response.rawValue) - 1000
        if index >= 0 && index < spaces.count {
          continuation.resume(returning: spaces[index].id)
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  private func createIssue(text: String, message: Message, spaceId: Int64) async {
    showLoadingToast()

    do {
      let userId = Auth.shared.getCurrentUserId() ?? 0
      let integrations = try await ApiClient.shared.getIntegrations(userId: userId, spaceId: spaceId)

      guard integrations.hasLinearConnected else {
        hideLoadingToast()
        ToastCenter.shared.showError("Linear isn’t connected for that space.")
        return
      }

      guard let linearTeamId = integrations.linearTeamId, !linearTeamId.isEmpty else {
        hideLoadingToast()
        ToastCenter.shared.showError("Select a default Linear team for that space first.")
        return
      }

      let result = try await ApiClient.shared.createLinearIssue(
        text: text,
        messageId: message.messageId,
        peerId: message.peerId,
        chatId: message.chatId,
        fromId: userId,
        spaceId: spaceId
      )

      hideLoadingToast()

      guard let link = result.link, let url = URL(string: link) else {
        ToastCenter.shared.showError("Failed to create Linear issue")
        return
      }

      ToastCenter.shared.showSuccess("Linear issue created", actionTitle: "Open") {
        NSWorkspace.shared.open(url)
      }
    } catch {
      hideLoadingToast()
      ToastCenter.shared.showError("Failed to create Linear issue")
      Log.shared.error("Failed to create Linear issue", error: error)
    }
  }

  private func showLoadingToast() {
    isCreatingIssue = true
    ToastCenter.shared.showLoading("Creating Linear issue…")
  }

  private func hideLoadingToast() {
    isCreatingIssue = false
    ToastCenter.shared.dismiss()
  }
}
