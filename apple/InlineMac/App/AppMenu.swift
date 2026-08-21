import AppKit
import Auth
import InlineCLIInstaller
import InlineKit
import MacDevtools
import MacTheme
import Observation

extension Notification.Name {
  static let toggleSidebar = Notification.Name("toggleSidebar")
  static let quickSearchVisibilityChanged = Notification.Name("quickSearchVisibilityChanged")
  static let renameThread = Notification.Name("renameThread")
  static let switchToInbox = Notification.Name("switchToInbox")
  static let prevChat = Notification.Name("prevChat")
  static let nextChat = Notification.Name("nextChat")
}

@MainActor
final class AppMenu: NSObject {
  static let shared = AppMenu()
  private let mainMenu = NSMenu()
  private var dependencies: AppDependencies?
  private weak var undoMenuItem: NSMenuItem?
  private weak var redoMenuItem: NSMenuItem?
  private weak var cliInstallerMenuItem: NSMenuItem?
  private var cliInstallerMenuItemEnabled = true
  private weak var tabBarMenuItem: NSMenuItem?
  private weak var closeWindowMenuItem: NSMenuItem?
  private weak var spaceMenu: NSMenu?
  private var chatMenuItems: [ChatMenuCommand: NSMenuItem] = [:]
#if SPARKLE
  private weak var updateMenuItem: NSMenuItem?
  private var updateMenuItemEnabled = true
#if DEBUG
  private var lastAppliedUpdatePhase: SoftwareUpdatePhase?
#endif
#endif

  override private init() {
    super.init()
  }

  @MainActor func setupMainMenu(dependencies: AppDependencies) {
    self.dependencies = dependencies
    mainMenu.removeAllItems()
    chatMenuItems.removeAll()
    NSApp.mainMenu = mainMenu

    setupApplicationMenu()
    setupFileMenu()
    setupEditMenu()
    setupFormatMenu()
    setupViewMenu()
    setupChatMenu()
    setupSpaceMenu()
    setupWindowMenu()
    setupHelpMenu()
  }

  @MainActor private func setupApplicationMenu() {
    let appMenu = NSMenu()
    let appName = ProcessInfo.processInfo.processName

    let appMenuItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    appMenu.addItem(
      withTitle: "About \(appName)",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )

#if SPARKLE
    let checkForUpdatesMenuItem = NSMenuItem(
      title: "Check for Updates…",
      action: #selector(handleUpdateMenuAction(_:)),
      keyEquivalent: ""
    )
    checkForUpdatesMenuItem.target = self
    checkForUpdatesMenuItem.image = NSImage(
      systemSymbolName: "arrow.triangle.2.circlepath",
      accessibilityDescription: nil
    )
    appMenu.addItem(checkForUpdatesMenuItem)
    updateMenuItem = checkForUpdatesMenuItem
    bindUpdateMenuItemState()
#endif

    appMenu.addItem(NSMenuItem.separator())

    let settingsMenuItem = NSMenuItem(
      title: "Settings…",
      action: #selector(showPreferences),
      keyEquivalent: ","
    )
    settingsMenuItem.target = self
    settingsMenuItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
    appMenu.addItem(settingsMenuItem)

    appMenu.addItem(NSMenuItem.separator())

    let installCLIMenuItem = NSMenuItem(
      title: "Install Inline CLI…",
      action: #selector(handleCLIInstallerMenuAction(_:)),
      keyEquivalent: ""
    )
    installCLIMenuItem.target = self
    installCLIMenuItem.image = NSImage(
      systemSymbolName: "terminal",
      accessibilityDescription: nil
    )
    appMenu.addItem(installCLIMenuItem)
    cliInstallerMenuItem = installCLIMenuItem
    bindCLIInstallerMenuItemState()

    let setupAgentMenuItem = NSMenuItem(
      title: "Set Up an Agent…",
      action: #selector(handleAgentSetupMenuAction(_:)),
      keyEquivalent: ""
    )
    setupAgentMenuItem.target = self
    setupAgentMenuItem.image = NSImage(
      systemSymbolName: "cpu",
      accessibilityDescription: nil
    )
    appMenu.addItem(setupAgentMenuItem)

    appMenu.addItem(NSMenuItem.separator())

    let servicesMenu = NSMenu()
    let servicesMenuItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    servicesMenuItem.submenu = servicesMenu
    appMenu.addItem(servicesMenuItem)
    NSApp.servicesMenu = servicesMenu

    let logoutMenuItem = NSMenuItem(
      title: "Log Out…",
      action: #selector(logOut(_:)),
      keyEquivalent: ""
    )
    logoutMenuItem.target = self
    logoutMenuItem.image = NSImage(
      systemSymbolName: "rectangle.portrait.and.arrow.right",
      accessibilityDescription: nil
    )
    appMenu.addItem(logoutMenuItem)

    appMenu.addItem(NSMenuItem.separator())

    appMenu.addItem(
      withTitle: "Hide \(appName)",
      action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h"
    )

    let hideOthersItem = NSMenuItem(
      title: "Hide Others",
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h"
    )
    hideOthersItem.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(hideOthersItem)

    appMenu.addItem(
      withTitle: "Show All",
      action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: ""
    )

    appMenu.addItem(NSMenuItem.separator())

    appMenu.addItem(
      withTitle: "Quit \(appName)",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
  }

  private func setupFileMenu() {
    let fileMenu = NSMenu(title: "File")
    let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    fileMenuItem.submenu = fileMenu
    mainMenu.addItem(fileMenuItem)

    let newThreadItem = NSMenuItem(
      title: "New Thread",
      action: #selector(newThread(_:)),
      keyEquivalent: "n"
    )
    newThreadItem.target = self
    newThreadItem.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
    fileMenu.addItem(newThreadItem)

    let newWindowItem = NSMenuItem(
      title: "New Window",
      action: #selector(newWindow(_:)),
      keyEquivalent: "n"
    )
    newWindowItem.keyEquivalentModifierMask = [.command, .shift]
    newWindowItem.target = self
    newWindowItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
    fileMenu.addItem(newWindowItem)

    let newTabItem = NSMenuItem(
      title: "New Tab",
      action: #selector(newTab(_:)),
      keyEquivalent: "t"
    )
    newTabItem.target = self
    newTabItem.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
    fileMenu.addItem(newTabItem)

    fileMenu.addItem(NSMenuItem.separator())

    let closeItem = NSMenuItem(
      title: "Close Window",
      action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "w"
    )
    fileMenu.addItem(closeItem)
    closeWindowMenuItem = closeItem
  }

  private func setupEditMenu() {
    let editMenu = NSMenu(title: "Edit")
    let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    // Undo/Redo
    let undoItem = NSMenuItem(
      title: "Undo",
      action: #selector(performUndo(_:)),
      keyEquivalent: "z"
    )
    undoItem.target = self
    editMenu.addItem(undoItem)
    undoMenuItem = undoItem

    let redoItem = NSMenuItem(
      title: "Redo",
      action: #selector(performRedo(_:)),
      keyEquivalent: "Z"
    )
    redoItem.target = self
    editMenu.addItem(redoItem)
    redoMenuItem = redoItem

    editMenu.addItem(NSMenuItem.separator())

    // Cut/Copy/Paste
    editMenu.addItem(
      withTitle: "Cut",
      action: #selector(NSText.cut(_:)),
      keyEquivalent: "x"
    )
    editMenu.addItem(
      withTitle: "Copy",
      action: #selector(NSText.copy(_:)),
      keyEquivalent: "c"
    )
    editMenu.addItem(
      withTitle: "Paste",
      action: #selector(NSText.paste(_:)),
      keyEquivalent: "v"
    )
    let pasteAndMatchStyleItem = NSMenuItem(
      title: "Paste and Match Style",
      action: #selector(NSTextView.pasteAsPlainText(_:)),
      keyEquivalent: "v"
    )
    pasteAndMatchStyleItem.keyEquivalentModifierMask = [.command, .option, .shift]
    editMenu.addItem(pasteAndMatchStyleItem)
    editMenu.addItem(
      withTitle: "Delete",
      action: #selector(NSText.delete(_:)),
      keyEquivalent: "\u{8}"
    ) // Backspace key
    editMenu.addItem(
      withTitle: "Select All",
      action: #selector(NSText.selectAll(_:)),
      keyEquivalent: "a"
    )
    editMenu.addItem(NSMenuItem.separator())

    // Find
    let findMenu = NSMenu(title: "Find")
    let findMenuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
    findMenuItem.submenu = findMenu
    editMenu.addItem(findMenuItem)

    findMenu.addItem(
      withTitle: "Find…",
      action: #selector(NSResponder.performTextFinderAction(_:)),
      keyEquivalent: "f"
    )
    findMenu.addItem(
      withTitle: "Find Next",
      action: #selector(NSResponder.performTextFinderAction(_:)),
      keyEquivalent: "g"
    )
    findMenu.addItem(
      withTitle: "Find Previous",
      action: #selector(NSResponder.performTextFinderAction(_:)),
      keyEquivalent: "G"
    )
    findMenu.addItem(
      withTitle: "Use Selection for Find",
      action: #selector(NSResponder.performTextFinderAction(_:)),
      keyEquivalent: "e"
    )
    findMenu.addItem(
      withTitle: "Jump to Selection",
      action: #selector(NSResponder.centerSelectionInVisibleArea(_:)),
      keyEquivalent: "j"
    )

    editMenu.addItem(NSMenuItem.separator())

    // Spelling and Grammar
    let spellingMenu = NSMenu(title: "Spelling")
    let spellingMenuItem = NSMenuItem(
      title: "Spelling and Grammar",
      action: nil,
      keyEquivalent: ""
    )
    spellingMenuItem.submenu = spellingMenu
    editMenu.addItem(spellingMenuItem)

    spellingMenu.addItem(
      withTitle: "Show Spelling and Grammar",
      action: #selector(NSText.showGuessPanel(_:)),
      keyEquivalent: ":"
    )
    spellingMenu.addItem(
      withTitle: "Check Document Now",
      action: #selector(NSText.checkSpelling(_:)),
      keyEquivalent: ";"
    )

    spellingMenu.addItem(NSMenuItem.separator())

    spellingMenu.addItem(
      withTitle: "Check Spelling While Typing",
      action: #selector(NSTextView.toggleContinuousSpellChecking(_:)),
      keyEquivalent: ""
    )
    spellingMenu.addItem(
      withTitle: "Check Grammar With Spelling",
      action: #selector(NSTextView.toggleGrammarChecking(_:)),
      keyEquivalent: ""
    )
    spellingMenu.addItem(
      withTitle: "Correct Spelling Automatically",
      action: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)),
      keyEquivalent: ""
    )

    // Substitutions
    let substitutionsMenu = NSMenu(title: "Substitutions")
    let substitutionsMenuItem = NSMenuItem(
      title: "Substitutions",
      action: nil,
      keyEquivalent: ""
    )
    substitutionsMenuItem.submenu = substitutionsMenu
    editMenu.addItem(substitutionsMenuItem)

    substitutionsMenu.addItem(
      withTitle: "Show Substitutions",
      action: #selector(NSTextView.orderFrontSubstitutionsPanel(_:)),
      keyEquivalent: ""
    )

    substitutionsMenu.addItem(NSMenuItem.separator())

    substitutionsMenu.addItem(
      withTitle: "Smart Copy/Paste",
      action: #selector(NSTextView.toggleSmartInsertDelete(_:)),
      keyEquivalent: ""
    )
    substitutionsMenu.addItem(
      withTitle: "Smart Quotes",
      action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)),
      keyEquivalent: ""
    )
    substitutionsMenu.addItem(
      withTitle: "Smart Dashes",
      action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)),
      keyEquivalent: ""
    )
    substitutionsMenu.addItem(
      withTitle: "Smart Links",
      action: #selector(NSTextView.toggleAutomaticLinkDetection(_:)),
      keyEquivalent: ""
    )
    substitutionsMenu.addItem(
      withTitle: "Text Replacement",
      action: #selector(NSTextView.toggleAutomaticTextReplacement(_:)),
      keyEquivalent: ""
    )

    // Transformations
    let transformationsMenu = NSMenu(title: "Transformations")
    let transformationsMenuItem = NSMenuItem(
      title: "Transformations",
      action: nil,
      keyEquivalent: ""
    )
    transformationsMenuItem.submenu = transformationsMenu
    editMenu.addItem(transformationsMenuItem)

    transformationsMenu.addItem(
      withTitle: "Make Upper Case",
      action: #selector(NSResponder.uppercaseWord(_:)),
      keyEquivalent: ""
    )
    transformationsMenu.addItem(
      withTitle: "Make Lower Case",
      action: #selector(NSResponder.lowercaseWord(_:)),
      keyEquivalent: ""
    )
    transformationsMenu.addItem(
      withTitle: "Capitalize",
      action: #selector(NSResponder.capitalizeWord(_:)),
      keyEquivalent: ""
    )

    if #available(macOS 15.2, *) {
      let writingToolsItems = NSMenuItem.writingToolsItems
      if !writingToolsItems.isEmpty {
        editMenu.addItem(NSMenuItem.separator())
        writingToolsItems.forEach { editMenu.addItem($0) }
      }
    }

    editMenu.addItem(NSMenuItem.separator())

    let speechMenu = NSMenu(title: "Speech")
    let speechMenuItem = NSMenuItem(title: "Speech", action: nil, keyEquivalent: "")
    speechMenuItem.submenu = speechMenu
    editMenu.addItem(speechMenuItem)

    speechMenu.addItem(
      withTitle: "Start Speaking",
      action: Selector(("startSpeaking:")),
      keyEquivalent: ""
    )
    speechMenu.addItem(
      withTitle: "Stop Speaking",
      action: Selector(("stopSpeaking:")),
      keyEquivalent: ""
    )

    editMenu.addItem(NSMenuItem.separator())

    editMenu.addItem(
      withTitle: "Start Dictation…",
      action: Selector(("startDictation:")),
      keyEquivalent: ""
    )

    let emojiItem = NSMenuItem(
      title: "Emoji & Symbols",
      action: #selector(NSApplication.orderFrontCharacterPalette(_:)),
      keyEquivalent: " "
    )
    emojiItem.keyEquivalentModifierMask = [.control, .command]
    emojiItem.target = NSApp
    editMenu.addItem(emojiItem)
  }

  private func setupFormatMenu() {
    let formatMenu = NSMenu(title: "Format")
    let formatMenuItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
    formatMenuItem.identifier = NSUserInterfaceItemIdentifier("menu.format")
    formatMenuItem.submenu = formatMenu
    mainMenu.addItem(formatMenuItem)

    formatMenu.addItem(
      withTitle: "Bold",
      action: #selector(ComposeNSTextView.toggleBold(_:)),
      keyEquivalent: "b"
    )
    formatMenu.addItem(
      withTitle: "Italic",
      action: #selector(ComposeNSTextView.toggleItalic(_:)),
      keyEquivalent: "i"
    )

    let inlineCodeItem = NSMenuItem(
      title: "Inline Code",
      action: #selector(ComposeNSTextView.toggleInlineCode(_:)),
      keyEquivalent: "c"
    )
    inlineCodeItem.keyEquivalentModifierMask = [.command, .shift]
    formatMenu.addItem(inlineCodeItem)

    formatMenu.addItem(NSMenuItem.separator())
    formatMenu.addItem(
      withTitle: "Add Link…",
      action: #selector(ComposeNSTextView.makeLink(_:)),
      keyEquivalent: ""
    )
  }

  private func setupViewMenu() {
    let viewMenu = NSMenu(title: "View")
    let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
    viewMenuItem.submenu = viewMenu
    mainMenu.addItem(viewMenuItem)

    let quickSearchItem = NSMenuItem(
      title: "Quick Search",
      action: #selector(toggleQuickSearch(_:)),
      keyEquivalent: "k"
    )
    quickSearchItem.keyEquivalentModifierMask = [.command]
    quickSearchItem.target = self
    quickSearchItem.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    viewMenu.addItem(quickSearchItem)

    let toggleSidebarItem = NSMenuItem(
      title: "Toggle Sidebar",
      action: #selector(toggleSidebar(_:)),
      keyEquivalent: "s"
    )
    toggleSidebarItem.keyEquivalentModifierMask = [.command]
    toggleSidebarItem.target = self
    toggleSidebarItem.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
    viewMenu.addItem(toggleSidebarItem)

    let tabStripItem = NSMenuItem(
      title: "Show Tab Bar",
      action: #selector(toggleNativeTabBar(_:)),
      keyEquivalent: "s"
    )
    tabStripItem.keyEquivalentModifierMask = [.command, .shift]
    tabStripItem.target = self
    tabStripItem.state = activeWindow()?.tabGroup?.isTabBarVisible == true ? .on : .off
    tabStripItem.image = NSImage(
      systemSymbolName: "rectangle.topthird.inset.filled",
      accessibilityDescription: nil
    )
    viewMenu.addItem(tabStripItem)
    tabBarMenuItem = tabStripItem

    let showAllTabsItem = NSMenuItem(
      title: "Show All Tabs",
      action: #selector(showAllTabs(_:)),
      keyEquivalent: "\\"
    )
    showAllTabsItem.keyEquivalentModifierMask = [.command, .shift]
    showAllTabsItem.target = self
    showAllTabsItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
    viewMenu.addItem(showAllTabsItem)

    viewMenu.addItem(NSMenuItem.separator())

    viewMenu.addItem(
      withTitle: "Toggle Full Screen",
      action: #selector(NSWindow.toggleFullScreen(_:)),
      keyEquivalent: "f"
    )

    viewMenu.addItem(NSMenuItem.separator())

    setupViewPreferenceMenus(in: viewMenu)

    viewMenu.addItem(NSMenuItem.separator())

    let backItem = NSMenuItem(
      title: "Back",
      action: #selector(goBack(_:)),
      keyEquivalent: "["
    )
    backItem.keyEquivalentModifierMask = [.command]
    backItem.target = self
    backItem.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
    viewMenu.addItem(backItem)

    let forwardItem = NSMenuItem(
      title: "Forward",
      action: #selector(goForward(_:)),
      keyEquivalent: "]"
    )
    forwardItem.keyEquivalentModifierMask = [.command]
    forwardItem.target = self
    forwardItem.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
    viewMenu.addItem(forwardItem)

  }

  private func setupViewPreferenceMenus(in menu: NSMenu) {
    menu.addItem(preferenceSubmenu(
      title: "Appearance",
      values: AppAppearance.pickerOrder,
      action: #selector(selectAppearance(_:)),
      itemTitle: \AppAppearance.title
    ))
    menu.addItem(preferenceSubmenu(
      title: "Theme",
      values: AppThemePreset.allCases,
      action: #selector(selectTheme(_:)),
      itemTitle: \AppThemePreset.title
    ))
    menu.addItem(preferenceSubmenu(
      title: "Message Style",
      values: MessageRenderStyle.allCases,
      action: #selector(selectMessageStyle(_:)),
      itemTitle: \MessageRenderStyle.title
    ))
    menu.addItem(togglePreferenceItem(
      title: "Compact Toolbar",
      action: #selector(toggleCompactToolbar(_:))
    ))
    menu.addItem(togglePreferenceItem(
      title: "Sidebar Tint",
      action: #selector(toggleSidebarTint(_:))
    ))

    menu.addItem(NSMenuItem.separator())

    menu.addItem(preferenceSubmenu(
      title: "Sidebar View",
      values: SidebarMode.allCases,
      action: #selector(selectSidebarMode(_:)),
      itemTitle: \SidebarMode.title
    ))
    menu.addItem(preferenceSubmenu(
      title: "Sidebar Item Size",
      values: SidebarItemSize.allCases,
      action: #selector(selectSidebarItemSize(_:)),
      itemTitle: { String(localized: $0.title) }
    ))
    menu.addItem(preferenceSubmenu(
      title: "Sidebar Sort",
      values: SidebarSortMode.allCases,
      action: #selector(selectSidebarSort(_:)),
      itemTitle: \SidebarSortMode.title
    ))
    menu.addItem(sidebarCleanupSubmenu())
    menu.addItem(togglePreferenceItem(
      title: "Open Reply Threads in Side Pane",
      action: #selector(toggleReplyThreadSidePane(_:))
    ))
    menu.addItem(togglePreferenceItem(
      title: "Show Dock Badge",
      action: #selector(toggleDockBadge(_:))
    ))
  }

  private func preferenceSubmenu<Value>(
    title: String,
    values: [Value],
    action: Selector,
    itemTitle: (Value) -> String
  ) -> NSMenuItem {
    let submenu = NSMenu(title: title)
    for (index, value) in values.enumerated() {
      let item = NSMenuItem(title: itemTitle(value), action: action, keyEquivalent: "")
      item.target = self
      item.tag = index
      submenu.addItem(item)
    }
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = submenu
    return item
  }

  private func togglePreferenceItem(title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  private func sidebarCleanupSubmenu() -> NSMenuItem {
    let submenu = NSMenu(title: "Open Chats Cleanup")
    let off = NSMenuItem(
      title: SidebarCleanupInterval.never.title,
      action: #selector(selectSidebarCleanupInterval(_:)),
      keyEquivalent: ""
    )
    off.target = self
    off.tag = SidebarCleanupInterval.allCases.firstIndex(of: .never) ?? 0
    submenu.addItem(off)
    submenu.addItem(NSMenuItem.separator())
    submenu.addItem(.sectionHeader(title: "Close Open Chats After"))
    for (index, interval) in SidebarCleanupInterval.allCases.enumerated() where interval != .never {
      let item = NSMenuItem(
        title: interval.title,
        action: #selector(selectSidebarCleanupInterval(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.tag = index
      submenu.addItem(item)
    }
    let item = NSMenuItem(title: "Open Chats Cleanup", action: nil, keyEquivalent: "")
    item.submenu = submenu
    return item
  }

  private func setupSpaceMenu() {
    let menu = NSMenu(title: "Space")
    menu.delegate = self
    let item = NSMenuItem(title: "Space", action: nil, keyEquivalent: "")
    item.identifier = NSUserInterfaceItemIdentifier("menu.space")
    item.submenu = menu
    mainMenu.addItem(item)
    spaceMenu = menu
  }

  private func setupChatMenu() {
    let menu = NSMenu(title: "Chat")
    let item = NSMenuItem(title: "Chat", action: nil, keyEquivalent: "")
    item.identifier = NSUserInterfaceItemIdentifier("menu.chat")
    item.submenu = menu
    mainMenu.addItem(item)

    let commandGroups: [[ChatMenuCommand]] = [
      [.openNewTab, .openNewWindow],
      [.showInfo, .rename, .copyLink],
      [.toggleRead, .openInSidebar],
      [.toggleFollow, .togglePin, .toggleArchive],
    ]

    for (groupIndex, commands) in commandGroups.enumerated() {
      if groupIndex > 0 {
        menu.addItem(NSMenuItem.separator())
      }
      for command in commands {
        let commandItem = NSMenuItem(
          title: ChatMenuContext.placeholderTitle(for: command),
          action: #selector(performChatCommand(_:)),
          keyEquivalent: ""
        )
        commandItem.target = self
        commandItem.tag = command.rawValue
        commandItem.identifier = command.identifier
        menu.addItem(commandItem)
        chatMenuItems[command] = commandItem
      }
    }

    menu.addItem(NSMenuItem.separator())

    let previous = NSMenuItem(
      title: "Previous Chat",
      action: #selector(prevChat(_:)),
      keyEquivalent: String(UnicodeScalar(NSEvent.SpecialKey.upArrow.rawValue)!)
    )
    previous.keyEquivalentModifierMask = [.option]
    previous.target = self
    menu.addItem(previous)

    let next = NSMenuItem(
      title: "Next Chat",
      action: #selector(nextChat(_:)),
      keyEquivalent: String(UnicodeScalar(NSEvent.SpecialKey.downArrow.rawValue)!)
    )
    next.keyEquivalentModifierMask = [.option]
    next.target = self
    menu.addItem(next)
  }

  private func setupWindowMenu() {
    let windowMenu = NSMenu(title: "Window")
    let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)

    windowMenu.addItem(
      withTitle: "Minimize",
      action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m"
    )
    windowMenu.addItem(
      withTitle: "Zoom",
      action: #selector(NSWindow.performZoom(_:)),
      keyEquivalent: ""
    )

    let alwaysOnTopItem = NSMenuItem(
      title: "Always on Top",
      action: #selector(toggleAlwaysOnTop(_:)),
      keyEquivalent: "t"
    )
    alwaysOnTopItem.keyEquivalentModifierMask = [.command, .option]
    alwaysOnTopItem.target = self
    alwaysOnTopItem.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
    windowMenu.addItem(alwaysOnTopItem)

    windowMenu.addItem(NSMenuItem.separator())

    let macDevtoolsItem = NSMenuItem(
      title: "Open Devtools",
      action: #selector(openMacDevtools(_:)),
      keyEquivalent: "d"
    )
    macDevtoolsItem.keyEquivalentModifierMask = [.command, .option]
    macDevtoolsItem.target = self
    macDevtoolsItem.image = NSImage(systemSymbolName: "ladybug", accessibilityDescription: nil)
    windowMenu.addItem(macDevtoolsItem)

#if DEBUG || DEBUG_BUILD
    let playgroundItem = NSMenuItem(
      title: "Open Playground",
      action: #selector(openDeveloperPlayground(_:)),
      keyEquivalent: "p"
    )
    playgroundItem.keyEquivalentModifierMask = [.command, .option]
    playgroundItem.target = self
    playgroundItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
    windowMenu.addItem(playgroundItem)
#endif

    windowMenu.addItem(NSMenuItem.separator())

    windowMenu.addItem(
      withTitle: "Bring All to Front",
      action: #selector(NSApplication.arrangeInFront(_:)),
      keyEquivalent: ""
    )

    NSApp.windowsMenu = windowMenu
  }

  private func setupHelpMenu() {
    let helpMenu = NSMenu(title: "Help")
    let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
    helpMenuItem.submenu = helpMenu
    mainMenu.addItem(helpMenuItem)

    let docsItem = NSMenuItem(
      title: "Documentation",
      action: #selector(openDocs(_:)),
      keyEquivalent: ""
    )
    docsItem.target = self
    docsItem.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
    helpMenu.addItem(docsItem)

    let whatsNewItem = NSMenuItem(
      title: "What’s New",
      action: #selector(openWhatsNew(_:)),
      keyEquivalent: ""
    )
    whatsNewItem.target = self
    whatsNewItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
    helpMenu.addItem(whatsNewItem)

    let previousVersionsItem = NSMenuItem(
      title: "Previous Versions",
      action: #selector(openPreviousVersions(_:)),
      keyEquivalent: ""
    )
    previousVersionsItem.target = self
    previousVersionsItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
    helpMenu.addItem(previousVersionsItem)

    let feedbackItem = NSMenuItem(
      title: "Send Feedback",
      action: #selector(sendFeedback(_:)),
      keyEquivalent: ""
    )
    feedbackItem.target = self
    feedbackItem.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil)
    helpMenu.addItem(feedbackItem)

    helpMenu.addItem(NSMenuItem.separator())

    let websiteItem = NSMenuItem(
      title: "Website",
      action: #selector(openWebsite(_:)),
      keyEquivalent: ""
    )
    websiteItem.target = self
    websiteItem.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
    helpMenu.addItem(websiteItem)

    let githubItem = NSMenuItem(
      title: "GitHub",
      action: #selector(openGitHub(_:)),
      keyEquivalent: ""
    )
    githubItem.target = self
    githubItem.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
    helpMenu.addItem(githubItem)

    let xItem = NSMenuItem(
      title: "Updates on X",
      action: #selector(openX(_:)),
      keyEquivalent: ""
    )
    xItem.target = self
    xItem.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
    helpMenu.addItem(xItem)

    helpMenu.addItem(NSMenuItem.separator())

    let statusPageItem = NSMenuItem(
      title: "Status Page",
      action: #selector(openStatusPage(_:)),
      keyEquivalent: ""
    )
    statusPageItem.target = self
    statusPageItem.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)
    helpMenu.addItem(statusPageItem)

    helpMenu.addItem(NSMenuItem.separator())

    let clearCacheItem = NSMenuItem(
      title: "Reset Local Data…",
      action: #selector(clearCache(_:)),
      keyEquivalent: ""
    )
    clearCacheItem.target = self
    clearCacheItem.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil)
    helpMenu.addItem(clearCacheItem)
  }

  @objc private func showPreferences(_ sender: Any?) {
    guard let dependencies else { return }
    dependencies.appBridge.openSettings(dependencies: dependencies, sender: sender)
  }

  @MainActor @objc private func newWindow(_ sender: Any?) {
    (NSApp.delegate as? AppDelegate)?.openNewMainWindow(sender)
  }

  @MainActor @objc private func newThread(_ sender: Any?) {
    MainWindowOpenCoordinator.shared.createNewThread()
  }

  @MainActor @objc private func newTab(_ sender: Any?) {
    MainWindowOpenCoordinator.shared.openTab()
  }

  @objc private func logOut(_ sender: Any?) {
    let alert = NSAlert()
    alert.messageText = "Log Out"
    alert.informativeText = "Are you sure you want to log out?"
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning
    let button = alert.addButton(withTitle: "Log Out")
    button.hasDestructiveAction = true

    if alert.runModal() == .alertSecondButtonReturn {
      Task { @MainActor in
        await self.dependencies?.logOut()
      }
    }
  }

  @objc private func clearCache(_ sender: Any?) {
    AppRecoveryActions.clearCache(confirming: true)
  }

  @objc private func openDocs(_ sender: Any?) {
    openURL("https://inline.chat/docs")
  }

  @objc private func openWhatsNew(_ sender: Any?) {
    openURL("https://inline.chat/docs/changelog")
  }

  @objc private func openPreviousVersions(_ sender: Any?) {
    openURL("https://inline.chat/docs/downloads/previous")
  }

  @objc private func sendFeedback(_ sender: Any?) {
    openURL("https://inline.chat/feedback")
  }

  @objc private func openWebsite(_ sender: Any?) {
    openURL("https://inline.chat")
  }

  @objc private func openGitHub(_ sender: Any?) {
    openURL("https://github.com/inline-chat")
  }

  @objc private func openX(_ sender: Any?) {
    openURL("https://x.com/InlineChat")
  }

  @objc private func openStatusPage(_ sender: Any?) {
    openURL("https://status.inline.chat/")
  }

  private func openURL(_ string: String) {
    guard let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func toggleAlwaysOnTop(_ sender: NSMenuItem) {
    guard let window = NSApp.keyWindow else { return }

    if window.level == .floating {
      window.level = .normal
      sender.state = .off
    } else {
      window.level = .floating
      sender.state = .on
    }
  }

  @objc private func openMacDevtools(_ sender: Any?) {
    MacDevtoolsWindowController.show(sender: sender)
  }

#if DEBUG || DEBUG_BUILD
  @objc private func openDeveloperPlayground(_ sender: Any?) {
    DeveloperPlaygroundWindowController.show(sender: sender)
  }

#endif

  @objc private func showAllTabs(_ sender: Any?) {
    guard let window = tabOverviewWindow() else { return }
    window.toggleTabOverview(sender)
  }

  private func activeWindow() -> NSWindow? {
    NSApp.keyWindow ?? NSApp.mainWindow
  }

  @objc private func performUndo(_ sender: Any?) {
    performUndoTransition(.undo, sender: sender)
  }

  @objc private func performRedo(_ sender: Any?) {
    performUndoTransition(.redo, sender: sender)
  }

  private func performUndoTransition(_ direction: UndoDirection, sender: Any?) {
    guard let window = activeWindow() else { return }
    if window.firstResponder is any NSTextInputClient {
      // Never fall through to semantic history from an editor. Even if native
      // undo has no target or fails, the application action stays untouched.
      _ = NSApp.sendAction(direction.nativeSelector, to: nil, from: sender)
      return
    }

    guard let dependencies else { return }
    Task {
      switch direction {
      case .undo:
        await dependencies.appUndo.undo(using: dependencies)
      case .redo:
        await dependencies.appUndo.redo(using: dependencies)
      }
    }
  }

  private enum UndoDirection {
    case undo
    case redo

    var nativeSelector: Selector {
      switch self {
      case .undo: Selector(("undo:"))
      case .redo: Selector(("redo:"))
      }
    }
  }

  private func tabOverviewWindow() -> NSWindow? {
    let candidates = [activeWindow()] + NSApp.windows
    return candidates.compactMap { $0 }.first { ($0.tabGroup?.windows.count ?? 0) > 1 }
      ?? activeWindow()
  }

  @objc private func toggleSidebar(_ sender: NSMenuItem) {
    if MainWindowOpenCoordinator.shared.toggleSidebar() == false {
      NotificationCenter.default.post(name: .toggleSidebar, object: nil)
    }
  }

  @objc private func toggleNativeTabBar(_ sender: NSMenuItem) {
    guard let window = activeWindow() else { return }
    window.toggleTabBar(sender)
    sender.state = window.tabGroup?.isTabBarVisible == true ? .on : .off
  }

  @objc private func toggleQuickSearch(_ sender: NSMenuItem) {
    MainWindowOpenCoordinator.shared.toggleCommandBar()
  }

  // MARK: - Navigation Actions

  @objc private func goBack(_ sender: Any?) {
    let coordinator = MainWindowOpenCoordinator.shared
    if coordinator.hasActiveWindow {
      coordinator.goBack()
      return
    }

    if let nav2 = dependencies?.nav2 {
      nav2.goBack()
      return
    }

    dependencies?.nav.goBack()
  }

  @objc private func goForward(_ sender: Any?) {
    let coordinator = MainWindowOpenCoordinator.shared
    if coordinator.hasActiveWindow {
      coordinator.goForward()
      return
    }

    if let nav2 = dependencies?.nav2 {
      nav2.goForward()
      return
    }

    dependencies?.nav.goForward()
  }

  // MARK: - Chat Navigation Actions

  @objc private func prevChat(_ sender: Any?) {
    if MainWindowOpenCoordinator.shared.navigateChat(offset: -1) == false {
      NotificationCenter.default.post(name: .prevChat, object: nil)
    }
  }

  @objc private func nextChat(_ sender: Any?) {
    if MainWindowOpenCoordinator.shared.navigateChat(offset: 1) == false {
      NotificationCenter.default.post(name: .nextChat, object: nil)
    }
  }

  @objc private func performChatCommand(_ sender: NSMenuItem) {
    guard let command = ChatMenuCommand(rawValue: sender.tag) else { return }
    MainWindowOpenCoordinator.shared.performChatMenuCommand(command)
  }

  @objc private func selectHomeSpace(_ sender: Any?) {
    MainWindowOpenCoordinator.shared.activeSpaceMenuContext?.selectHome()
  }

  @objc private func selectSpace(_ sender: NSMenuItem) {
    guard let id = (sender.representedObject as? NSNumber)?.int64Value else { return }
    MainWindowOpenCoordinator.shared.activeSpaceMenuContext?.selectSpace(id)
  }

  @objc private func createSpace(_ sender: Any?) {
    MainWindowOpenCoordinator.shared.activeSpaceMenuContext?.createSpace()
  }

  @objc private func showSpaceSettings(_ sender: Any?) {
    guard let context = MainWindowOpenCoordinator.shared.activeSpaceMenuContext,
          let id = context.selectedSpaceID
    else { return }
    context.showSettings(id)
  }

  @objc private func showSpaceMembers(_ sender: Any?) {
    guard let context = MainWindowOpenCoordinator.shared.activeSpaceMenuContext,
          let id = context.selectedSpaceID
    else { return }
    context.showMembers(id)
  }

  @objc private func inviteToSpace(_ sender: Any?) {
    guard let context = MainWindowOpenCoordinator.shared.activeSpaceMenuContext else { return }
    context.invitePeople(context.selectedSpaceID)
  }

  @objc private func showSpaceIntegrations(_ sender: Any?) {
    guard let context = MainWindowOpenCoordinator.shared.activeSpaceMenuContext,
          let id = context.selectedSpaceID
    else { return }
    context.showIntegrations(id)
  }

  @objc private func showSpaceGrid(_ sender: Any?) {
    guard let context = MainWindowOpenCoordinator.shared.activeSpaceMenuContext,
          let id = context.selectedSpaceID
    else { return }
    context.showGrid(id)
  }

  @objc private func selectAppearance(_ sender: NSMenuItem) {
    guard AppAppearance.pickerOrder.indices.contains(sender.tag) else { return }
    AppSettings.shared.appearance = AppAppearance.pickerOrder[sender.tag]
  }

  @objc private func selectTheme(_ sender: NSMenuItem) {
    guard AppThemePreset.allCases.indices.contains(sender.tag) else { return }
    AppSettings.shared.appTheme = AppThemePreset.allCases[sender.tag]
  }

  @objc private func selectMessageStyle(_ sender: NSMenuItem) {
    guard MessageRenderStyle.allCases.indices.contains(sender.tag) else { return }
    AppSettings.shared.messageRenderStyle = MessageRenderStyle.allCases[sender.tag]
  }

  @objc private func toggleCompactToolbar(_ sender: Any?) {
    AppSettings.shared.usesCompactToolbar.toggle()
  }

  @objc private func toggleSidebarTint(_ sender: Any?) {
    AppSettings.shared.sidebarGlassAndTintEnabled.toggle()
  }

  @objc private func selectSidebarMode(_ sender: NSMenuItem) {
    guard SidebarMode.allCases.indices.contains(sender.tag) else { return }
    AppSettings.shared.sidebarMode = SidebarMode.allCases[sender.tag]
  }

  @objc private func selectSidebarItemSize(_ sender: NSMenuItem) {
    guard SidebarItemSize.allCases.indices.contains(sender.tag) else { return }
    AppSettings.shared.sidebarItemSize = SidebarItemSize.allCases[sender.tag]
  }

  @objc private func selectSidebarSort(_ sender: NSMenuItem) {
    guard SidebarSortMode.allCases.indices.contains(sender.tag) else { return }
    let mode = SidebarSortMode.allCases[sender.tag]
    guard AppSettings.shared.sidebarMode != .allChats || mode == .recentActivity else { return }
    AppSettings.shared.sidebarSort = mode
  }

  @objc private func selectSidebarCleanupInterval(_ sender: NSMenuItem) {
    guard SidebarCleanupInterval.allCases.indices.contains(sender.tag) else { return }
    AppSettings.shared.sidebarCleanupInterval = SidebarCleanupInterval.allCases[sender.tag]
  }

  @objc private func toggleReplyThreadSidePane(_ sender: Any?) {
    AppSettings.shared.openReplyThreadsInSidePane.toggle()
  }

  @objc private func toggleDockBadge(_ sender: Any?) {
    AppSettings.shared.showDockBadgeUnreadDMs.toggle()
  }

#if SPARKLE
  @MainActor @objc private func handleUpdateMenuAction(_ sender: Any?) {
    guard let dependencies else { return }
    dependencies.updates.performPrimaryAction()
  }

  @MainActor private func bindUpdateMenuItemState() {
    guard let dependencies else { return }
    withObservationTracking {
      applyUpdateMenuItemState(
        dependencies.updates.phase,
        enabled: dependencies.updates.allowsPrimaryAction
      )
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.bindUpdateMenuItemState()
      }
    }
  }

  private func applyUpdateMenuItemState(_ phase: SoftwareUpdatePhase, enabled: Bool) {
    updateMenuItem?.title = phase.menuTitle
    updateMenuItemEnabled = enabled
#if DEBUG
    assertUpdateMenuItemBinding(phase)
#endif
  }

#if DEBUG
  private func assertUpdateMenuItemBinding(_ phase: SoftwareUpdatePhase) {
    if let updateMenuItem {
      assert(
        updateMenuItem.title == phase.menuTitle,
        "Update menu title must mirror SoftwareUpdatePhase.menuTitle"
      )
    }
    if let previousPhase = lastAppliedUpdatePhase {
      let titleTransitioned = previousPhase.menuTitle != phase.menuTitle
      if titleTransitioned, let updateMenuItem {
        assert(
          updateMenuItem.title == phase.menuTitle,
          "Update menu title must refresh when status title changes"
        )
      }
    }
    lastAppliedUpdatePhase = phase
  }
#endif
#endif

  @MainActor @objc private func handleCLIInstallerMenuAction(_ sender: Any?) {
    installCLI(sender: sender)
  }

  @MainActor func installCLI(sender: Any? = nil) {
    guard let dependencies else { return }
    CLIInstallerWindowController.show(using: dependencies, sender: sender)
  }

  @MainActor @objc private func handleAgentSetupMenuAction(_ sender: Any?) {
    guard let dependencies else { return }
    AgentSetupWindowController.show(using: dependencies, sender: sender)
  }

  @MainActor private func bindCLIInstallerMenuItemState() {
    guard let dependencies else { return }
    withObservationTracking {
      let phase = dependencies.cliInstaller.phase
      cliInstallerMenuItem?.title = phase.menuTitle
      cliInstallerMenuItemEnabled = phase.allowsPrimaryAction
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.bindCLIInstallerMenuItemState()
      }
    }
  }

}

extension AppMenu: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu === spaceMenu else { return }
    menu.removeAllItems()

    guard let context = MainWindowOpenCoordinator.shared.activeSpaceMenuContext else {
      let unavailable = NSMenuItem(title: "No Active Space", action: nil, keyEquivalent: "")
      unavailable.isEnabled = false
      menu.addItem(unavailable)
      return
    }

    let selectedSpace = context.selectedSpaceID.flatMap { selectedID in
      context.spaces.first { $0.id == selectedID }
    }
    let contextTitle = context.selectedSpaceID == nil ? "Home" : selectedSpace?.name ?? "Space"
    menu.addItem(.sectionHeader(title: contextTitle))

    let newThread = NSMenuItem(title: "New Thread", action: #selector(newThread(_:)), keyEquivalent: "")
    newThread.target = self
    menu.addItem(newThread)

    if context.selectedSpaceID != nil {
      let settings = NSMenuItem(title: "Space Settings…", action: #selector(showSpaceSettings(_:)), keyEquivalent: "")
      settings.target = self
      menu.addItem(settings)

      let members = NSMenuItem(title: "Members", action: #selector(showSpaceMembers(_:)), keyEquivalent: "")
      members.target = self
      menu.addItem(members)

      let integrations = NSMenuItem(title: "Integrations", action: #selector(showSpaceIntegrations(_:)), keyEquivalent: "")
      integrations.target = self
      menu.addItem(integrations)

      let grid = NSMenuItem(title: "Grid", action: #selector(showSpaceGrid(_:)), keyEquivalent: "")
      grid.target = self
      menu.addItem(grid)
    }

    let invite = NSMenuItem(title: "Invite…", action: #selector(inviteToSpace(_:)), keyEquivalent: "")
    invite.target = self
    menu.addItem(invite)

    menu.addItem(NSMenuItem.separator())

    let switchSpaceMenu = NSMenu(title: "Switch Space")
    let home = NSMenuItem(title: "Home", action: #selector(selectHomeSpace(_:)), keyEquivalent: "")
    home.target = self
    home.subtitle = "Your main chat list"
    home.state = context.selectedSpaceID == nil ? .on : .off
    switchSpaceMenu.addItem(home)

    if context.spaces.isEmpty == false {
      switchSpaceMenu.addItem(NSMenuItem.separator())
    }

    for space in context.spaces {
      let item = NSMenuItem(title: space.name, action: #selector(selectSpace(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = NSNumber(value: space.id)
      item.identifier = NSUserInterfaceItemIdentifier("space.select.\(space.id)")
      item.state = context.selectedSpaceID == space.id ? .on : .off
      switchSpaceMenu.addItem(item)
    }

    let switchSpace = NSMenuItem(title: "Switch Space", action: nil, keyEquivalent: "")
    switchSpace.submenu = switchSpaceMenu
    menu.addItem(switchSpace)

    let create = NSMenuItem(title: "Create Space…", action: #selector(createSpace(_:)), keyEquivalent: "")
    create.target = self
    menu.addItem(create)
  }
}

extension AppMenu: NSMenuItemValidation {
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let dependencies else { return false }

#if SPARKLE
    if menuItem == updateMenuItem {
      return updateMenuItemEnabled
    }
#endif

    if menuItem == cliInstallerMenuItem {
      return cliInstallerMenuItemEnabled
    }

    if menuItem === closeWindowMenuItem {
      guard let window = activeWindow() else { return false }
      menuItem.title = (window.tabGroup?.windows.count ?? 0) > 1 ? "Close Tab" : "Close Window"
      return true
    }

    if menuItem === undoMenuItem {
      return validateUndoMenuItem(menuItem, direction: .undo, dependencies: dependencies)
    }
    if menuItem === redoMenuItem {
      return validateUndoMenuItem(menuItem, direction: .redo, dependencies: dependencies)
    }

    if let command = ChatMenuCommand(rawValue: menuItem.tag), chatMenuItems[command] === menuItem {
      guard let context = MainWindowOpenCoordinator.shared.activeChatMenuContext else {
        menuItem.title = ChatMenuContext.placeholderTitle(for: command)
        menuItem.state = .off
        return false
      }
      menuItem.title = context.title(for: command)
      switch command {
      case .toggleFollow:
        menuItem.state = context.isFollowing ? .on : .off
      case .togglePin:
        menuItem.state = context.isPinned ? .on : .off
      case .toggleArchive:
        menuItem.state = context.isArchived ? .on : .off
      default:
        menuItem.state = .off
      }
      if command == .rename {
        return context.isEnabled(command) && MainWindowOpenCoordinator.shared.canRenameThread
      }
      return context.isEnabled(command)
    }

    let settings = AppSettings.shared
    if menuItem.action == #selector(selectAppearance(_:)) {
      guard AppAppearance.pickerOrder.indices.contains(menuItem.tag) else { return false }
      menuItem.state = settings.appearance == AppAppearance.pickerOrder[menuItem.tag] ? .on : .off
      return true
    }
    if menuItem.action == #selector(selectTheme(_:)) {
      guard AppThemePreset.allCases.indices.contains(menuItem.tag) else { return false }
      menuItem.state = settings.appTheme == AppThemePreset.allCases[menuItem.tag] ? .on : .off
      return true
    }
    if menuItem.action == #selector(selectMessageStyle(_:)) {
      guard MessageRenderStyle.allCases.indices.contains(menuItem.tag) else { return false }
      menuItem.state = settings.messageRenderStyle == MessageRenderStyle.allCases[menuItem.tag] ? .on : .off
      return true
    }
    if menuItem.action == #selector(toggleCompactToolbar(_:)) {
      menuItem.state = settings.usesCompactToolbar ? .on : .off
      return true
    }
    if menuItem.action == #selector(toggleSidebarTint(_:)) {
      menuItem.state = settings.sidebarGlassAndTintEnabled ? .on : .off
      return true
    }
    if menuItem.action == #selector(selectSidebarMode(_:)) {
      guard SidebarMode.allCases.indices.contains(menuItem.tag) else { return false }
      menuItem.state = settings.sidebarMode == SidebarMode.allCases[menuItem.tag] ? .on : .off
      return true
    }
    if menuItem.action == #selector(selectSidebarItemSize(_:)) {
      guard SidebarItemSize.allCases.indices.contains(menuItem.tag) else { return false }
      menuItem.state = settings.sidebarItemSize == SidebarItemSize.allCases[menuItem.tag] ? .on : .off
      return true
    }
    if menuItem.action == #selector(selectSidebarSort(_:)) {
      guard SidebarSortMode.allCases.indices.contains(menuItem.tag) else { return false }
      let mode = SidebarSortMode.allCases[menuItem.tag]
      let effectiveMode: SidebarSortMode = settings.sidebarMode == .allChats ? .recentActivity : settings.sidebarSort
      menuItem.state = effectiveMode == mode ? .on : .off
      return settings.sidebarMode != .allChats || mode == .recentActivity
    }
    if menuItem.action == #selector(selectSidebarCleanupInterval(_:)) {
      guard SidebarCleanupInterval.allCases.indices.contains(menuItem.tag) else { return false }
      menuItem.state = settings.sidebarCleanupInterval == SidebarCleanupInterval.allCases[menuItem.tag] ? .on : .off
      return true
    }
    if menuItem.action == #selector(toggleReplyThreadSidePane(_:)) {
      menuItem.state = settings.openReplyThreadsInSidePane ? .on : .off
      return true
    }
    if menuItem.action == #selector(toggleDockBadge(_:)) {
      menuItem.state = settings.showDockBadgeUnreadDMs ? .on : .off
      return true
    }

    if menuItem.action == #selector(prevChat(_:)) || menuItem.action == #selector(nextChat(_:)) {
      if MainWindowOpenCoordinator.shared.canNavigateChat {
        return true
      }
      if dependencies.nav2 != nil {
        return true
      }
      let nav = dependencies.nav
      return nav.selectedTab == .inbox || nav.selectedTab == .archive
    }

    if menuItem.action == #selector(newThread(_:)) {
      return dependencies.auth.currentUserId != nil && dependencies.viewModel.topLevelRoute == .main
    }

    if menuItem.action == #selector(goBack(_:)) {
      let coordinator = MainWindowOpenCoordinator.shared
      if coordinator.hasActiveWindow {
        return coordinator.canGoBack
      }
      if let nav2 = dependencies.nav2 {
        return nav2.canGoBack
      }
      return dependencies.nav.canGoBack
    }

    if menuItem.action == #selector(goForward(_:)) {
      let coordinator = MainWindowOpenCoordinator.shared
      if coordinator.hasActiveWindow {
        return coordinator.canGoForward
      }
      if let nav2 = dependencies.nav2 {
        return nav2.canGoForward
      }
      return dependencies.nav.canGoForward
    }

    if menuItem.action == #selector(toggleNativeTabBar(_:)) || menuItem == tabBarMenuItem {
      guard let window = activeWindow() else { return false }
      menuItem.state = window.tabGroup?.isTabBarVisible == true ? .on : .off
      return true
    }

    if menuItem.action == #selector(showAllTabs(_:)) {
      guard let window = tabOverviewWindow() else { return false }
      return (window.tabGroup?.windows.count ?? 0) > 1
    }

    return true
  }

  private func validateUndoMenuItem(
    _ menuItem: NSMenuItem,
    direction: UndoDirection,
    dependencies: AppDependencies
  ) -> Bool {
    if let window = activeWindow(), window.firstResponder is any NSTextInputClient {
      let undoManager = window.firstResponder?.undoManager ?? window.undoManager
      switch direction {
      case .undo:
        menuItem.title = undoManager?.undoMenuItemTitle ?? "Undo"
        return undoManager?.canUndo == true
      case .redo:
        menuItem.title = undoManager?.redoMenuItemTitle ?? "Redo"
        return undoManager?.canRedo == true
      }
    }

    switch direction {
    case .undo:
      menuItem.title = dependencies.appUndo.undoMenuTitle
      return dependencies.appUndo.canUndo
    case .redo:
      menuItem.title = dependencies.appUndo.redoMenuTitle
      return dependencies.appUndo.canRedo
    }
  }
}
