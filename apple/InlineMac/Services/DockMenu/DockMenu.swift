import AppKit

/// Native Dock presentation, independent of storage, navigation, and read-state mutations.
@MainActor
final class DockMenu: NSObject {
  struct Chat {
    let title: String
    let open: () -> Void
  }

  nonisolated static let chatLimit = 5
  private var displayedMenu: NSMenu?

  func makeMenu(chats: [Chat], totalCount: Int, markAllRead: @escaping () -> Void) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    displayedMenu = menu

    guard totalCount > 0 else {
      addHeading("No Unread Chats", to: menu)
      return menu
    }

    addHeading("Unread Chats (\(totalCount))", to: menu)
    for chat in chats.prefix(Self.chatLimit) {
      addAction(title: menuTitle(chat.title), to: menu, perform: chat.open)
    }
    menu.addItem(.separator())
    let clearTitle = totalCount == 1 ? "Mark Chat as Read" : "Mark All \(totalCount) Chats as Read"
    addAction(title: clearTitle, to: menu, perform: markAllRead)
    return menu
  }

  func unavailableMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    displayedMenu = menu
    addHeading("Unread Chats Unavailable", to: menu)
    return menu
  }

  private func addHeading(_ title: String, to menu: NSMenu) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    menu.addItem(item)
  }

  private func addAction(title: String, to menu: NSMenu, perform: @escaping () -> Void) {
    let action = Action(perform: perform)
    let item = NSMenuItem(title: title, action: #selector(Action.invoke(_:)), keyEquivalent: "")
    item.target = action
    // Dock forwards target/action with a nil sender. Each item needs its own retained target;
    // reading the sender's representedObject or tag works in normal menus but not in the Dock.
    item.representedObject = action
    menu.addItem(item)
  }

  private func menuTitle(_ title: String) -> String {
    let singleLine = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    guard !singleLine.isEmpty else { return "Chat" }
    return singleLine.count > 60 ? String(singleLine.prefix(59)) + "…" : singleLine
  }

  @MainActor
  private final class Action: NSObject {
    let perform: () -> Void

    init(perform: @escaping () -> Void) {
      self.perform = perform
    }

    @objc func invoke(_: Any?) {
      perform()
    }
  }
}
