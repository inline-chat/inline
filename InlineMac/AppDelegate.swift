//
//  AppDelegate.swift
//  Inline
//
//  Created by Mohammad Rajabifard on 9/22/24.
//

import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillFinishLaunching(_ notification: Notification) {
    // Disable native tabbing
    NSWindow.allowsAutomaticWindowTabbing = false
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
