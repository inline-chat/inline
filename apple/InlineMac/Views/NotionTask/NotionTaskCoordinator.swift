import AppKit
import SwiftUI
import InlineKit

@MainActor
class NotionTaskCoordinator: ObservableObject {
  static let shared = NotionTaskCoordinator()

  @Published var isCreatingTask = false
  private var loadingWindow: NotionTaskLoadingWindow?

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
      showErrorAlert(error: error, window: window)
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
    showLoadingWindow()

    do {
      let url = try await NotionTaskService.shared.createTask(message: message, spaceId: spaceId)
      hideLoadingWindow()
      showSuccessAlert(url: url, window: window)
    } catch {
      hideLoadingWindow()
      showErrorAlert(error: error, window: window)
    }
  }

  private func showLoadingWindow() {
    isCreatingTask = true
    loadingWindow = NotionTaskLoadingWindow()
    loadingWindow?.makeKeyAndOrderFront(nil)
  }

  private func hideLoadingWindow() {
    isCreatingTask = false
    loadingWindow?.close()
    loadingWindow = nil
  }

  private func showSuccessAlert(url: String, window: NSWindow) {
    let alert = NSAlert()
    alert.messageText = "Task Created"
    alert.informativeText = "Notion task has been created successfully."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Open in Notion")
    alert.addButton(withTitle: "Done")

    alert.beginSheetModal(for: window) { response in
      if response == .alertFirstButtonReturn {
        if let notionURL = URL(string: url) {
          NSWorkspace.shared.open(notionURL)
        }
      }
    }
  }

  private func showErrorAlert(error: Error, window: NSWindow) {
    let alert = NSAlert()
    alert.messageText = "Failed to Create Task"
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .critical
    alert.addButton(withTitle: "Dismiss")

    alert.beginSheetModal(for: window) { _ in }
  }
}
