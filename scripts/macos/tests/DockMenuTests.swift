import AppKit

/// Standalone AppKit checks against the production menu source; no account or app launch.
@main
struct DockMenuTests {
  @MainActor
  static func main() {
    let presentation = DockMenu()
    var opened: [Int] = []
    var cleared: [Int] = []
    let chats = (1...7).map { id in
      DockMenu.Chat(title: "Chat \(id)") { opened.append(id) }
    }
    let menu = presentation.makeMenu(chats: chats, totalCount: 7) { cleared.append(contentsOf: 1...7) }
    precondition(menu.items.map(\.title) == [
      "Unread Chats (7)", "Chat 1", "Chat 2", "Chat 3", "Chat 4", "Chat 5", "", "Mark All 7 Chats as Read",
    ])
    precondition(!menu.autoenablesItems)
    precondition(!menu.items[0].isEnabled && menu.items[6].isSeparatorItem)
    invoke(menu.items[3])
    precondition(opened == [3] && cleared.isEmpty)
    invoke(menu.items[7])
    precondition(cleared == Array(1...7))

    let empty = presentation.makeMenu(chats: [], totalCount: 0) { preconditionFailure("Empty menu cleared") }
    precondition(empty.items.count == 1 && empty.items[0].title == "No Unread Chats")
    precondition(!empty.items[0].isEnabled && empty.items[0].action == nil)

    let unavailable = presentation.unavailableMenu()
    precondition(unavailable.items.count == 1 && !unavailable.items[0].isEnabled)
    precondition(unavailable.items[0].title == "Unread Chats Unavailable")

    let single = presentation.makeMenu(chats: [.init(title: " A\n\tB ", open: {})], totalCount: 1) {}
    precondition(single.items[1].title == "A B")
    precondition(single.items.last?.title == "Mark Chat as Read")
    let longTitle = String(repeating: "👩🏽‍💻", count: 80)
    let long = presentation.makeMenu(chats: [.init(title: longTitle, open: {})], totalCount: 1) {}
    precondition(long.items[1].title.count == 60 && long.items[1].title.hasSuffix("…"))

    // Building a new menu must not redirect callbacks from an already returned menu.
    invoke(menu.items[1])
    precondition(opened == [3, 1])
    precondition(cleared == Array(1...7))
    print("DockMenu: native menu structure, five-chat limit, navigation, full clear scope, empty/error states, titles, and action ownership passed")
  }

  @MainActor
  private static func invoke(_ item: NSMenuItem) {
    precondition(item.isEnabled)
    guard let target = item.target as? NSObject, let action = item.action else {
      preconditionFailure("Missing menu action")
    }
    // Unlike an ordinary menu, Dock dispatches the action with no sender.
    target.perform(action, with: nil)
  }
}
