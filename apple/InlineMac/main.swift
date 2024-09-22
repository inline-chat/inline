//
//  main.swift
//  Inline
//
//  Created by Mohammad Rajabifard on 9/22/24.
//

import AppKit


let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
//app.setActivationPolicy(.accessory)
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
