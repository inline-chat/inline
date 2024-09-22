//
//  AppDelegate.swift
//  Inline
//
//  Created by Mohammad Rajabifard on 9/22/24.
//

import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create a SwiftUI view
        let contentView = ContentView(hideTitlebar: { [weak self] in
            self?.mainWindow.titleVisibility = .hidden
        })

        // Create the NSWindow
        mainWindow = NSWindow(contentRect: NSMakeRect(0, 0, 500, 300), // Window position and size
                              styleMask: [.titled, .closable, .resizable, .unifiedTitleAndToolbar, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        mainWindow.isMovableByWindowBackground = true
        mainWindow.title = "Inline"
        mainWindow.isOpaque = false
        mainWindow.backgroundColor = .windowBackgroundColor.withAlphaComponent(0.1)

        mainWindow.titlebarAppearsTransparent = true
        mainWindow.isOpaque = false
        mainWindow.backgroundColor = .clear
        

        // Create a visual effect view for the blur effect
        let visualEffectView = NSVisualEffectView()
        visualEffectView.state = .active
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.material = .fullScreenUI // You can experiment with different materials

        // Create a hosting view for the SwiftUI content
        let hostingView = NSHostingView(rootView: contentView)

        // Set up the visual effect view as the content view
        mainWindow.contentView = visualEffectView

        // Add the hosting view as a subview of the visual effect view
        visualEffectView.addSubview(hostingView)

        // Make the hosting view fill the visual effect view
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])

        mainWindow.center() // Center the window
        mainWindow.setFrameAutosaveName("main") // Save window size/position
        mainWindow.makeKeyAndOrderFront(nil) // Show the window
    }
}
