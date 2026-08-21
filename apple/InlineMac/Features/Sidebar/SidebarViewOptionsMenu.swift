import AppKit
import InlineMacUI
import SwiftUI

/// Native owner for the described view-options menu. AppKit provides native
/// state columns for aligned choice checkmarks and explicit macOS 27 image
/// visibility for the parent submenu icons.
struct SidebarViewOptionsMenuButton: NSViewRepresentable {
  @Binding var itemSize: SidebarItemSize
  @Binding var sortMode: SidebarSortMode
  @Binding var cleanupInterval: SidebarCleanupInterval
  @Binding var sidebarMode: SidebarMode

  func makeCoordinator() -> Coordinator {
    Coordinator(configuration: self)
  }

  func makeNSView(context: Context) -> SidebarNativeMenuButton {
    let button = SidebarNativeMenuButton()
    button.image = NSImage(
      systemSymbolName: "line.3.horizontal.decrease",
      accessibilityDescription: "View options"
    )
    button.imageScaling = .scaleProportionallyDown
    button.contentTintColor = .tertiaryLabelColor
    button.setAccessibilityLabel("View options")
    button.target = context.coordinator
    button.action = #selector(Coordinator.showMenu(_:))
    button.setInlineTooltip("View options", placement: .above)
    return button
  }

  func updateNSView(_ button: SidebarNativeMenuButton, context: Context) {
    context.coordinator.configuration = self
    button.contentTintColor = .tertiaryLabelColor
  }

  static func dismantleNSView(_ button: SidebarNativeMenuButton, coordinator: Coordinator) {
    button.removeInlineTooltip()
  }

  @MainActor
  final class Coordinator: NSObject {
    var configuration: SidebarViewOptionsMenuButton

    init(configuration: SidebarViewOptionsMenuButton) {
      self.configuration = configuration
    }

    @objc func showMenu(_ sender: NSButton) {
      let menu = makeMenu()
      menu.popUp(
        positioning: nil,
        at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 4),
        in: sender
      )
    }

    private func makeMenu() -> NSMenu {
      let menu = NSMenu(title: "View Options")
      menu.autoenablesItems = false
      menu.addItem(sidebarModeItem())
      menu.addItem(itemSizeItem())
      menu.addItem(sortModeItem())
      menu.addItem(.separator())
      menu.addItem(cleanupItem())
      return menu
    }

    private func sidebarModeItem() -> NSMenuItem {
      let submenu = NSMenu(title: "Sidebar View")
      for (index, mode) in SidebarMode.allCases.enumerated() {
        submenu.addItem(choiceItem(
          title: mode.title,
          subtitle: mode.detail,
          isSelected: configuration.sidebarMode == mode,
          tag: index,
          action: #selector(selectSidebarMode(_:))
        ))
      }
      return submenuItem(
        title: "Sidebar View",
        subtitle: configuration.sidebarMode.title,
        systemImage: "sidebar.left",
        submenu: submenu
      )
    }

    private func itemSizeItem() -> NSMenuItem {
      let submenu = NSMenu(title: "Item Size")
      for (index, size) in SidebarItemSize.allCases.enumerated() {
        submenu.addItem(choiceItem(
          title: String(localized: size.title),
          subtitle: String(localized: size.detail),
          isSelected: configuration.itemSize == size,
          tag: index,
          action: #selector(selectItemSize(_:))
        ))
      }
      return submenuItem(
        title: "Item Size",
        subtitle: String(localized: configuration.itemSize.title),
        systemImage: "textformat.size",
        submenu: submenu
      )
    }

    private func sortModeItem() -> NSMenuItem {
      let effectiveMode: SidebarSortMode = configuration.sidebarMode == .allChats
        ? .recentActivity
        : configuration.sortMode
      let submenu = NSMenu(title: "Sort By")
      for (index, mode) in SidebarSortMode.allCases.enumerated() {
        let item = choiceItem(
          title: mode.title,
          subtitle: mode.detail,
          isSelected: effectiveMode == mode,
          tag: index,
          action: #selector(selectSortMode(_:))
        )
        item.isEnabled = configuration.sidebarMode != .allChats || mode == .recentActivity
        submenu.addItem(item)
      }
      return submenuItem(
        title: "Sort By",
        subtitle: effectiveMode.title,
        systemImage: "arrow.up.arrow.down",
        submenu: submenu
      )
    }

    private func cleanupItem() -> NSMenuItem {
      let submenu = NSMenu(title: "Open Chats Cleanup")
      submenu.addItem(choiceItem(
        title: SidebarCleanupInterval.never.title,
        subtitle: SidebarCleanupInterval.never.detailText,
        isSelected: configuration.cleanupInterval == .never,
        tag: SidebarCleanupInterval.allCases.firstIndex(of: .never) ?? 0,
        action: #selector(selectCleanupInterval(_:))
      ))
      submenu.addItem(.separator())
      submenu.addItem(.sectionHeader(title: "Close Open Chats After"))
      for (index, interval) in SidebarCleanupInterval.allCases.enumerated()
        where interval != .never {
        submenu.addItem(choiceItem(
          title: interval.title,
          isSelected: configuration.cleanupInterval == interval,
          tag: index,
          action: #selector(selectCleanupInterval(_:))
        ))
      }
      return submenuItem(
        title: "Open Chats Cleanup",
        subtitle: configuration.cleanupInterval.title,
        systemImage: "clock.arrow.circlepath",
        submenu: submenu
      )
    }

    private func submenuItem(
      title: String,
      subtitle: String,
      systemImage: String,
      submenu: NSMenu
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.subtitle = subtitle
      item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
      forceImageVisible(item)
      item.submenu = submenu
      return item
    }

    private func choiceItem(
      title: String,
      subtitle: String? = nil,
      isSelected: Bool,
      tag: Int,
      action: Selector
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      item.tag = tag
      item.subtitle = subtitle
      item.state = isSelected ? .on : .off
      return item
    }

    private func forceImageVisible(_ item: NSMenuItem) {
      if #available(macOS 27.0, *) {
        item.preferredImageVisibility = .visible
      }
    }

    @objc private func selectSidebarMode(_ sender: NSMenuItem) {
      guard SidebarMode.allCases.indices.contains(sender.tag) else { return }
      configuration.sidebarMode = SidebarMode.allCases[sender.tag]
    }

    @objc private func selectItemSize(_ sender: NSMenuItem) {
      guard SidebarItemSize.allCases.indices.contains(sender.tag) else { return }
      configuration.itemSize = SidebarItemSize.allCases[sender.tag]
    }

    @objc private func selectSortMode(_ sender: NSMenuItem) {
      guard SidebarSortMode.allCases.indices.contains(sender.tag) else { return }
      configuration.sortMode = SidebarSortMode.allCases[sender.tag]
    }

    @objc private func selectCleanupInterval(_ sender: NSMenuItem) {
      guard SidebarCleanupInterval.allCases.indices.contains(sender.tag) else { return }
      configuration.cleanupInterval = SidebarCleanupInterval.allCases[sender.tag]
    }
  }
}

final class SidebarNativeMenuButton: NSButton {
  private var hoverTrackingArea: NSTrackingArea?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isBordered = false
    bezelStyle = .accessoryBarAction
    focusRingType = .none
    imagePosition = .imageOnly
    wantsLayer = true
    layer?.cornerRadius = SidebarFooterMetrics.cornerRadius
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func updateTrackingAreas() {
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(trackingArea)
    hoverTrackingArea = trackingArea
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    layer?.backgroundColor = NSColor.clear.cgColor
  }
}
