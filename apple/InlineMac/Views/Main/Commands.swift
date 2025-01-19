import InlineKit
import SwiftUI

struct MainWindowCommands: Commands {
  @Environment(\.openWindow) var openWindow

  @AppStorage("isDevtoolsOpen") var isDevtoolsOpen = false

  var isLoggedIn: Bool
  var navigation: NavigationModel
  var logOut: () -> Void

  @ObservedObject var auth = Auth.shared

  var body: some Commands {
    CommandGroup(before: .appTermination) {
      if auth.isLoggedIn {
        Button(action: logOutWithConfirmation) {
          Text("Log Out")
        }
      }

      Button(action: clearCache) {
        Text("Clear Cache...")
      }

      Divider()
    }

    // This removes the "New Window" command from the File menu
    CommandGroup(replacing: .newItem) {}

    TextEditingCommands()

    // Create Space
    if auth.isLoggedIn {
      CommandGroup(after: .newItem) {
        Button(action: createSpace) {
          Text("Create Space")
        }
      }
    }

    CommandGroup(after: .sidebar) {
      if isDevtoolsOpen {
        Button(action: { isDevtoolsOpen.toggle() }) {
          Text("Close Devtools")
        }.keyboardShortcut("D", modifiers: [.shift, .command])
      } else {
        Button(action: { isDevtoolsOpen.toggle() }) {
          Text("Open Devtools")
        }
        .keyboardShortcut("D", modifiers: [.shift, .command])
      }
    }

    CommandGroup(replacing: .help) {
      Button(action: sendFeedback) {
        Text("Send Feedback")
      }

      Button(action: openHelpWebsite) {
        Text("Help")
      }

      Button(action: openWebsite) {
        Text("Website")
      }

      Divider()

      Button(action: openX) {
        Text("Updates on X")
      }

      Button(action: openGitHub) {
        Text("GitHub")
      }

      Divider()

      Button(action: openStatus) {
        Text("Service Status")
      }
    }

    SidebarCommands()
  }

  private func createSpace() {
    navigation.createSpaceSheetPresented = true
  }

  private func openHelpWebsite() {
    NSWorkspace.shared.open(URL(string: "https://inline.chat/docs")!)
  }

  private func openX() {
    NSWorkspace.shared.open(URL(string: "https://x.com/inline_chat")!)
  }

  private func openWebsite() {
    NSWorkspace.shared.open(URL(string: "https://inline.chat")!)
  }

  private func openStatus() {
    NSWorkspace.shared.open(URL(string: "https://status.inline.chat")!)
  }

  private func openGitHub() {
    NSWorkspace.shared.open(URL(string: "https://github.com/inline-chat")!)
  }

  private func sendFeedback() {
    NSWorkspace.shared.open(URL(string: "https://inline.chat/feedback")!)
  }

  func logOutWithConfirmation() {
    let alert = NSAlert()
    alert.messageText = "Log Out"
    alert.informativeText = "Are you sure you want to log out?"
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning
    let button = alert.addButton(withTitle: "Log Out")
    button.hasDestructiveAction = true

    if alert.runModal() == .alertSecondButtonReturn {
      logOut()
    }
  }

  func clearCache() {
    // Clear database
    try? AppDatabase.clearDB()

    // Close main window
    if let window = NSApplication.shared.mainWindow {
      window.close()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      openWindow(id: "main")
    }
  }
}
