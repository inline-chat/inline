//
//  AppDelegate.swift
//  Inline
//
//  Created by Mohammad Rajabifard on 9/22/24.
//

import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMainMenu()

        // MARK: - Main Window

        let mainWindowController = MainWindowController()
        self.windowController = mainWindowController
        App.shared.setMainWindow(mainWindowController)
        App.shared.navigate(to: .main)
        
        // show
        mainWindowController.showWindow(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
