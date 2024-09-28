//
//  AppDelegate.swift
//  Inline
//
//  Created by Mohammad Rajabifard on 9/22/24.
//

import AppKit
import SwiftUI

class AppActions: ObservableObject {
    var clearToolbar: () -> Void
    var setUpToolbar: () -> Void

    init(
        clearToolbar: @escaping () -> Void,
        setUpToolbar: @escaping () -> Void
    ) {
        self.clearToolbar = clearToolbar
        self.setUpToolbar = setUpToolbar
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: NSWindow!
    var toolbar: NSToolbar!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup menus
        setUpMainMenu()

        // Create a SwiftUI view
        let contentView = MainWindowContent().environmentObject(AppActions(clearToolbar: clearToolbar, setUpToolbar: setUpToolbar))

        // Create the NSWindow
        mainWindow = NSWindow(contentRect: NSMakeRect(0, 0, 500, 300), // Window position and size
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .unifiedTitleAndToolbar, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        mainWindow.isMovableByWindowBackground = true
        mainWindow.title = "Inline"
        mainWindow.isOpaque = false
        mainWindow.backgroundColor = .windowBackgroundColor.withAlphaComponent(0.1)
        mainWindow.titleVisibility = .hidden
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.isOpaque = false
        mainWindow.backgroundColor = .clear

        // Add toolbar
//        setUpToolbar()

        // Translucent
        let visualEffectView = NSVisualEffectView()
        visualEffectView.state = .active
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.material = .popover

        // Create a hosting view for the SwiftUI content
        let hostingView = NSHostingView(rootView: contentView)
        mainWindow.contentView = visualEffectView
        visualEffectView.addSubview(hostingView)

        // Make the hosting view fill the visual effect view
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])

        mainWindow.center()
        mainWindow.setFrameAutosaveName("Main")
        mainWindow.makeKeyAndOrderFront(nil) // Show the window
    }

    func clearToolbar() {
        mainWindow.toolbar = nil
        mainWindow.toolbarStyle = .automatic
    }

    func setUpToolbar() {
        toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.delegate = self

        mainWindow.toolbar = toolbar
        mainWindow.toolbarStyle = .unified
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

extension AppDelegate: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar:
            return NSToolbarItem(itemIdentifier: .toggleSidebar)
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
    }

//    @objc func newItemAction() {
//        print("New item action")
//        // Implement your new item action here
//    }
}
