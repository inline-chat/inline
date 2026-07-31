import AppKit
import InlineCLIInstaller
import InlineKit
import MacDevtools
import Observation
import Translation

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
  private weak var cliInstallerMenuItem: NSMenuItem?
  private var cliInstallerMenuItemEnabled = true
  private weak var tabBarMenuItem: NSMenuItem?
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
    NSApp.mainMenu = mainMenu

    setupApplicationMenu()
    setupFileMenu()
    setupEditMenu()
    setupViewMenu()
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

    appMenu.addItem(NSMenuItem.separator())

    let servicesMenu = NSMenu()
    let servicesMenuItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    servicesMenuItem.submenu = servicesMenu
    appMenu.addItem(servicesMenuItem)
    NSApp.servicesMenu = servicesMenu

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

    let clearCacheMenuItem = NSMenuItem(
      title: "Clear Cache…",
      action: #selector(clearCache(_:)),
      keyEquivalent: ""
    )
    clearCacheMenuItem.target = self
    clearCacheMenuItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
    appMenu.addItem(clearCacheMenuItem)

    let clearMediaCacheMenuItem = NSMenuItem(
      title: "Clear Media Cache…",
      action: #selector(clearMediaCache(_:)),
      keyEquivalent: ""
    )
    clearMediaCacheMenuItem.target = self
    appMenu.addItem(clearMediaCacheMenuItem)

    let resetDismissedPopoversMenuItem = NSMenuItem(
      title: "Reset Dismissed Popovers…",
      action: #selector(resetDismissedPopovers(_:)),
      keyEquivalent: ""
    )
    resetDismissedPopoversMenuItem.target = self
    appMenu.addItem(resetDismissedPopoversMenuItem)

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

    fileMenu.addItem(
      withTitle: "Close Window",
      action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "w"
    )
  }

  private func setupEditMenu() {
    let editMenu = NSMenu(title: "Edit")
    let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    // Undo/Redo
    editMenu.addItem(
      withTitle: "Undo",
      action: Selector(("undo:")),
      keyEquivalent: "z"
    )
    editMenu.addItem(
      withTitle: "Redo",
      action: Selector(("redo:")),
      keyEquivalent: "Z"
    )

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
    editMenu.addItem(
      withTitle: "Bold",
      action: #selector(ComposeNSTextView.toggleBold(_:)),
      keyEquivalent: "b"
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

    viewMenu.addItem(NSMenuItem.separator())

    // Navigation between chats in sidebar
    let prevChatItem = NSMenuItem(
      title: "Previous Chat",
      action: #selector(prevChat(_:)),
      keyEquivalent: String(UnicodeScalar(NSEvent.SpecialKey.upArrow.rawValue)!)
    )
    prevChatItem.keyEquivalentModifierMask = [.option]
    prevChatItem.target = self
    prevChatItem.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)
    viewMenu.addItem(prevChatItem)

    let nextChatItem = NSMenuItem(
      title: "Next Chat",
      action: #selector(nextChat(_:)),
      keyEquivalent: String(UnicodeScalar(NSEvent.SpecialKey.downArrow.rawValue)!)
    )
    nextChatItem.keyEquivalentModifierMask = [.option]
    nextChatItem.target = self
    nextChatItem.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
    viewMenu.addItem(nextChatItem)
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
    guard confirm(
      title: "Clear Cache",
      message: "This clears local cached app data and sync state. Inline will reload your account from the server."
    ) else { return }

    Task { @MainActor in
      guard let appDelegate = NSApp.delegate as? AppDelegate else {
        ToastCenter.shared.showError("Failed to clear cache")
        return
      }

      do {
        try await appDelegate.clearCacheAndResetApp()
        ToastCenter.shared.showSuccess("Cache cleared")
      } catch {
        ToastCenter.shared.showError("Failed to clear cache")
      }
    }
  }

  @objc private func clearMediaCache(_ sender: Any?) {
    Task {
      try await FileCache.shared.clearCache()
    }
  }

  @objc private func resetDismissedPopovers(_ sender: Any?) {
    TranslationAlertDismiss.shared.resetAllDismissStates()
  }

  @objc private func openDocs(_ sender: Any?) {
    openURL("https://inline.chat/docs")
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

  private func confirm(title: String, message: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning
    let button = alert.addButton(withTitle: title)
    button.hasDestructiveAction = true
    return alert.runModal() == .alertSecondButtonReturn
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

  @objc private func showAllTabs(_ sender: Any?) {
    guard let window = tabOverviewWindow() else { return }
    window.toggleTabOverview(sender)
  }

  private func activeWindow() -> NSWindow? {
    NSApp.keyWindow ?? NSApp.mainWindow
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
    guard let dependencies else { return }

    Task { @MainActor [weak self] in
      let result = await dependencies.cliInstaller.install()
      await self?.presentCLIInstallResult(result)
    }
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

  @MainActor private func presentCLIInstallResult(_ result: CLIInstallResult) async {
    switch result {
    case let .installed(installation):
      await presentCLIInstallSuccess(installation, alreadyInstalled: false)
    case let .alreadyInstalled(installation):
      await presentCLIInstallSuccess(installation, alreadyInstalled: true)
    case let .failed(failure):
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = failure.title
      alert.informativeText = failure.message
      alert.addButton(withTitle: "Install Manually")
      alert.addButton(withTitle: "OK")
      if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.open(failure.recoveryURL)
      }
    }
  }

  @MainActor private func presentCLIInstallSuccess(
    _ installation: CLIInstallation,
    alreadyInstalled: Bool
  ) async {
    guard let dependencies else { return }

    guard CLIAuthBootstrapper.isSupportedInCurrentProcess else {
      presentCLIAuthFallback(
        installation,
        alreadyInstalled: alreadyInstalled,
        reason: "Automatic sign-in is not available in this build of Inline for Mac."
      )
      return
    }

    guard dependencies.auth.getIsLoggedIn() else {
      presentCLIAuthFallback(
        installation,
        alreadyInstalled: alreadyInstalled,
        reason: "Inline for Mac is not signed in."
      )
      return
    }

    do {
      let result = try await authenticateCLI(installation, dependencies: dependencies)
      presentCLIInstallCompletion(
        installation,
        alreadyInstalled: alreadyInstalled,
        authentication: result
      )
    } catch {
      presentCLIAuthFallback(
        installation,
        alreadyInstalled: alreadyInstalled,
        reason: error.localizedDescription
      )
    }
  }

  @MainActor private func presentCLIInstallCompletion(
    _ installation: CLIInstallation,
    alreadyInstalled: Bool,
    authentication: CLIAuthBootstrapResult
  ) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = alreadyInstalled ? "Inline CLI Is Ready" : "Inline CLI Installed and Signed In"

    let version = installation.version.map { " version \($0)" } ?? ""
    var details = "Inline CLI\(version) is available at:\n\(installation.executableURL.path)"
    details += "\n\nThe CLI is signed in with its own revocable Inline session."
    if let warning = authentication.warning {
      details += "\n\n\(warning)"
    }
    if !installation.isOnPath {
      details += "\n\nIts directory is not currently on PATH. See the installation guide for shell setup."
    }
    alert.informativeText = details
    alert.addButton(withTitle: "Done")
    if !installation.isOnPath {
      alert.addButton(withTitle: "Installation Guide")
    }

    let response = alert.runModal()
    if !installation.isOnPath, response == .alertSecondButtonReturn {
      NSWorkspace.shared.open(CLIInstallerConfiguration.production.documentationURL)
    }
  }

  @MainActor private func presentCLIAuthFallback(
    _ installation: CLIInstallation,
    alreadyInstalled: Bool,
    reason: String
  ) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = alreadyInstalled
      ? "Inline CLI Sign-In Needed"
      : "Inline CLI Installed — Sign-In Needed"
    alert.informativeText = """
    Automatic sign-in could not finish: \(reason)

    Run this command in Terminal:
    \(manualLoginCommand(for: installation))

    If that does not work, follow the online CLI guide.
    """
    alert.addButton(withTitle: "Open CLI Guide")
    alert.addButton(withTitle: "Done")
    if alert.runModal() == .alertFirstButtonReturn {
      NSWorkspace.shared.open(CLIInstallerConfiguration.production.documentationURL)
    }
  }

  private func manualLoginCommand(for installation: CLIInstallation) -> String {
    guard !installation.isOnPath else { return "inline login" }
    let escapedPath = installation.executableURL.path.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escapedPath)' login"
  }

  @MainActor private func authenticateCLI(
    _ installation: CLIInstallation,
    dependencies: AppDependencies
  ) async throws -> CLIAuthBootstrapResult {
    let bootstrapper = CLIAuthBootstrapper()
    var deliveredSessionID: Int64?
    do {
      let result = try await bootstrapper.authenticate(installation: installation) { request in
        guard let endpoint = LocalCLIAuthBroker.Endpoint(url: request.callbackURL) else {
          throw CLIAuthBootstrapError.invalidHandshake
        }
        do {
          let client = try await LocalCLIAuthBroker.probe(endpoint)
          deliveredSessionID = try await LocalCLIAuthBroker.createAndDeliverSession(
            endpoint,
            client: client,
            realtime: dependencies.realtimeV2
          )
        } catch {
          await LocalCLIAuthBroker.cancel(
            endpoint,
            detail: "Inline for Mac could not complete the request."
          )
          throw error
        }
      }
      deliveredSessionID = nil
      return result
    } catch {
      if let deliveredSessionID {
        _ = try? await dependencies.realtimeV2.revokeSession(deliveredSessionID)
      }
      throw error
    }
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
}
