//
//  MainWindow.swift
//  Inline
//
//  Created by Mohammad Rajabifard on 9/22/24.
//

import AppKit
import Cocoa
import SwiftUI

// MARK: - Window Controller

enum MainWindowStyle {
    case onboarding
    case splitView
}

protocol MainWindowProtocol: NSWindowController {
    func setWindowStyle(_ style: MainWindowStyle) -> Void
}

class MainWindowController: NSWindowController, MainWindowProtocol {
    convenience init() {
        // Create the NSWindow
        let window = NSWindow(contentRect: NSMakeRect(0, 0, 500, 300), // Window position and size
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .unifiedTitleAndToolbar, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)

        self.init(window: window)

        // Style
        window.isMovableByWindowBackground = true
        window.title = "Inline"
        window.isOpaque = false
        window.backgroundColor = .windowBackgroundColor.withAlphaComponent(0.1)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear

        // Set the default size
        let defaultFrame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.setFrame(defaultFrame, display: true)
        window.center()
        window.minSize = NSSize(width: 200, height: 150)

        window.setFrameAutosaveName("Main")
    }

    public func setWindowStyle(_ style: MainWindowStyle) {
        switch style {
        case .onboarding:
            window?.toolbar = nil
            window?.toolbarStyle = .automatic
        case .splitView:
            let toolbar = NSToolbar(identifier: "MainToolbar")
            toolbar.displayMode = .iconOnly
            toolbar.sizeMode = .regular
//            toolbar.allowsUserCustomization = true
//            toolbar.autosavesConfiguration = true
            toolbar.delegate = self
            window?.toolbar = toolbar
            window?.toolbarStyle = .unifiedCompact
        }
    }

    func windowDidResize(_ notification: Notification) {
        updateToolbarLayout()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        updateToolbarLayout()
    }

    private func updateToolbarLayout() {
        guard let window = window,
              let contentView = window.contentView,
              let splitView = contentView.subviews.first as? NSSplitView,
              let mainContentView = splitView.subviews.last,
              let customToolbar = mainContentView.subviews.first(where: { $0 is CustomToolbar })
        else {
            return
        }

        let safeAreaInsets = contentView.safeAreaInsets

        NSLayoutConstraint.deactivate(customToolbar.constraints)

        NSLayoutConstraint.activate([
            customToolbar.topAnchor.constraint(equalTo: mainContentView.topAnchor),
            customToolbar.leadingAnchor.constraint(equalTo: mainContentView.leadingAnchor, constant: safeAreaInsets.left),
            customToolbar.trailingAnchor.constraint(equalTo: mainContentView.trailingAnchor),
            customToolbar.heightAnchor.constraint(equalToConstant: 38)
        ])
    }
}

// MARK: - App Actions

class WindowActions: ObservableObject {
    var setWindowStyle: ((_ style: MainWindowStyle) -> Void)?

    init(
        setWindowStyle: @escaping (_ style: MainWindowStyle) -> Void
    ) {
        self.setWindowStyle = setWindowStyle
    }
}

// MARK: - Toolbar

extension MainWindowController: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == .toggleSidebar {
            return NSToolbarItem(itemIdentifier: .toggleSidebar)
        }
        return nil
    }
    
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.toggleSidebar, .sidebarTrackingSeparator]
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.toggleSidebar, .sidebarTrackingSeparator]
    }
}
