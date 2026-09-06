import AppKit
import InlineKit

@MainActor
enum ForwardMessageMenu {
  static func make(messages: [FullMessage], dependencies: AppDependencies) -> NSMenu {
    let menu = NSMenu(title: "Forward")
    menu.autoenablesItems = false
    guard let presenter = dependencies.forwardMessages else { return menu }

    if !presenter.hasLoadedRecentDestinations {
      let loading = NSMenuItem(title: "Loading recent chats…", action: nil, keyEquivalent: "")
      loading.isEnabled = false
      menu.addItem(loading)
    }
    for destination in presenter.recentDestinations {
      let title = destination.parentTitle.map { "\($0) › \(destination.title)" } ?? destination.title
      let item = ForwardMenuItem(title: title) {
        presenter.sendImmediately(messages: messages, to: destination, dependencies: dependencies)
      }
      item.image = NSImage(
        systemSymbolName: destination.peerId.isPrivate ? "person.crop.circle" : "bubble.left.and.bubble.right",
        accessibilityDescription: nil
      )
      item.toolTip = "Forward immediately to \(title)"
      menu.addItem(item)
    }
    if menu.items.isEmpty == false { menu.addItem(.separator()) }
    let more = ForwardMenuItem(title: "More…") { presenter.present(messages: messages) }
    more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
    more.toolTip = "Choose more recipients or add a message"
    menu.addItem(more)
    return menu
  }
}

private final class ForwardMenuItem: NSMenuItem {
  private let handler: () -> Void

  init(title: String, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(invoke), keyEquivalent: "")
    target = self
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // Message context menus copy their items when AppKit asks for an update.
  // A copied item must target itself, rather than the soon-to-be-released original.
  override func copy(with zone: NSZone? = nil) -> Any {
    let item = ForwardMenuItem(title: title, handler: handler)
    item.image = image
    item.toolTip = toolTip
    item.isEnabled = isEnabled
    item.keyEquivalent = keyEquivalent
    return item
  }

  @objc private func invoke() { handler() }
}
