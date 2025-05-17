import AppKit
import InlineKit

final class AppMenu: NSObject {
  static let shared = AppMenu()
  private let mainMenu = NSMenu()
  private var dependencies: AppDependencies?

  override private init() {
    super.init()
  }

  func setupMainMenu(dependencies: AppDependencies) {
    self.dependencies = dependencies
    NSApp.mainMenu = mainMenu

    setupApplicationMenu()
    setupFileMenu()
    setupEditMenu()
    setupViewMenu()
    setupWindowMenu()
  }

  private func setupApplicationMenu() {
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

    appMenu.addItem(NSMenuItem.separator())

    let servicesMenu = NSMenu()
    let servicesMenuItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    servicesMenuItem.submenu = servicesMenu
    appMenu.addItem(servicesMenuItem)
    NSApp.servicesMenu = servicesMenu

//    appMenu.addItem(NSMenuItem.separator())
//
//    appMenu.addItem(withTitle: "Preferences…",
//                    action: #selector(showPreferences),
//                    keyEquivalent: ",")

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

    let logoutMenuItem = NSMenuItem(
      title: "Log Out…",
      action: #selector(logOut(_:)),
      keyEquivalent: ""
    )
    logoutMenuItem.target = self
    appMenu.addItem(logoutMenuItem)

    let clearCacheMenuItem = NSMenuItem(
      title: "Clear Cache…",
      action: #selector(clearCache(_:)),
      keyEquivalent: ""
    )
    clearCacheMenuItem.target = self
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
  }

  private func setupViewMenu() {
    let viewMenu = NSMenu(title: "View")
    let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
    viewMenuItem.submenu = viewMenu
    mainMenu.addItem(viewMenuItem)

    viewMenu.addItem(
      withTitle: "Toggle Full Screen",
      action: #selector(NSWindow.toggleFullScreen(_:)),
      keyEquivalent: "f"
    )
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

    windowMenu.addItem(NSMenuItem.separator())

    let alwaysOnTopItem = NSMenuItem(
      title: "Always on Top",
      action: #selector(toggleAlwaysOnTop(_:)),
      keyEquivalent: "t"
    )
    alwaysOnTopItem.keyEquivalentModifierMask = [.command, .option]
    alwaysOnTopItem.target = self
    windowMenu.addItem(alwaysOnTopItem)

    windowMenu.addItem(NSMenuItem.separator())

    windowMenu.addItem(
      withTitle: "Bring All to Front",
      action: #selector(NSApplication.arrangeInFront(_:)),
      keyEquivalent: ""
    )

    NSApp.windowsMenu = windowMenu
  }

  @objc private func showPreferences(_ sender: Any?) {
    // Implement your preferences window display logic here
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
    Transactions.shared.clearAll()

    // Clear database
    try? AppDatabase.clearDB()

    // TODO: re-open windows?
  }

  @objc private func clearMediaCache(_ sender: Any?) {
    Task {
      try await FileCache.shared.clearCache()
    }
  }

  @objc private func resetDismissedPopovers(_ sender: Any?) {
    Task {
      await TranslationAlertDismiss.shared.resetAllDismissStates()
    }
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
}
