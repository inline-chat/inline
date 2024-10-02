
import Cocoa

func setUpMainMenu() {
    // Create the main menu
    let mainMenu = NSMenu()
    
    // Create a menu item
    let appMenuItem = NSMenuItem(title: "Inline", action: nil, keyEquivalent: "")
    
    // Create a submenu for the Application menu
    let appMenu = NSMenu(title: "Inline")
    appMenu.addItem(NSMenuItem(title: "About", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
    appMenu.addItem(NSMenuItem.separator()) // Separator item
    appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    
    // Assign the submenu to the app menu item
    appMenuItem.submenu = appMenu
    
    // Add the app menu item to the main menu
    mainMenu.addItem(appMenuItem)
    
    // Set the main menu
    NSApplication.shared.mainMenu = mainMenu
}
