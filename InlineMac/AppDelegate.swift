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
        let contentView = ContentView()

        // Create the NSWindow
        mainWindow = NSWindow(contentRect: NSMakeRect(100, 100, 400, 300), // Window position and size
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)

        mainWindow.center() // Center the window
        mainWindow.setFrameAutosaveName("main") // Save window size/position
        mainWindow.contentView = NSHostingView(rootView: contentView) // Set the root view
        mainWindow.makeKeyAndOrderFront(nil) // Show the window
    }
}
